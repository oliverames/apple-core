import Foundation
import Testing

@Suite("Filesystem batch reads")
struct FilesystemBatchReadTests {
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-fs-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    private static func write(_ text: String, _ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Ordering and per-file outcomes

    @Test("Every file comes back in the order it was asked for, with its own contents")
    func orderedResults() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let first = try Self.write("one\n", "a.txt", in: sandbox)
        let second = try Self.write("two\n", "b.txt", in: sandbox)

        // Deliberately not alphabetical, and with a repeat: the caller decides
        // the order, and asking twice is not an error.
        let batch = try FilesystemBatchRead.read(
            paths: [second.path, first.path, second.path],
            roots: [FilesystemRoot(path: sandbox.path)]
        )
        #expect(batch.entries.map(\.content) == ["two\n", "one\n", "two\n"])
        #expect(batch.entries.map(\.ok) == [true, true, true])
        #expect(batch.bytesReturned == 12)
        #expect(!batch.budgetExhausted)
    }

    /// The whole point of the batch: one bad path must not cost the caller the
    /// files that were fine.
    @Test("A missing file fails on its own row while its neighbours still return")
    func partialFailure() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let present = try Self.write("one\n", "a.txt", in: sandbox)
        let absent = sandbox.appendingPathComponent("gone.txt")

        let batch = try FilesystemBatchRead.read(
            paths: [present.path, absent.path, present.path],
            roots: [FilesystemRoot(path: sandbox.path)]
        )
        #expect(batch.entries.map(\.ok) == [true, false, true])
        #expect(batch.entries[1].content == nil)
        #expect(batch.entries[1].error?.contains("does not exist") == true)
        #expect(batch.entries[2].content == "one\n")
    }

    @Test("A folder in the list is named as a folder rather than read")
    func folderIsRejectedOnItsOwnRow() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try Self.write("one\n", "a.txt", in: sandbox)
        let folder = sandbox.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let batch = try FilesystemBatchRead.read(
            paths: [folder.path, file.path],
            roots: [FilesystemRoot(path: sandbox.path)]
        )
        #expect(batch.entries.map(\.ok) == [false, true])
        #expect(batch.entries[0].error?.contains("filesystem_list") == true)
    }

    @Test("A file that is not UTF-8 text is reported, not returned as bytes")
    func binaryFileIsDescribedNotRead() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let binary = sandbox.appendingPathComponent("image.bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: binary)

        let batch = try FilesystemBatchRead.read(
            paths: [binary.path],
            roots: [FilesystemRoot(path: sandbox.path)]
        )
        // Not an error: the file was read, it simply is not text.
        #expect(batch.entries[0].ok)
        #expect(!batch.entries[0].isText)
        #expect(batch.entries[0].content == nil)
        #expect(batch.entries[0].sizeBytes == 3)
    }

    @Test("Multibyte text survives the round trip")
    func unicodeContent() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let text = "héllo wörld 📌 ünïcode ✓\n"
        let file = try Self.write(text, "unicode.txt", in: sandbox)

        let batch = try FilesystemBatchRead.read(
            paths: [file.path],
            roots: [FilesystemRoot(path: sandbox.path)]
        )
        #expect(batch.entries[0].content == text)
        #expect(batch.bytesReturned == text.utf8.count)
    }

    // MARK: - Bounds

    @Test("More paths than the call accepts is refused before anything is read")
    func fileCountIsBounded() throws {
        let paths = (0 ... FilesystemBatchRead.maximumPaths).map { "/tmp/\($0).txt" }
        #expect(
            throws: FilesystemBatchReadError.tooManyPaths(
                requested: paths.count,
                limit: FilesystemBatchRead.maximumPaths
            )
        ) {
            try FilesystemBatchRead.read(paths: paths, roots: [FilesystemRoot(path: "/tmp")])
        }
    }

    @Test("An empty list is refused")
    func emptyListIsRefused() throws {
        #expect(throws: FilesystemBatchReadError.noPaths) {
            try FilesystemBatchRead.read(paths: [], roots: [FilesystemRoot(path: "/tmp")])
        }
    }

    /// Without an aggregate bound, a batch is simply a way to return many
    /// times what a single read is capped at.
    @Test("The byte budget is spent across the batch, and the rest is told where to go")
    func aggregateByteBudget() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let first = try Self.write(String(repeating: "a", count: 100), "a.txt", in: sandbox)
        let second = try Self.write(String(repeating: "b", count: 100), "b.txt", in: sandbox)
        let third = try Self.write(String(repeating: "c", count: 100), "c.txt", in: sandbox)

        let batch = try FilesystemBatchRead.read(
            paths: [first.path, second.path, third.path],
            roots: [FilesystemRoot(path: sandbox.path)],
            budget: 150
        )
        #expect(batch.entries[0].content?.count == 100)
        // The second file is cut at the remaining budget rather than skipped.
        #expect(batch.entries[1].content?.count == 50)
        #expect(batch.entries[1].truncated)
        // The third has nothing left to spend, and is told to read on its own.
        #expect(!batch.entries[2].ok)
        #expect(batch.entries[2].error?.contains("filesystem_read") == true)
        #expect(batch.budgetExhausted)
        #expect(batch.bytesReturned == 150)
    }

    @Test("A window cut mid-character by the budget still decodes")
    func budgetCutMidCharacter() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // "aé" is three bytes; a two-byte budget splits the é.
        let file = try Self.write("aé", "multibyte.txt", in: sandbox)

        let batch = try FilesystemBatchRead.read(
            paths: [file.path],
            roots: [FilesystemRoot(path: sandbox.path)],
            budget: 2
        )
        #expect(batch.entries[0].content == "a")
        #expect(batch.entries[0].isText)
        #expect(batch.entries[0].truncated)
    }

    // MARK: - Scope

    /// A denied path may only ever talk about the path the caller already
    /// named. Naming the shared folder it is not inside, or any other one,
    /// would turn a batch read into a way to map the allowlist.
    @Test("A denied path says nothing about the folders that were shared")
    func deniedPathRevealsNothing() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("shared")
        let other = sandbox.appendingPathComponent("also-shared")
        let secret = sandbox.appendingPathComponent("secret")
        for directory in [shared, other, secret] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let visible = try Self.write("fine\n", "a.txt", in: shared)
        try Self.write("hunter2\n", "passwords.txt", in: secret)
        let denied = secret.appendingPathComponent("passwords.txt")

        let batch = try FilesystemBatchRead.read(
            paths: [visible.path, denied.path],
            roots: [FilesystemRoot(path: shared.path), FilesystemRoot(path: other.path)]
        )
        #expect(batch.entries[0].content == "fine\n")
        let message = try #require(batch.entries[1].error)
        #expect(!message.contains(shared.path))
        #expect(!message.contains(other.path))
        #expect(!message.contains("hunter2"))
        #expect(batch.entries[1].content == nil)
    }

    @Test("A symlink out of a shared folder is denied on its own row")
    func symlinkEscapeIsDenied() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("shared")
        let secret = sandbox.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        let target = try Self.write("hunter2\n", "passwords.txt", in: secret)
        let link = shared.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let visible = try Self.write("fine\n", "a.txt", in: shared)

        let batch = try FilesystemBatchRead.read(
            paths: [link.path, visible.path],
            roots: [FilesystemRoot(path: shared.path)]
        )
        #expect(!batch.entries[0].ok)
        #expect(batch.entries[0].content == nil)
        #expect(batch.entries[1].content == "fine\n")
    }

    @Test("An empty allowlist denies every row without reading anything")
    func emptyAllowlistDeniesEverything() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try Self.write("one\n", "a.txt", in: sandbox)

        let batch = try FilesystemBatchRead.read(paths: [file.path], roots: [])
        #expect(!batch.entries[0].ok)
        #expect(batch.bytesReturned == 0)
    }

    @Test("Reading only needs a readable root, not a writable one")
    func readOnlyRootIsEnough() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try Self.write("one\n", "a.txt", in: sandbox)

        let batch = try FilesystemBatchRead.read(
            paths: [file.path],
            roots: [FilesystemRoot(path: sandbox.path, writable: false)]
        )
        #expect(batch.entries[0].content == "one\n")
    }
}

