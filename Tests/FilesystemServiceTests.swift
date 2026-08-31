import Foundation
import Testing

@Suite("Filesystem service behaviour")
struct FilesystemServiceTests {

    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-fs-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Paging a text file

    /// The reason this is worth testing: a window can land mid-character at
    /// either end. Cut at the cap and the last character is incomplete; resume
    /// at the caller's offset and the window opens on continuation bytes that
    /// belong to the character before it. Either one fails UTF-8 validation,
    /// and the read tool would then report a perfectly ordinary text file as
    /// binary purely because of where the page boundary fell.
    @Test("Reading a multibyte file in small windows reassembles it exactly")
    func pagingRoundTripsThroughMultibyteCharacters() throws {
        let original = "héllo wörld 📌 ünïcode ✓ ends here"
        let bytes = Array(original.utf8)
        // Deliberately awkward: larger than the longest character so progress
        // is always possible, small enough to cut most of them.
        let cap = 7

        var rebuilt = ""
        var offset = 0
        var guardRail = 0
        while offset < bytes.count, guardRail < 1000 {
            guardRail += 1
            let remaining = Data(bytes[offset...])
            let truncated = remaining.count > cap
            let window = FilesystemContent.textWindow(
                remaining,
                cap: cap,
                resuming: offset > 0,
                truncated: truncated
            )
            guard let text = window.text, window.consumed > 0 else { break }
            rebuilt += text
            offset += window.consumed
        }

        #expect(rebuilt == original)
        #expect(offset == bytes.count)
    }

    @Test("A window cut mid-character still decodes")
    func truncatedWindowDropsThePartialCharacter() throws {
        // "aé" is 3 bytes; cutting at 2 splits the é.
        let data = Data("aé".utf8)
        let window = FilesystemContent.textWindow(data, cap: 2, resuming: false, truncated: true)
        #expect(window.text == "a")
        #expect(window.byteCount == 1)
        #expect(window.consumed == 1)
    }

    @Test("A window opening mid-character discards the orphaned bytes")
    func resumedWindowDropsLeadingContinuationBytes() throws {
        // Start one byte into a 2-byte é, so the window opens on its
        // continuation byte, which belongs to the previous character.
        let full = Array("éxy".utf8)
        let window = FilesystemContent.textWindow(
            Data(full[1...]),
            cap: 64,
            resuming: true,
            truncated: false
        )
        #expect(window.text == "xy")
        // One orphan byte skipped plus two kept: the caller must advance by
        // three, not two, or it re-reads the orphan forever.
        #expect(window.byteCount == 2)
        #expect(window.consumed == 3)
    }

    @Test("A window that is not text at all decodes to nothing")
    func binaryWindowIsNotText() throws {
        let window = FilesystemContent.textWindow(
            Data([0xFF, 0xFE, 0xFD]),
            cap: 64,
            resuming: false,
            truncated: false
        )
        #expect(window.text == nil)
    }

    // MARK: - Finder tags

    @Test("Tags written through the extended attribute read back as Finder tags")
    func tagsRoundTrip() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("tagged.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        // A URL caches resource values once fetched, so every read here goes
        // through a fresh URL. Reusing one returns the first answer forever
        // and the test would pass whatever the second write did.
        func tagsOnDisk() -> [String] {
            let fresh = URL(fileURLWithPath: file.path)
            return (try? fresh.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }

        try FilesystemContent.setTags(["Receipts", "2026"], on: file)
        #expect(Set(tagsOnDisk()) == Set(["Receipts", "2026"]))

        // Setting replaces rather than merges, which the tool's description
        // promises and a caller adding one tag has to know.
        try FilesystemContent.setTags(["Archive"], on: file)
        #expect(tagsOnDisk() == ["Archive"])

        try FilesystemContent.setTags([], on: file)
        #expect(tagsOnDisk().isEmpty)
    }

    // MARK: - Spotlight query building

    /// Quotes and backslashes in a search term would otherwise end the string
    /// literal in the metadata query and change what is being asked.
    @Test("Search terms are escaped for the metadata query language")
    func spotlightQuotingEscapesQuotesAndBackslashes() throws {
        #expect(Spotlight.quoted("plain") == "plain")
        #expect(Spotlight.quoted("it's") == "it\\'s")
        #expect(Spotlight.quoted("back\\slash") == "back\\\\slash")
        // A term crafted to close the literal and append its own clause stays
        // inert: every quote in it is escaped, not just the one that would
        // have ended the string.
        #expect(
            Spotlight.quoted("' || kMDItemFSName == '*")
                == "\\' || kMDItemFSName == \\'*"
        )
    }

    // MARK: - Overwrite

    @Test("Writing a new file is allowed")
    func writeToNewPathAllowed() {
        #expect(!FilesystemContent.refusesOverwrite(exists: false, overwriteRequested: false))
    }

    @Test("Writing over an existing file is refused unless asked for")
    func writeOverExistingRefused() {
        // The gap this closes: move and copy refused to overwrite, write did
        // not, and a replaced file never reaches the Trash.
        #expect(FilesystemContent.refusesOverwrite(exists: true, overwriteRequested: false))
    }

    @Test("An explicit overwrite is honoured")
    func explicitOverwriteAllowed() {
        #expect(!FilesystemContent.refusesOverwrite(exists: true, overwriteRequested: true))
    }

    // MARK: - Truncation

    @Test("A page that holds every permitted match is not truncated")
    func completePageIsNotTruncated() {
        // The bug: truncation was measured against raw search hits, so any
        // hit dropped for sitting outside the shared roots made a complete
        // answer claim it had been cut short.
        #expect(!FilesystemContent.isTruncated(permittedCount: 7, limit: 100))
    }

    @Test("A page exactly at the limit is not truncated")
    func exactlyFullPageIsNotTruncated() {
        #expect(!FilesystemContent.isTruncated(permittedCount: 100, limit: 100))
    }

    @Test("More permitted matches than the limit is truncated")
    func overflowingPageIsTruncated() {
        #expect(FilesystemContent.isTruncated(permittedCount: 101, limit: 100))
    }

    @Test("No matches at all is not truncated")
    func emptyResultIsNotTruncated() {
        #expect(!FilesystemContent.isTruncated(permittedCount: 0, limit: 100))
    }

    // MARK: - Hidden files

    @Test("A dotfile is hidden and an ordinary file is not")
    func hiddenDetection() throws {
        // filesystem_list showed dotfiles while filesystem_search skipped
        // them, so a file you could see could never be found by name.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotfile = root.appendingPathComponent(".hidden.txt")
        let plain = root.appendingPathComponent("visible.txt")
        try Data("x".utf8).write(to: dotfile)
        try Data("x".utf8).write(to: plain)

        #expect(FilesystemContent.isHidden(dotfile))
        #expect(!FilesystemContent.isHidden(plain))
    }

    @Test("A file hidden without a leading dot is still hidden")
    func hiddenFlagWithoutDot() throws {
        // The dot convention alone would miss this one.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-hidden-flag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var flagged = root.appendingPathComponent("flagged.txt")
        try Data("x".utf8).write(to: flagged)
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)

        #expect(FilesystemContent.isHidden(flagged))
    }
}
