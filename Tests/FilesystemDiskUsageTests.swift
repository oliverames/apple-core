import Foundation
import Testing

@Suite("Filesystem disk usage")
struct FilesystemDiskUsageTests {
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    private static func write(_ path: String, bytes: Int, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private static func measure(_ root: URL, maxChildren: Int = 20, roots: [FilesystemRoot]? = nil)
        throws -> FilesystemUsageResult
    {
        try FilesystemDiskUsage.measure(
            root: root,
            roots: roots ?? [FilesystemRoot(path: root.path)],
            maxChildren: maxChildren
        )
    }

    @Test("Subtrees roll up into each direct child and into the total")
    func rollsUp() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("big/one.bin", bytes: 4000, in: sandbox)
        try Self.write("big/deeper/two.bin", bytes: 1000, in: sandbox)
        try Self.write("small/three.bin", bytes: 100, in: sandbox)
        try Self.write("loose.bin", bytes: 10, in: sandbox)

        let result = try Self.measure(sandbox)
        #expect(result.logicalBytes == 5110)
        #expect(result.fileCount == 4)
        #expect(result.childCount == 3)
        // Largest first. These three occupy one, one and two blocks, so the
        // order is decided by the logical tie-break rather than by allocation.
        #expect(result.children.map(\.name) == ["big", "small", "loose.bin"])
        let big = try #require(result.children.first)
        #expect(big.logicalBytes == 5000)
        #expect(big.fileCount == 2)
        #expect(big.isDirectory)
        // "big" itself plus "big/deeper".
        #expect(big.directoryCount == 2)
        #expect(result.directoryCount == 3)
    }

    @Test("Allocated size is reported alongside logical size and is never smaller")
    func reportsAllocatedSize() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("a/one.bin", bytes: 17, in: sandbox)

        let result = try Self.measure(sandbox)
        #expect(result.logicalBytes == 17)
        // A 17-byte file occupies at least one block.
        #expect(result.allocatedBytes >= result.logicalBytes)
    }

    @Test("A symbolic link is counted and never followed")
    func doesNotFollowSymlinks() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let target = try Self.write("real/heavy.bin", bytes: 8000, in: sandbox)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("link.bin"),
            withDestinationURL: target
        )

        let result = try Self.measure(sandbox)
        #expect(result.symbolicLinkCount == 1)
        // Counted once through the real path, not twice through the link.
        #expect(result.logicalBytes == 8000)
        #expect(result.fileCount == 1)
        #expect(!result.children.contains { $0.name == "link.bin" })
    }

    @Test("A link pointing out of the shared folder is denied, not measured")
    func deniesEscapingLink() throws {
        let sandbox = try Self.makeSandbox()
        let outside = try Self.makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try Self.write("inside.bin", bytes: 5, in: sandbox)
        try Self.write("secret.bin", bytes: 9000, in: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("escape.bin"),
            withDestinationURL: outside.appendingPathComponent("secret.bin")
        )

        let result = try Self.measure(sandbox)
        #expect(result.deniedCount == 1)
        #expect(result.symbolicLinkCount == 0)
        #expect(result.logicalBytes == 5)
    }

    @Test("The child list is capped but the totals still cover everything")
    func capsChildrenNotTotals() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        for index in 0 ..< 6 {
            try Self.write("dir\(index)/file.bin", bytes: (index + 1) * 100, in: sandbox)
        }

        let result = try Self.measure(sandbox, maxChildren: 2)
        #expect(result.children.count == 2)
        #expect(result.childCount == 6)
        #expect(result.children.map(\.name) == ["dir5", "dir4"])
        #expect(result.logicalBytes == 2100)
    }

    @Test("A file is not a folder to measure")
    func refusesAFile() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try Self.write("one.bin", bytes: 1, in: sandbox)

        #expect(throws: FilesystemDiskUsageError.notADirectory(file.path)) {
            try Self.measure(file)
        }
    }

    @Test("With no shared folders nothing is measured")
    func requiresRoots() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("one.bin", bytes: 10, in: sandbox)

        let result = try Self.measure(sandbox, roots: [])
        #expect(result.logicalBytes == 0)
        #expect(result.deniedCount == 1)
    }

    @Test("Equal sizes order by name, so two calls agree")
    func deterministicOrder() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("b.bin", bytes: 100, in: sandbox)
        try Self.write("a.bin", bytes: 100, in: sandbox)
        try Self.write("c.bin", bytes: 100, in: sandbox)

        let result = try Self.measure(sandbox)
        #expect(result.children.map(\.name) == ["a.bin", "b.bin", "c.bin"])
    }

    @Test("maxChildren clamps to the documented bounds")
    func clampsChildren() {
        #expect(FilesystemDiskUsage.clampedChildren(nil) == FilesystemDiskUsage.defaultMaxChildren)
        #expect(FilesystemDiskUsage.clampedChildren(0) == FilesystemDiskUsage.defaultMaxChildren)
        #expect(FilesystemDiskUsage.clampedChildren(5) == 5)
        #expect(
            FilesystemDiskUsage.clampedChildren(10_000) == FilesystemDiskUsage.maximumMaxChildren
        )
    }
}
