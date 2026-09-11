// SPDX-License-Identifier: GPL-3.0-or-later
//
// Exact conversation targeting: the case participant filtering cannot answer.
//
// Two threads with the same two people in them are indistinguishable by
// participants, and a group's display name changes whenever someone renames
// it. The chat GUID is the only identifier that separates the first and
// survives the second, so these tests pin both properties against a fixture
// built to chat.db's schema rather than against anyone's real history.

import Foundation
import SQLite3
import Testing

@Suite("Messages chat targeting")
struct MessagesChatTargetingTests {
    private static func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-chats-\(UUID().uuidString).sqlite")

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        // Two conversations share both participants; a third is one-to-one.
        let schema = """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT,
                display_name TEXT, service_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                is_read INTEGER, is_from_me INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);

            INSERT INTO handle VALUES (1, '+15551110000', NULL), (2, 'friend@example.com', NULL);

            INSERT INTO chat VALUES
                (1, 'iMessage;+;chat-planning', 'chat-planning', 'Planning', 'iMessage'),
                (2, 'iMessage;+;chat-lunch', 'chat-lunch', 'Lunch Crew', 'iMessage'),
                (3, 'iMessage;-;+15551110000', '+15551110000', '', 'iMessage');

            -- Identical membership in the first two chats.
            INSERT INTO chat_handle_join VALUES (1,1),(1,2),(2,1),(2,2),(3,1);

            INSERT INTO message VALUES
                (1, 'm1', 700000000000000000, 1, 0),
                (2, 'm2', 800000000000000000, 1, 0),
                (3, 'm3', 900000000000000000, 1, 0),
                (4, 'm4', 850000000000000000, 1, 1);
            INSERT INTO chat_message_join VALUES (1,1),(2,2),(2,4),(3,3);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        return url
    }

    private static func execute(_ sql: String, at url: URL) {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test("Two conversations with the same participants keep distinct ids")
    func overlappingParticipantsStayDistinct() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let chats = try MessagesDatabaseReader(path: url.path).chats(limit: 10)

        #expect(chats.count == 3)
        let sharedMembership = chats.filter {
            Set($0.participants) == Set(["+15551110000", "friend@example.com"])
        }
        #expect(sharedMembership.count == 2)
        // Same people, same display-name-free description: only the GUID tells
        // the two threads apart, which is why fetch takes one.
        #expect(Set(sharedMembership.map(\.chatGUID)).count == 2)
        let allAreGroups = sharedMembership.allSatisfy { $0.isGroup }
        #expect(allAreGroups)
    }

    @Test("Conversations come back most recently active first")
    func chatsAreOrderedByLastMessage() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let chats = try MessagesDatabaseReader(path: url.path).chats(limit: 10)

        #expect(
            chats.map(\.chatGUID) == [
                "iMessage;-;+15551110000",
                "iMessage;+;chat-lunch",
                "iMessage;+;chat-planning",
            ]
        )
        #expect(chats[0].lastMessageDate != nil)
        // The one-to-one chat has one participant and is not a group.
        #expect(chats[0].isGroup == false)
        #expect(chats[1].messageCount == 2)
    }

    @Test("An empty display name is reported as absent, not as an empty string")
    func emptyDisplayNameIsAbsent() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let chat = try MessagesDatabaseReader(path: url.path)
            .chat(guid: "iMessage;-;+15551110000")

        #expect(chat?.displayName == nil)
        #expect(chat?.chatIdentifier == "+15551110000")
        #expect(chat?.serviceName == "iMessage")
    }

    @Test("Renaming a group changes its name and not its id")
    func renamingAGroupKeepsItsIdentifier() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let before = try reader.chat(guid: "iMessage;+;chat-lunch")
        #expect(before?.displayName == "Lunch Crew")

        Self.execute(
            "UPDATE chat SET display_name = 'Friday Lunch' WHERE guid = 'iMessage;+;chat-lunch'",
            at: url
        )

        let after = try reader.chat(guid: "iMessage;+;chat-lunch")
        #expect(after?.displayName == "Friday Lunch")
        #expect(after?.chatGUID == before?.chatGUID)
        #expect(after?.participants == before?.participants)
    }

    @Test("An unknown chat id resolves to nothing rather than to a stray chat")
    func unknownChatIdentifierIsNotFound() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try MessagesDatabaseReader(path: url.path).chat(guid: "no-such-chat") == nil)
    }

    @Test("Paging through conversations covers each one exactly once")
    func chatPagingDoesNotRepeatOrSkip() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = MessagesDatabaseReader(path: url.path)

        let first = try reader.chats(limit: 2, offset: 0)
        let second = try reader.chats(limit: 2, offset: 2)
        let past = try reader.chats(limit: 2, offset: 10)

        #expect(first.count == 2)
        #expect(second.count == 1)
        #expect(past.isEmpty)
        let paged = (first + second).map(\.chatGUID)
        #expect(Set(paged).count == 3)
        let unpaged = try reader.chats(limit: 10).map(\.chatGUID)
        #expect(paged == unpaged)
    }

    @Test("A chat with no messages still lists, with no last-message date")
    func silentChatsAreStillListed() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        Self.execute(
            "INSERT INTO chat VALUES (4, 'iMessage;+;chat-quiet', 'chat-quiet', 'Quiet', 'iMessage')",
            at: url
        )

        let quiet = try MessagesDatabaseReader(path: url.path).chat(guid: "iMessage;+;chat-quiet")

        #expect(quiet != nil)
        #expect(quiet?.lastMessageDate == nil)
        #expect(quiet?.messageCount == 0)
        #expect(quiet?.participants.isEmpty == true)
    }

    @Test("Message paging trims to the requested window without falling off the end")
    func messagePagingClampsToAvailableItems() {
        let items = Array(1 ... 10)

        #expect(messagesPage(items, offset: 0, limit: 3) == [1, 2, 3])
        #expect(messagesPage(items, offset: 3, limit: 3) == [4, 5, 6])
        #expect(messagesPage(items, offset: 9, limit: 5) == [10])
        #expect(messagesPage(items, offset: 10, limit: 5).isEmpty)
        #expect(messagesPage(items, offset: -4, limit: 2) == [1, 2])
        #expect(messagesPage(items, offset: 0, limit: 0).isEmpty)
    }
}
