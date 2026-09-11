import Foundation
import Testing

@Suite("Bounded filesystem tree")
struct FilesystemTreeTests {
    /// A real tree on disk: the walk resolves every child through
    /// `FilesystemAccess`, which is defined on canonical paths and cannot be
    /// exercised against files that do not exist.
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-tree-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func write(_ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func walk(
        _ root: URL,
        maxDepth: Int = 10,
        maxEntries: Int = 100,
        exclusions: [String] = [],
        includeHidden: Bool = true,
        cursor: String? = nil
    ) throws -> FilesystemTreeResult {
        try FilesystemTree.walk(
            root: root,
            roots: [FilesystemRoot(path: root.path)],
            maxDepth: maxDepth,
            maxEntries: maxEntries,
            exclusions: exclusions,
            includeHidden: includeHidden,
            cursor: cursor
        )
    }

    @Test("The walk descends and reports relative paths and depth")
    func descends() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("a/b/c.txt", in: sandbox)

        let result = try Self.walk(sandbox)
        let paths = result.entries.map(\.relativePath)
        #expect(paths == ["a", "a/b", "a/b/c.txt"])
        #expect(result.entries.map(\.depth) == [1, 2, 3])
        #expect(result.nextCursor == nil)
    }

    @Test("maxDepth stops the descent and says so")
    func depthLimit() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("a/b/c.txt", in: sandbox)

        let result = try Self.walk(sandbox, maxDepth: 2)
        #expect(result.entries.map(\.relativePath) == ["a", "a/b"])
        #expect(result.reachedDepthLimit)
    }

    @Test("A page stops at the entry budget and continues from its cursor")
    func entryBudgetAndContinuation() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try Self.write(name, in: sandbox)
        }

        let first = try Self.walk(sandbox, maxEntries: 2)
        #expect(first.entries.map(\.relativePath) == ["a.txt", "b.txt"])
        #expect(first.reachedEntryLimit)
        #expect(first.nextCursor == "b.txt")

        let second = try Self.walk(sandbox, maxEntries: 2, cursor: first.nextCursor)
        #expect(second.entries.map(\.relativePath) == ["c.txt", "d.txt"])
        // Exactly the budget, so the walk cannot yet know it is finished; the
        // page after it is the empty one that proves it.
        let third = try Self.walk(sandbox, maxEntries: 2, cursor: second.nextCursor)
        #expect(third.entries.isEmpty)
        #expect(third.nextCursor == nil)
    }

    @Test("Continuation resumes inside a directory it was part way through")
    func continuationInsideDirectory() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("dir/one.txt", in: sandbox)
        try Self.write("dir/two.txt", in: sandbox)
        try Self.write("zebra.txt", in: sandbox)

        let first = try Self.walk(sandbox, maxEntries: 2)
        #expect(first.entries.map(\.relativePath) == ["dir", "dir/one.txt"])
        let second = try Self.walk(sandbox, maxEntries: 5, cursor: first.nextCursor)
        #expect(second.entries.map(\.relativePath) == ["dir/two.txt", "zebra.txt"])
    }

    @Test("Exclusion patterns match names and paths, and are counted")
    func exclusions() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("keep.txt", in: sandbox)
        try Self.write("noisy.log", in: sandbox)
        try Self.write("build/output.txt", in: sandbox)

        let result = try Self.walk(sandbox, exclusions: ["*.log", "build"])
        #expect(result.entries.map(\.relativePath) == ["keep.txt"])
        #expect(result.excludedCount == 2)
    }

    @Test("A path pattern matches the path, not the bare name")
    func pathPattern() {
        #expect(
            FilesystemGlob.matches(pattern: "build/*", name: "out.txt", relativePath: "build/out.txt")
        )
        #expect(
            !FilesystemGlob.matches(pattern: "build/*", name: "out.txt", relativePath: "src/out.txt")
        )
        #expect(FilesystemGlob.matches(pattern: "*.log", name: "a.log", relativePath: "x/a.log"))
    }

    @Test("Hidden entries are excluded on request")
    func hidden() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write(".secret", in: sandbox)
        try Self.write("open.txt", in: sandbox)

        let shown = try Self.walk(sandbox, includeHidden: true)
        #expect(shown.entries.count == 2)
        let hidden = try Self.walk(sandbox, includeHidden: false)
        #expect(hidden.entries.map(\.relativePath) == ["open.txt"])
    }

    @Test("A symlink out of the root is listed but never descended into")
    func symlinkNotFollowed() throws {
        let sandbox = try Self.makeSandbox()
        let outside = try Self.makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try Self.write("secret.txt", in: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let result = try Self.walk(sandbox)
        // The link itself resolves outside the shared root, so it is denied
        // rather than listed: the allowlist is asked about every child.
        #expect(result.entries.isEmpty)
        #expect(result.deniedCount == 1)
    }

    @Test("A child that resolves outside the shared roots is counted, never named")
    func deniedChildrenAreCounted() throws {
        let sandbox = try Self.makeSandbox()
        let outside = try Self.makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try Self.write("inside.txt", in: sandbox)
        try Self.write("target.txt", in: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("link.txt"),
            withDestinationURL: outside.appendingPathComponent("target.txt")
        )

        let result = try Self.walk(sandbox)
        #expect(result.entries.map(\.relativePath) == ["inside.txt"])
        #expect(result.deniedCount == 1)
    }

    @Test("Walking a file rather than a folder is an error")
    func notADirectory() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Self.write("file.txt", in: sandbox)
        let file = sandbox.appendingPathComponent("file.txt")

        #expect(throws: FilesystemTreeError.notADirectory(file.path)) {
            try FilesystemTree.walk(
                root: file,
                roots: [FilesystemRoot(path: sandbox.path)],
                maxDepth: 3,
                maxEntries: 10,
                exclusions: [],
                includeHidden: true,
                cursor: nil
            )
        }
    }

    @Test("Bounds are clamped rather than trusted")
    func clamping() {
        #expect(FilesystemTree.clampedDepth(nil) == FilesystemTree.defaultMaxDepth)
        #expect(FilesystemTree.clampedDepth(0) == FilesystemTree.defaultMaxDepth)
        #expect(FilesystemTree.clampedDepth(99) == FilesystemTree.maximumMaxDepth)
        #expect(FilesystemTree.clampedEntries(5) == 5)
        #expect(FilesystemTree.clampedEntries(9_999) == FilesystemTree.maximumMaxEntries)
    }
}
