import Foundation
import SQLite3
import Testing

/// Exercises the chat.db queries against a database built to the same schema
/// subset, so the SQL and the column bindings are verified without depending
/// on whatever happens to be in the developer's own Messages history.
@Suite("Messages database reader")
struct MessagesDatabaseReaderTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Builds the tables and joins the reader queries touch, populated with
    /// one unread incoming message, one read one, one outgoing, and two
    /// attachments across two chats.
    private static func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-chatdb-\(UUID().uuidString).sqlite")

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        let schema = """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, is_read INTEGER, is_from_me INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, transfer_name TEXT, mime_type TEXT,
                uti TEXT, total_bytes INTEGER, is_sticker INTEGER, created_date INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

            INSERT INTO chat VALUES (1, 'chat-alpha', 'Alpha'), (2, 'chat-beta', '');
            -- two unread incoming in alpha, one read incoming, one unread outgoing
            INSERT INTO message VALUES (1, 'm1', 0, 0), (2, 'm2', 0, 0), (3, 'm3', 1, 0), (4, 'm4', 0, 1);
            -- one unread incoming in beta
            INSERT INTO message VALUES (5, 'm5', 0, 0);
            INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(2,5);

            INSERT INTO attachment VALUES
                (1, 'photo.heic', 'image/heic', 'public.heic', 2048, 0, 700000000000000000),
                (2, 'sticker.png', 'image/png', 'public.png', 512, 1, 800000000000000000);
            INSERT INTO message_attachment_join VALUES (1,1),(5,2);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        return url
    }

    @Test("Unread counts only include incoming messages, busiest chat first")
    func unreadCountsExcludeOutgoing() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let counts = try MessagesDatabaseReader(path: url.path).unreadCounts(limit: 10)

        #expect(counts.count == 2)
        // Alpha has two unread incoming. Its third message is read and its
        // fourth is outgoing-and-unread, neither of which should be counted.
        #expect(counts[0].chatGUID == "chat-alpha")
        #expect(counts[0].unreadCount == 2)
        #expect(counts[0].displayName == "Alpha")
        #expect(counts[1].unreadCount == 1)
        // An empty display_name is reported as absent rather than as "".
        #expect(counts[1].displayName == nil)
    }

    @Test("The unread total is not truncated by the per-conversation limit")
    func totalUnreadIgnoresLimit() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        // Three unread incoming messages exist in total; a limit of one
        // conversation used to make callers sum just that page.
        #expect(try reader.totalUnreadCount() == 3)
        #expect(try reader.unreadCounts(limit: 1).count == 1)
    }

    @Test("Attachments come back newest first with their metadata")
    func attachmentsAreListedNewestFirst() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let all = try MessagesDatabaseReader(path: url.path).attachments(chatGUID: nil, limit: 10)

        #expect(all.count == 2)
        #expect(all[0].name == "sticker.png")
        #expect(all[0].isSticker)
        #expect(all[1].name == "photo.heic")
        #expect(all[1].mimeType == "image/heic")
        #expect(all[1].sizeBytes == 2048)
        #expect(all[1].chatGUID == "chat-alpha")
        #expect(all[1].created != nil)
    }

    @Test("Filtering by chat returns only that conversation's attachments")
    func attachmentsCanBeFilteredByChat() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let alpha = try MessagesDatabaseReader(path: url.path)
            .attachments(chatGUID: "chat-alpha", limit: 10)

        #expect(alpha.count == 1)
        #expect(alpha[0].name == "photo.heic")
    }

    @Test("A database missing the expected tables reports a reason, not a crash")
    func missingSchemaIsReported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-empty-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_close(handle)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try MessagesDatabaseReader(path: url.path).attachments(chatGUID: nil, limit: 10)
        }
    }
}