@Suite("Filesystem not-found contract")
struct FilesystemExistenceTests {
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-fs-exists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// The reported bug: resolution deliberately succeeds for a path that does
    /// not exist yet, because that is the write case. A read-only caller that
    /// took the resolved URL at face value described a trashed file as an
    /// ordinary non-directory, and the caller had to infer absence from
    /// missing fields.
    @Test("A trashed file is a clean not-found, not metadata saying it is not a directory")
    func trashedPathIsNotFound() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("receipt.txt")
        try Data("one\n".utf8).write(to: file, options: [.atomic])
        let roots = [FilesystemRoot(path: sandbox.path, writable: true)]

        // While it is there, it describes normally.
        #expect(
            try FilesystemContent.resolveExisting(requested: file.path, roots: roots).path
                == file.path
        )

        var trashed: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        // The test put it in the Trash, so the test takes it back out.
        defer {
            if let location = trashed as? URL {
                try? FileManager.default.removeItem(at: location)
            }
        }

        #expect(throws: FilesystemAccessError.notFound(file.path)) {
            try FilesystemContent.resolveExisting(requested: file.path, roots: roots)
        }
    }

    @Test("A path that was never there is the same not-found")
    func absentPathIsNotFound() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let absent = sandbox.appendingPathComponent("never-existed.txt")

        #expect(throws: FilesystemAccessError.notFound(absent.path)) {
            try FilesystemContent.resolveExisting(
                requested: absent.path,
                roots: [FilesystemRoot(path: sandbox.path)]
            )
        }
    }

    /// Containment is still decided first. A path outside the shared folders
    /// must not learn whether it exists.
    @Test("A path outside the shared folders is refused for being outside, not for being absent")
    func outsideRootsStaysOutsideRoots() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("outside.txt")

        #expect(throws: FilesystemAccessError.outsideAllowedRoots(outside.path)) {
            try FilesystemContent.resolveExisting(
                requested: outside.path,
                roots: [FilesystemRoot(path: shared.path)]
            )
        }
    }
}
