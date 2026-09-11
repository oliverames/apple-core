// SPDX-License-Identifier: GPL-3.0-or-later
//
// Attachment identity, filtering and bounded retrieval.
//
// The listing half runs against a chat.db-shaped fixture; the retrieval half
// runs against a fake home directory holding real files, so "the file is
// gone", "the file is in iCloud" and "that link leaves Messages' storage" are
// exercised as filesystem states rather than mocked out.

import Foundation
import SQLite3
import Testing

@Suite("Messages attachment retrieval")
struct MessagesAttachmentRetrievalTests {
    // MARK: - Listing

    private static func makeFixture(withModernColumns: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-attach-\(UUID().uuidString).sqlite")

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        // 2023-01-01 and 2024-01-01 in Apple's nanoseconds-since-2001.
        let attachmentTable =
            withModernColumns
            ? """
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, transfer_name TEXT,
                mime_type TEXT, uti TEXT, total_bytes INTEGER, is_sticker INTEGER,
                created_date INTEGER, filename TEXT);
            INSERT INTO attachment VALUES
                (1, 'at_0_AAA', 'photo.png', 'image/png', 'public.png', 2048, 0,
                 694224000000000000, '~/Library/Messages/Attachments/aa/photo.png'),
                (2, 'at_0_BBB', 'contract.pdf', 'application/pdf', 'com.adobe.pdf', 4096, 0,
                 725846400000000000, '~/Library/Messages/Attachments/bb/contract.pdf'),
                (3, 'at_0_CCC', 'sticker.heic', 'image/heic', 'public.heic', 512, 1,
                 725932800000000000, '~/Library/Messages/Attachments/cc/sticker.heic');
            """
            : """
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, transfer_name TEXT,
                mime_type TEXT, uti TEXT, total_bytes INTEGER, is_sticker INTEGER,
                created_date INTEGER);
            INSERT INTO attachment VALUES
                (1, 'photo.png', 'image/png', 'public.png', 2048, 0, 694224000000000000),
                (2, 'contract.pdf', 'application/pdf', 'com.adobe.pdf', 4096, 0, 725846400000000000),
                (3, 'sticker.heic', 'image/heic', 'public.heic', 512, 1, 725932800000000000);
            """

        let schema = """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, is_read INTEGER, is_from_me INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            \(attachmentTable)

            INSERT INTO chat VALUES (1, 'chat-alpha', 'Alpha'), (2, 'chat-beta', 'Beta');
            INSERT INTO handle VALUES (1, '+15551110000', NULL), (2, 'friend@example.com', NULL);
            INSERT INTO chat_handle_join VALUES (1,1),(2,2);
            INSERT INTO message VALUES (1, 'm1', 1, 0), (2, 'm2', 1, 1), (3, 'm3', 1, 0);
            INSERT INTO chat_message_join VALUES (1,1),(1,2),(2,3);
            INSERT INTO message_attachment_join VALUES (1,1),(2,2),(3,3);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        return url
    }

    @Test("Every attachment carries a stable id that fetch accepts")
    func attachmentsCarryStableIdentifiers() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let first = try reader.attachments(matching: MessageAttachmentFilter(limit: 10))
        let second = try reader.attachments(matching: MessageAttachmentFilter(limit: 10))

        #expect(first.map(\.id) == ["at_0_CCC", "at_0_BBB", "at_0_AAA"])
        #expect(first.map(\.id) == second.map(\.id))
        let fetched = try reader.attachment(id: "at_0_BBB")
        #expect(fetched?.name == "contract.pdf")
        #expect(fetched?.storedPath == "~/Library/Messages/Attachments/bb/contract.pdf")
        #expect(fetched?.chatGUID == "chat-alpha")
        #expect(try reader.attachment(id: "at_0_NOPE") == nil)
    }

    @Test("A database without the guid and filename columns falls back to row ids")
    func legacySchemaStillYieldsIdentifiers() throws {
        let url = try Self.makeFixture(withModernColumns: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let all = try reader.attachments(matching: MessageAttachmentFilter(limit: 10))

        #expect(all.map(\.id) == ["3", "2", "1"])
        #expect(all.allSatisfy { $0.storedPath == nil })
        #expect(try reader.attachment(id: "2")?.name == "contract.pdf")
    }

    @Test("MIME filtering matches a whole family or one exact type")
    func mimeFilteringMatchesFamilyAndExactType() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let images = try reader.attachments(
            matching: MessageAttachmentFilter(mimeType: "image/", limit: 10)
        )
        let wildcard = try reader.attachments(
            matching: MessageAttachmentFilter(mimeType: "IMAGE/*", limit: 10)
        )
        let pdfs = try reader.attachments(
            matching: MessageAttachmentFilter(mimeType: "application/pdf", limit: 10)
        )
        // "_" is a LIKE wildcard; escaped, it matches nothing here.
        let escaped = try reader.attachments(
            matching: MessageAttachmentFilter(mimeType: "image_", limit: 10)
        )

        #expect(images.map(\.id) == ["at_0_CCC", "at_0_AAA"])
        #expect(wildcard.map(\.id) == images.map(\.id))
        #expect(pdfs.map(\.name) == ["contract.pdf"])
        #expect(escaped.isEmpty)
    }

    @Test("Date bounds narrow to the window, treating end as exclusive")
    func dateFilteringUsesAHalfOpenWindow() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)
        let appleEpoch = Date(timeIntervalSince1970: 978_307_200)
        let january2024 = appleEpoch.addingTimeInterval(725_846_400)

        let since = try reader.attachments(
            matching: MessageAttachmentFilter(start: january2024, limit: 10)
        )
        let before = try reader.attachments(
            matching: MessageAttachmentFilter(end: january2024, limit: 10)
        )

        #expect(since.map(\.name) == ["sticker.heic", "contract.pdf"])
        #expect(before.map(\.name) == ["photo.png"])
    }

    @Test("Participant and chat filters narrow to one conversation")
    func participantAndChatFiltersNarrowResults() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let handles = try reader.participantHandles(matching: ["friend@example.com"])
        let byParticipant = try reader.attachments(
            matching: MessageAttachmentFilter(participantHandles: handles, limit: 10)
        )
        let byChat = try reader.attachments(
            matching: MessageAttachmentFilter(chatGUID: "chat-alpha", limit: 10)
        )

        #expect(handles == ["friend@example.com"])
        #expect(byParticipant.map(\.name) == ["sticker.heic"])
        #expect(byChat.map(\.name) == ["contract.pdf", "photo.png"])
    }

    @Test("Paging attachments covers each one exactly once")
    func attachmentPagingDoesNotRepeatOrSkip() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let first = try reader.attachments(matching: MessageAttachmentFilter(limit: 2, offset: 0))
        let second = try reader.attachments(matching: MessageAttachmentFilter(limit: 2, offset: 2))

        #expect(first.map(\.id) == ["at_0_CCC", "at_0_BBB"])
        #expect(second.map(\.id) == ["at_0_AAA"])
    }

    // MARK: - Retrieval

    /// A throwaway home directory with Messages' attachment folder inside it.
    private struct FakeHome {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var attachments: URL {
            home.appendingPathComponent("Library/Messages/Attachments")
        }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-core-messages-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: attachments,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("elsewhere"),
                withIntermediateDirectories: true
            )
        }

        func write(_ name: String, bytes: Int) throws -> String {
            let url = attachments.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return "~/Library/Messages/Attachments/\(name)"
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func reason(
        storedPath: String?,
        name: String,
        declaredSize: Int,
        maximumBytes: Int = 256 * 1024,
        home: FakeHome
    ) -> MessagesAttachmentContentError? {
        do {
            _ = try MessagesAttachmentContent.load(
                storedPath: storedPath,
                name: name,
                declaredSize: declaredSize,
                maximumBytes: maximumBytes,
                homeDirectory: home.home
            )
            return nil
        } catch let error as MessagesAttachmentContentError {
            return error
        } catch {
            return nil
        }
    }

    @Test("An attachment on disk comes back as bytes with its size and type")
    func presentAttachmentIsReturnedInline() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let stored = try home.write("aa/photo.png", bytes: 1024)

        let payload = try MessagesAttachmentContent.load(
            storedPath: stored,
            name: "photo.png",
            declaredSize: 1024,
            maximumBytes: 256 * 1024,
            homeDirectory: home.home,
            mimeType: "image/png"
        )

        #expect(payload.byteCount == 1024)
        #expect(payload.data.count == 1024)
        #expect(payload.mimeType == "image/png")
        #expect(
            MessagesAttachmentContent.availability(
                storedPath: stored,
                name: "photo.png",
                declaredSize: 1024,
                homeDirectory: home.home
            ) == .available
        )
    }

    @Test("A pruned attachment says the file is gone, not that the read failed")
    func missingFileHasItsOwnReason() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let stored = "~/Library/Messages/Attachments/aa/vanished.png"

        #expect(
            MessagesAttachmentContent.availability(
                storedPath: stored,
                name: "vanished.png",
                declaredSize: 2048,
                homeDirectory: home.home
            ) == .missing
        )
        guard
            case .missingFile = reason(
                storedPath: stored,
                name: "vanished.png",
                declaredSize: 2048,
                home: home
            )
        else {
            Issue.record("expected a missing-file reason")
            return
        }
    }

    @Test("A cloud-only attachment says it was never downloaded to this Mac")
    func cloudOnlyFileHasItsOwnReason() throws {
        let home = try FakeHome()
        defer { home.remove() }
        // iCloud leaves a dot-prefixed placeholder where the file would be.
        _ = try home.write("aa/.holiday.heic.icloud", bytes: 16)
        let stored = "~/Library/Messages/Attachments/aa/holiday.heic"

        #expect(
            MessagesAttachmentContent.availability(
                storedPath: stored,
                name: "holiday.heic",
                declaredSize: 900_000,
                homeDirectory: home.home
            ) == .notDownloaded
        )
        guard
            case .notDownloaded = reason(
                storedPath: stored,
                name: "holiday.heic",
                declaredSize: 900_000,
                home: home
            )
        else {
            Issue.record("expected a not-downloaded reason")
            return
        }
    }

    @Test("An empty stand-in for a file Messages says has content is not downloaded")
    func zeroByteStandInIsNotDownloaded() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let stored = try home.write("aa/evicted.heic", bytes: 0)

        #expect(
            MessagesAttachmentContent.availability(
                storedPath: stored,
                name: "evicted.heic",
                declaredSize: 900_000,
                homeDirectory: home.home
            ) == .notDownloaded
        )
    }

    @Test("Attachments over the cap are refused with their size, before being read")
    func sizeCapIsEnforcedFromBothSides() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let stored = try home.write("aa/big.bin", bytes: 4096)

        // The recorded size alone is enough to refuse.
        guard
            case let .tooLarge(_, declaredBytes, declaredCap) = reason(
                storedPath: stored,
                name: "big.bin",
                declaredSize: 10_000_000,
                maximumBytes: 1024,
                home: home
            )
        else {
            Issue.record("expected a too-large reason for the declared size")
            return
        }
        #expect(declaredBytes == 10_000_000)
        #expect(declaredCap == 1024)

        // So is the real size when chat.db understates it.
        guard
            case let .tooLarge(_, actualBytes, _) = reason(
                storedPath: stored,
                name: "big.bin",
                declaredSize: 10,
                maximumBytes: 1024,
                home: home
            )
        else {
            Issue.record("expected a too-large reason for the on-disk size")
            return
        }
        #expect(actualBytes == 4096)

        // And a file inside the cap still comes back.
        let payload = try MessagesAttachmentContent.load(
            storedPath: stored,
            name: "big.bin",
            declaredSize: 4096,
            maximumBytes: 8192,
            homeDirectory: home.home
        )
        #expect(payload.byteCount == 4096)
    }

    @Test("A link out of Messages' storage is refused, one staying inside is followed")
    func symlinkBoundariesAreEnforced() throws {
        let home = try FakeHome()
        defer { home.remove() }

        let outside = home.root.appendingPathComponent("elsewhere/secret.txt")
        try Data("private".utf8).write(to: outside)
        let escaping = home.attachments.appendingPathComponent("aa/escape.txt")
        try FileManager.default.createDirectory(
            at: escaping.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside)

        let escapePath = "~/Library/Messages/Attachments/aa/escape.txt"
        #expect(
            MessagesAttachmentContent.availability(
                storedPath: escapePath,
                name: "escape.txt",
                declaredSize: 7,
                homeDirectory: home.home
            ) == .blocked
        )
        guard
            case .outsideMessagesStorage = reason(
                storedPath: escapePath,
                name: "escape.txt",
                declaredSize: 7,
                home: home
            )
        else {
            Issue.record("expected an outside-storage reason for the escaping link")
            return
        }

        // A link that stays inside the attachments tree is ordinary.
        let real = try home.write("bb/real.txt", bytes: 12)
        let inside = home.attachments.appendingPathComponent("aa/alias.txt")
        try FileManager.default.createSymbolicLink(
            at: inside,
            withDestinationURL: home.attachments.appendingPathComponent("bb/real.txt")
        )
        #expect(real.hasSuffix("bb/real.txt"))
        let payload = try MessagesAttachmentContent.load(
            storedPath: "~/Library/Messages/Attachments/aa/alias.txt",
            name: "alias.txt",
            declaredSize: 12,
            maximumBytes: 4096,
            homeDirectory: home.home
        )
        #expect(payload.byteCount == 12)
    }

    @Test("Climbing out of the attachments folder with .. is refused")
    func relativeEscapeIsRefused() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let outside = home.root.appendingPathComponent("elsewhere/secret.txt")
        try Data("private".utf8).write(to: outside)

        let stored = "~/Library/Messages/Attachments/../../../elsewhere/secret.txt"

        #expect(
            MessagesAttachmentContent.availability(
                storedPath: stored,
                name: "secret.txt",
                declaredSize: 7,
                homeDirectory: home.home
            ) == .blocked
        )
        guard
            case .outsideMessagesStorage = reason(
                storedPath: stored,
                name: "secret.txt",
                declaredSize: 7,
                home: home
            )
        else {
            Issue.record("expected an outside-storage reason for the relative escape")
            return
        }
    }

    @Test("A row with no recorded path says so rather than failing obscurely")
    func rowWithoutAPathIsReported() throws {
        let home = try FakeHome()
        defer { home.remove() }

        #expect(
            MessagesAttachmentContent.availability(
                storedPath: nil,
                name: "unknown",
                declaredSize: 0,
                homeDirectory: home.home
            ) == .unknown
        )
        guard
            case .noStoredPath = reason(
                storedPath: "   ",
                name: "unknown",
                declaredSize: 0,
                home: home
            )
        else {
            Issue.record("expected a no-stored-path reason")
            return
        }
    }
}
