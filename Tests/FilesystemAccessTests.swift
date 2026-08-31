import Foundation
import Testing

@Suite("Filesystem scope enforcement")
struct FilesystemAccessTests {
    /// Real directories, because containment is defined on symlink-resolved
    /// canonical paths and that cannot be exercised against paths that do not
    /// exist. Everything lives under one temporary root and is removed after.
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-fs-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    @Test("An empty allowlist denies everything")
    func emptyAllowlistDenies() throws {
        #expect(throws: FilesystemAccessError.noRootsConfigured) {
            try FilesystemAccess.resolve(
                requested: NSHomeDirectory(),
                roots: [],
                requiringWrite: false
            )
        }
    }

    @Test("A file inside an allowed root resolves")
    func fileInsideRootResolves() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let resolved = try FilesystemAccess.resolve(
            requested: file.path,
            roots: [FilesystemRoot(path: sandbox.path)],
            requiringWrite: false
        )
        #expect(resolved.path == file.path)
    }

    @Test("Traversal out of an allowed root is refused")
    func traversalIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let inside = sandbox.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        // ../.. climbs above the shared folder; canonicalization collapses it
        // before the containment check, so it cannot sneak through.
        #expect(throws: (any Error).self) {
            try FilesystemAccess.resolve(
                requested: inside.appendingPathComponent("../../escaped.txt").path,
                roots: [FilesystemRoot(path: inside.path)],
                requiringWrite: false
            )
        }
    }

    @Test("A symlink pointing outside an allowed root is refused")
    func symlinkEscapeIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let shared = sandbox.appendingPathComponent("shared")
        let secret = sandbox.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        let target = secret.appendingPathComponent("password.txt")
        try "hunter2".write(to: target, atomically: true, encoding: .utf8)

        // A symlink that lives inside the shared folder but resolves outside it
        // is the whole reason containment is checked after resolution.
        let link = shared.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try FilesystemAccess.resolve(
                requested: link.path,
                roots: [FilesystemRoot(path: shared.path)],
                requiringWrite: false
            )
        }
    }

    @Test("A sibling whose name extends the root is not contained")
    func siblingPrefixIsNotContained() {
        #expect(!FilesystemAccess.isContained("/Users/x/Documents-private", in: "/Users/x/Documents"))
        #expect(FilesystemAccess.isContained("/Users/x/Documents/a.txt", in: "/Users/x/Documents"))
        #expect(FilesystemAccess.isContained("/Users/x/Documents", in: "/Users/x/Documents"))
    }

    @Test("Writing to a read-only root is refused but reading is allowed")
    func readOnlyRootRefusesWrites() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let roots = [FilesystemRoot(path: sandbox.path, writable: false)]

        #expect(throws: FilesystemAccessError.rootNotWritable(file.path)) {
            try FilesystemAccess.resolve(requested: file.path, roots: roots, requiringWrite: true)
        }
        #expect(throws: Never.self) {
            try FilesystemAccess.resolve(requested: file.path, roots: roots, requiringWrite: false)
        }
    }

    @Test("A new file in a writable root resolves before it exists")
    func newFileInWritableRootResolves() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolved = try FilesystemAccess.resolve(
            requested: sandbox.appendingPathComponent("new.txt").path,
            roots: [FilesystemRoot(path: sandbox.path, writable: true)],
            requiringWrite: true
        )
        #expect(resolved.lastPathComponent == "new.txt")
    }

    @Test("A dangling symlink at the final component is refused for writes")
    func danglingSymlinkIsRefusedForWrites() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // fileExists follows symlinks, so this planted link reads as a
        // not-yet-created file. Parent-only resolution used to bless the raw
        // name and the out-of-process writer (Mail.app, shortcuts) would
        // then follow the link wherever it pointed.
        let link = sandbox.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/tmp/apple-core-dangling-target-\(UUID().uuidString)")
        )

        #expect(throws: FilesystemAccessError.danglingSymlink(link.path)) {
            try FilesystemAccess.resolve(
                requested: link.path,
                roots: [FilesystemRoot(path: sandbox.path, writable: true)],
                requiringWrite: true
            )
        }
    }

    @Test("A shared root cannot be retargeted after approval")
    func retargetedRootIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let shared = sandbox.appendingPathComponent("shared")
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let roots = [FilesystemRoot(path: shared.path, writable: true)]

        try FileManager.default.removeItem(at: shared)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: outside)
        let redirectedFile = shared.appendingPathComponent("redirected.txt")

        #expect(throws: FilesystemAccessError.retargetedRoot(shared.path)) {
            try FilesystemAccess.resolve(
                requested: redirectedFile.path,
                roots: roots,
                requiringWrite: true
            )
        }
    }

    /// Roots are allowed to overlap, so the settings list can hold a broad
    /// read-only root and a narrow writable one inside it. Resolution takes
    /// the most permissive match, which is what lets a user grant writes to
    /// one folder without opening up everything above it.
    @Test("A writable root inside a read-only root grants writes to its own subtree")
    func writableRootInsideReadOnlyRootGrantsWrites() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let inner = sandbox.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let innerFile = inner.appendingPathComponent("draft.txt")
        try "hello".write(to: innerFile, atomically: true, encoding: .utf8)
        let outerFile = sandbox.appendingPathComponent("readme.txt")
        try "hello".write(to: outerFile, atomically: true, encoding: .utf8)

        let roots = [
            FilesystemRoot(path: sandbox.path, writable: false),
            FilesystemRoot(path: inner.path, writable: true),
        ]

        // The writable inner root covers this file, so the write is allowed
        // even though the enclosing root is read-only.
        let resolved = try FilesystemAccess.resolve(
            requested: innerFile.path,
            roots: roots,
            requiringWrite: true
        )
        #expect(resolved.path == innerFile.path)

        // A sibling covered only by the read-only root still refuses writes,
        // and reports that it is shared rather than absent.
        #expect(throws: FilesystemAccessError.rootNotWritable(outerFile.path)) {
            try FilesystemAccess.resolve(
                requested: outerFile.path,
                roots: roots,
                requiringWrite: true
            )
        }

        // Both remain readable through the broad root.
        #expect(
            try FilesystemAccess.resolve(
                requested: outerFile.path,
                roots: roots,
                requiringWrite: false
            ).path == outerFile.path
        )
    }

    @Test("A path outside the roots never reveals anything about itself")
    func outsidePathsRevealNothing() throws {
        // These checks used to run before containment, so asking for any path
        // on the disk answered "broken symbolic link" or "does not exist".
        // Both are facts about a file the caller may not see, which made the
        // resolver a probe. Every outside path must now give one answer.
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let shared = sandbox.appendingPathComponent("shared")
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let dangling = outside.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: sandbox.appendingPathComponent("gone").path
        )
        let roots = [FilesystemRoot(path: shared.path, writable: true)]

        #expect(throws: FilesystemAccessError.outsideAllowedRoots(dangling.path)) {
            try FilesystemAccess.resolve(
                requested: dangling.path,
                roots: roots,
                requiringWrite: false
            )
        }

        // A missing file under a missing parent must answer the same way.
        let deep = outside.appendingPathComponent("nope/alsonope.txt")
        #expect(throws: FilesystemAccessError.outsideAllowedRoots(deep.path)) {
            try FilesystemAccess.resolve(requested: deep.path, roots: roots, requiringWrite: false)
        }
    }

    @Test("A broken symlink inside a shared folder is still refused")
    func danglingInsideRootStillRefused() throws {
        // Reordering must not weaken the check it reordered: inside a shared
        // folder, a broken link is still where a write could land anywhere.
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let dangling = sandbox.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: "/nonexistent/elsewhere"
        )
        #expect(throws: FilesystemAccessError.danglingSymlink(dangling.path)) {
            try FilesystemAccess.resolve(
                requested: dangling.path,
                roots: [FilesystemRoot(path: sandbox.path, writable: true)],
                requiringWrite: true
            )
        }
    }
}
