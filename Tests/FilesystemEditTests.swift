import Foundation
import Testing

@Suite("Filesystem selective edits")
struct FilesystemEditTests {
    /// Real directories, because an edit is only interesting once it has a
    /// file to be atomic about and an allowlist to be refused by.
    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-fs-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    private static func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: url.path)), as: UTF8.self)
    }

    // MARK: - Matching

    @Test("A single unique match is replaced and the rest of the file is left alone")
    func singleMatchReplaced() throws {
        let result = try FilesystemEdit.apply(
            [FilesystemTextEdit(oldText: "beta", newText: "BETA")],
            to: "alpha\nbeta\ngamma\n"
        )
        #expect(result.content == "alpha\nBETA\ngamma\n")
        #expect(result.replacements == [1])
        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].line == 2)
        #expect(result.hunks[0].before == "beta")
        #expect(result.hunks[0].after == "BETA")
    }

    @Test("Edits apply in order, so a later one can match what an earlier one wrote")
    func editsApplyInOrder() throws {
        let result = try FilesystemEdit.apply(
            [
                FilesystemTextEdit(oldText: "one", newText: "two"),
                FilesystemTextEdit(oldText: "two", newText: "three"),
            ],
            to: "one\n"
        )
        #expect(result.content == "three\n")
        #expect(result.replacements == [1, 1])
    }

    /// Repeated text is the case where a whole-file rewrite quietly does the
    /// wrong thing: there is no way to tell which occurrence was meant.
    @Test("Text that appears more than once is refused rather than guessed at")
    func repeatedTextIsAmbiguous() throws {
        #expect(throws: FilesystemEditError.ambiguousMatch(editIndex: 0, count: 3)) {
            try FilesystemEdit.apply(
                [FilesystemTextEdit(oldText: "todo", newText: "done")],
                to: "todo\ntodo\nkeep\ntodo\n"
            )
        }
    }

    @Test("replaceAll turns repeated text into an instruction, with a hunk for each")
    func replaceAllChangesEveryOccurrence() throws {
        let result = try FilesystemEdit.apply(
            [FilesystemTextEdit(oldText: "todo", newText: "done", replaceAll: true)],
            to: "todo\ntodo\nkeep\ntodo\n"
        )
        #expect(result.content == "done\ndone\nkeep\ndone\n")
        #expect(result.replacements == [3])
        #expect(result.hunks.map(\.line) == [1, 2, 4])
    }

    @Test("Two occurrences on one line are both replaced without corrupting the line")
    func repeatedTextOnOneLine() throws {
        let result = try FilesystemEdit.apply(
            [FilesystemTextEdit(oldText: "ab", newText: "X", replaceAll: true)],
            to: "abcab\n"
        )
        #expect(result.content == "XcX\n")
        #expect(result.replacements == [2])
    }

    @Test("Text that is not in the file is an error, not a silent no-op")
    func missingTextIsAnError() throws {
        #expect(throws: FilesystemEditError.textNotFound(editIndex: 1)) {
            try FilesystemEdit.apply(
                [
                    FilesystemTextEdit(oldText: "alpha", newText: "ALPHA"),
                    FilesystemTextEdit(oldText: "nowhere", newText: "x"),
                ],
                to: "alpha\n"
            )
        }
    }

    @Test("Empty match text is refused, since it matches everywhere and nowhere")
    func emptyMatchTextIsRefused() throws {
        #expect(throws: FilesystemEditError.emptyMatchText(editIndex: 0)) {
            try FilesystemEdit.apply(
                [FilesystemTextEdit(oldText: "", newText: "x")],
                to: "alpha\n"
            )
        }
    }

    @Test("An empty edit list is refused")
    func noEditsRefused() throws {
        #expect(throws: FilesystemEditError.noEdits) {
            try FilesystemEdit.apply([], to: "alpha\n")
        }
    }

    @Test("More edits than the call accepts are refused before anything is applied")
    func tooManyEditsRefused() throws {
        let edits = (0 ... FilesystemEdit.maximumEdits).map {
            FilesystemTextEdit(oldText: "\($0)", newText: "x")
        }
        #expect(throws: (any Error).self) {
            try FilesystemEdit.apply(edits, to: "0\n")
        }
    }

    // MARK: - Unicode

    @Test("Multibyte text is matched and replaced without disturbing its neighbours")
    func unicodeReplacement() throws {
        let result = try FilesystemEdit.apply(
            [FilesystemTextEdit(oldText: "wörld 📌", newText: "wörld ✓")],
            to: "héllo wörld 📌 ünïcode\nsecond line\n"
        )
        #expect(result.content == "héllo wörld ✓ ünïcode\nsecond line\n")
        #expect(result.hunks[0].before == "héllo wörld 📌 ünïcode")
        #expect(result.hunks[0].after == "héllo wörld ✓ ünïcode")
    }

    /// Swift compares strings by canonical equivalence, so a decomposed "é"
    /// is `==` to a precomposed one while occupying different bytes. Matching
    /// that way would hand back a file whose bytes the caller never asked for,
    /// so the search is literal and this must not match.
    @Test("Two spellings of the same accented character are not treated as the same text")
    func canonicallyEquivalentTextDoesNotMatch() throws {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        #expect(precomposed == decomposed)
        #expect(throws: FilesystemEditError.textNotFound(editIndex: 0)) {
            try FilesystemEdit.apply(
                [FilesystemTextEdit(oldText: decomposed, newText: "tea")],
                to: precomposed + "\n"
            )
        }
    }

    @Test("A file with no trailing newline keeps its shape")
    func noTrailingNewline() throws {
        let result = try FilesystemEdit.apply(
            [FilesystemTextEdit(oldText: "end", newText: "END")],
            to: "start\nend"
        )
        #expect(result.content == "start\nEND")
        #expect(result.hunks[0].line == 2)
    }

    // MARK: - Hashing

    @Test("The hash is the SHA-256 filesystem_hash and notes_update already use")
    func hashMatchesTheExistingContract() {
        #expect(
            FilesystemEdit.hash(of: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(FilesystemEdit.hash(of: Data("abc".utf8)) == FilesystemEdit.hash(of: "abc"))
    }

    // MARK: - Conflict detection

    @Test("An edit against a hash taken before someone else's change is refused")
    func concurrentChangeIsAConflict() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("shared.txt")
        try Self.write("alpha\nbeta\n", to: file)
        let roots = [FilesystemRoot(path: sandbox.path, writable: true)]

        let hashWhenRead = FilesystemEdit.hash(of: "alpha\nbeta\n")
        // Someone else saves the file between the read and the edit.
        try Self.write("alpha\nbeta\ngamma\n", to: file)

        #expect(throws: FilesystemEditError.conflict(file.path)) {
            try FilesystemEdit.perform(
                path: file.path,
                edits: [FilesystemTextEdit(oldText: "beta", newText: "BETA")],
                expectedHash: hashWhenRead,
                preview: false,
                roots: roots
            )
        }
        #expect(try Self.read(file) == "alpha\nbeta\ngamma\n")
    }

    @Test("The conflict is named, so a caller can tell it apart from a bad path")
    func conflictIsNamed() {
        #expect(
            FilesystemEditError.conflict("/tmp/x").localizedDescription
                .hasPrefix("filesystem_edit_conflict:")
        )
    }

    @Test("A matching hash lets the edit through")
    func matchingHashProceeds() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("shared.txt")
        try Self.write("alpha\nbeta\n", to: file)

        let applied = try FilesystemEdit.perform(
            path: file.path,
            edits: [FilesystemTextEdit(oldText: "beta", newText: "BETA")],
            expectedHash: FilesystemEdit.hash(of: "alpha\nbeta\n"),
            preview: false,
            roots: [FilesystemRoot(path: sandbox.path, writable: true)]
        )
        #expect(applied.committed)
        #expect(try Self.read(file) == "alpha\nBETA\n")
        #expect(applied.newHash == FilesystemEdit.hash(of: "alpha\nBETA\n"))
    }

    @Test("An omitted hash edits whatever is there now")
    func omittedHashSkipsTheCheck() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("shared.txt")
        try Self.write("alpha\n", to: file)

        let applied = try FilesystemEdit.perform(
            path: file.path,
            edits: [FilesystemTextEdit(oldText: "alpha", newText: "omega")],
            expectedHash: nil,
            preview: false,
            roots: [FilesystemRoot(path: sandbox.path, writable: true)]
        )
        #expect(applied.previousHash == FilesystemEdit.hash(of: "alpha\n"))
        #expect(try Self.read(file) == "omega\n")
    }

    // MARK: - Preview and atomicity

    @Test("A preview reports the change and leaves the file byte for byte as it was")
    func previewWritesNothing() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("preview.txt")
        try Self.write("alpha\nbeta\n", to: file)
        let modifiedBefore = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        let applied = try FilesystemEdit.perform(
            path: file.path,
            edits: [FilesystemTextEdit(oldText: "beta", newText: "BETA")],
            expectedHash: nil,
            preview: true,
            roots: [FilesystemRoot(path: sandbox.path, writable: true)]
        )

        #expect(!applied.committed)
        #expect(applied.result.content == "alpha\nBETA\n")
        #expect(applied.newHash == FilesystemEdit.hash(of: "alpha\nBETA\n"))
        #expect(try Self.read(file) == "alpha\nbeta\n")
        let modifiedAfter =
            (try? URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        #expect(modifiedBefore == modifiedAfter)
        // Nothing left behind either: an aborted temporary file would show up
        // here as a second entry.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: sandbox.path) == ["preview.txt"]
        )
    }

    @Test("An edit that cannot be placed leaves the original intact")
    func failedEditLeavesTheOriginal() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("atomic.txt")
        try Self.write("alpha\nbeta\n", to: file)

        // The first edit matches and the second does not. Applying the set
        // half way would leave a file nobody asked for.
        #expect(throws: FilesystemEditError.textNotFound(editIndex: 1)) {
            try FilesystemEdit.perform(
                path: file.path,
                edits: [
                    FilesystemTextEdit(oldText: "alpha", newText: "ALPHA"),
                    FilesystemTextEdit(oldText: "nowhere", newText: "x"),
                ],
                expectedHash: nil,
                preview: false,
                roots: [FilesystemRoot(path: sandbox.path, writable: true)]
            )
        }
        #expect(try Self.read(file) == "alpha\nbeta\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.path) == ["atomic.txt"])
    }

    @Test("A committed edit keeps the file's Finder tags")
    func commitPreservesMetadata() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("tagged.txt")
        try Self.write("alpha\n", to: file)
        try FilesystemContent.setTags(["Receipts"], on: file)

        _ = try FilesystemEdit.perform(
            path: file.path,
            edits: [FilesystemTextEdit(oldText: "alpha", newText: "omega")],
            expectedHash: nil,
            preview: false,
            roots: [FilesystemRoot(path: sandbox.path, writable: true)]
        )

        // A fresh URL, because resource values are cached on the one above.
        let fresh = URL(fileURLWithPath: file.path)
        #expect((try? fresh.resourceValues(forKeys: [.tagNamesKey]))?.tagNames == ["Receipts"])
    }

    @Test("Editing a file that is not UTF-8 text is refused")
    func binaryFileIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("image.bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: file)

        #expect(throws: FilesystemEditError.notText(file.path)) {
            try FilesystemEdit.perform(
                path: file.path,
                edits: [FilesystemTextEdit(oldText: "a", newText: "b")],
                expectedHash: nil,
                preview: false,
                roots: [FilesystemRoot(path: sandbox.path, writable: true)]
            )
        }
    }

    @Test("Editing a file that is not there is a clean not-found")
    func missingFileIsNotFound() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("absent.txt")

        #expect(throws: FilesystemAccessError.notFound(file.path)) {
            try FilesystemEdit.perform(
                path: file.path,
                edits: [FilesystemTextEdit(oldText: "a", newText: "b")],
                expectedHash: nil,
                preview: false,
                roots: [FilesystemRoot(path: sandbox.path, writable: true)]
            )
        }
    }

    // MARK: - Scope

    /// A preview is refused too. Showing someone what an edit would do to a
    /// file the allowlist will never let them change reads as approval, and
    /// they find out one call later than they should.
    @Test("A read-only root refuses the edit, preview included", arguments: [true, false])
    func readOnlyRootRefuses(preview: Bool) throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("readonly.txt")
        try Self.write("alpha\n", to: file)

        #expect(throws: FilesystemAccessError.rootNotWritable(file.path)) {
            try FilesystemEdit.perform(
                path: file.path,
                edits: [FilesystemTextEdit(oldText: "alpha", newText: "omega")],
                expectedHash: nil,
                preview: preview,
                roots: [FilesystemRoot(path: sandbox.path, writable: false)]
            )
        }
        #expect(try Self.read(file) == "alpha\n")
    }

    @Test("A symlink out of a shared folder cannot be edited through")
    func symlinkEscapeIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("shared")
        let secret = sandbox.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        let target = secret.appendingPathComponent("passwords.txt")
        try Self.write("hunter2\n", to: target)

        let link = shared.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try FilesystemEdit.perform(
                path: link.path,
                edits: [FilesystemTextEdit(oldText: "hunter2", newText: "changed")],
                expectedHash: nil,
                preview: false,
                roots: [FilesystemRoot(path: shared.path, writable: true)]
            )
        }
        #expect(try Self.read(target) == "hunter2\n")
    }

    @Test("Traversal out of a shared folder cannot be edited through")
    func traversalIsRefused() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let shared = sandbox.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("outside.txt")
        try Self.write("private\n", to: outside)

        #expect(throws: (any Error).self) {
            try FilesystemEdit.perform(
                path: shared.appendingPathComponent("../outside.txt").path,
                edits: [FilesystemTextEdit(oldText: "private", newText: "public")],
                expectedHash: nil,
                preview: false,
                roots: [FilesystemRoot(path: shared.path, writable: true)]
            )
        }
        #expect(try Self.read(outside) == "private\n")
    }
}
