// SPDX-License-Identifier: GPL-3.0-or-later
//
// Direct chat.db reads for the fields madrid does not model.
//
// The Messages surface reads through loopwork-ai/madrid, whose `Message` type
// carries id, text, date, isFromMe and sender — and nothing else. Attachments,
// read state and per-chat unread counts all live in chat.db but never reach
// the surface through that model.
//
// This is not a new architecture: MessageService already opens chat.db, holds
// a security-scoped bookmark for it, and prompts the user for access. This
// reuses the same resolved path and adds a second read-only connection for the
// columns madrid skips, rather than forking madrid or waiting on upstream.
//
// Every query here is read-only and defensive. chat.db is Apple's private
// schema and changes between releases, so a missing table or column returns
// an empty result with a reason rather than throwing the surface down.

import Foundation
import SQLite3

/// SQLite hands back pointers it owns and will free; copying is required.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct MessageAttachment: Sendable {
    /// Stable across restarts and across re-listing: `attachment.guid` when
    /// chat.db carries one, else the row id. Clients hold on to this and pass
    /// it back to fetch the bytes, so it must not be derived from position.
    let id: String
    let name: String?
    let mimeType: String?
    let uti: String?
    let sizeBytes: Int
    let isSticker: Bool
    let chatGUID: String?
    let messageGUID: String?
    let created: Date?
    /// The on-disk location chat.db recorded, usually `~/Library/Messages/...`.
    /// Tilde-prefixed as stored; expansion and containment checks happen in
    /// `MessagesAttachmentContent`, not here.
    let storedPath: String?
}

/// The per-message columns `madrid` does not model, keyed by message GUID.
///
/// Everything here is read from `message` in one pass for a page of GUIDs, so
/// enriching a fetched page costs a single extra query rather than one per
/// message.
struct MessageMetadata: Sendable {
    let guid: String
    let service: String?
    let isRead: Bool
    let dateRead: Date?
    let dateDelivered: Date?
    let subject: String?
    let annotation: MessageAnnotation
    /// The GUID of the message this one replies to, when chat.db recorded an
    /// inline reply. Distinct from a tapback target.
    let replyToGUID: String?
    let expressiveSendStyle: String?
    /// The bundle identifier of the iMessage app that produced this message,
    /// for an Apple Cash payment or a third-party app message.
    let balloonBundleID: String?
    let attachmentNames: [String]
}

/// One conversation, keyed by the GUID that never changes when the group is
/// renamed or its membership shifts. Two conversations with identical
/// participants differ here even though their participant lists do not.
struct MessagesChatSummary: Sendable {
    let chatGUID: String
    let displayName: String?
    let chatIdentifier: String?
    let serviceName: String?
    let participants: [String]
    let lastMessageDate: Date?
    let messageCount: Int

    var isGroup: Bool { participants.count > 1 }
}

/// Everything `messages_attachments` can narrow by. All optional; an empty
/// filter lists the newest attachments across every conversation.
struct MessageAttachmentFilter: Sendable {
    var chatGUID: String?
    /// Already-resolved handle ids (see `participantHandles(matching:)`).
    var participantHandles: [String] = []
    /// Matched case-insensitively as an exact type ("image/png") or as a
    /// prefix when it ends in "/" ("image/").
    var mimeType: String?
    var start: Date?
    var end: Date?
    var limit: Int = 50
    var offset: Int = 0

    init(
        chatGUID: String? = nil,
        participantHandles: [String] = [],
        mimeType: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.chatGUID = chatGUID
        self.participantHandles = participantHandles
        self.mimeType = mimeType
        self.start = start
        self.end = end
        self.limit = limit
        self.offset = offset
    }
}

/// Trims a fetched page to a window the caller asked for.
///
/// Paging happens after text and participant filtering rather than in SQL,
/// because those filters run in Swift; applying OFFSET in the query would
/// skip rows that the filter was about to drop anyway and silently lose
/// messages from the window the client asked for.
func messagesPage<T>(_ items: [T], offset: Int, limit: Int) -> [T] {
    let start = max(offset, 0)
    guard start < items.count, limit > 0 else { return [] }
    let end = min(items.count, start + limit)
    return Array(items[start ..< end])
}

struct ChatUnreadCount: Sendable {
    let chatGUID: String
    let displayName: String?
    let unreadCount: Int
}

enum MessagesDatabaseReaderError: LocalizedError {
    case cannotOpen(String)
    case schemaMissing(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(detail):
            return "Could not read the Messages database: \(detail)"
        case let .schemaMissing(what):
            return
                "This version of macOS stores Messages differently than expected (\(what) is missing), "
                + "so that information is unavailable."
        }
    }
}

/// Opens chat.db read-only for the columns madrid does not expose.
struct MessagesDatabaseReader {
    let path: String

    /// Apple stores message dates as nanoseconds since 2001-01-01.
    private static let appleEpoch = Date(timeIntervalSince1970: 978_307_200)

    private func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        // A normal read-only connection participates in WAL snapshot reads.
        // `immutable=1` ignored committed rows still present in chat.db-wal.
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw MessagesDatabaseReaderError.cannotOpen(detail)
        }
        return handle
    }

    private func tableExists(_ name: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func date(fromAppleNanoseconds raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        // Pre-High Sierra rows are in seconds, not nanoseconds. The magnitude
        // is the only way to tell them apart.
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return appleEpoch.addingTimeInterval(seconds)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    /// Resolves participant aliases without Madrid's unescaped suffix LIKE.
    /// Filtering happens before the limit, so `_` and `%` in valid addresses
    /// cannot fill the result window with unrelated handles.
    func participantHandles(matching aliases: [String], limit: Int = 100) throws -> [String] {
        guard !aliases.isEmpty else { return [] }
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("handle", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the handle table")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id, uncanonicalized_id FROM handle WHERE id IS NOT NULL"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.schemaMissing("the handle columns")
        }

        var matches: [String] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, matches.count < max(limit, 1) {
            guard let identifier = Self.text(statement, 0) else { continue }
            let uncanonicalized = Self.text(statement, 1)
            guard
                messageHandle(identifier, matchesAny: aliases)
                    || uncanonicalized.map({ messageHandle($0, matchesAny: aliases) }) == true
            else {
                continue
            }
            if seen.insert(identifier).inserted {
                matches.append(identifier)
            }
        }
        return matches
    }

    /// What chat.db records about the addresses matching `aliases`: the
    /// service each handle is registered under, how much traffic it has, and
    /// the service of the most recent outgoing message.
    ///
    /// Read-only and bounded. Nothing here sends or prepares a send; the
    /// routing prediction built on top of it lives in
    /// `MessagesRouteDiagnostic`.
    func routeObservations(matching aliases: [String], limit: Int = 20) throws
        -> [MessagesRouteObservation]
    {
        guard !aliases.isEmpty else { return [] }
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("handle", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the handle table")
        }

        let hasService = columnExists("service", onTable: "handle", in: handle)
        let hasMessages =
            tableExists("message", in: handle)
            && columnExists("handle_id", onTable: "message", in: handle)
            && columnExists("date", onTable: "message", in: handle)
        let messageHasService = hasMessages && columnExists("service", onTable: "message", in: handle)
        let messageHasDirection =
            hasMessages && columnExists("is_from_me", onTable: "message", in: handle)

        // Matching happens in Swift, as it does for participant handles: the
        // alias forms a caller passes are not a SQL pattern.
        var rows: [(rowID: Int64, identifier: String, service: String?)] = []
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
                SELECT h.ROWID, h.id, \(hasService ? "h.service" : "NULL"), h.uncanonicalized_id
                FROM handle h WHERE h.id IS NOT NULL
                """
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw MessagesDatabaseReaderError.schemaMissing("the handle columns")
            }
            while sqlite3_step(statement) == SQLITE_ROW, rows.count < max(limit, 1) {
                guard let identifier = Self.text(statement, 1) else { continue }
                let uncanonicalized = Self.text(statement, 3)
                guard
                    messageHandle(identifier, matchesAny: aliases)
                        || uncanonicalized.map({ messageHandle($0, matchesAny: aliases) }) == true
                else { continue }
                rows.append(
                    (sqlite3_column_int64(statement, 0), identifier, Self.text(statement, 2))
                )
            }
        }

        return try rows.map { row in
            var count = 0
            var lastDate: Date?
            if hasMessages {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                let sql = """
                    SELECT COUNT(m.ROWID), MAX(\(Self.normalizedMessageSeconds))
                    FROM message m WHERE m.handle_id = ?
                    """
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw MessagesDatabaseReaderError.schemaMissing("the message columns")
                }
                sqlite3_bind_int64(statement, 1, row.rowID)
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(statement, 0))
                    if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                        lastDate = Self.date(fromAppleSeconds: sqlite3_column_int64(statement, 1))
                    }
                }
            }

            var lastOutgoing: String?
            if messageHasService, messageHasDirection {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                let sql = """
                    SELECT m.service FROM message m
                    WHERE m.handle_id = ? AND m.is_from_me = 1 AND m.service IS NOT NULL
                    ORDER BY m.date DESC LIMIT 1
                    """
                if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int64(statement, 1, row.rowID)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        lastOutgoing = Self.text(statement, 0)
                    }
                }
            }

            return MessagesRouteObservation(
                handle: row.identifier,
                registeredService: row.service,
                lastOutgoingService: lastOutgoing,
                lastMessageDate: lastDate,
                messageCount: count
            )
        }
    }

    /// Attachments, newest first, optionally limited to one chat.
    ///
    /// Kept as the narrow entry point the unread and listing paths already
    /// used; `attachments(matching:)` is the filtered form.
    func attachments(chatGUID: String?, limit: Int) throws -> [MessageAttachment] {
        try attachments(matching: MessageAttachmentFilter(chatGUID: chatGUID, limit: limit))
    }

    /// Attachments narrowed by chat, participants, MIME type and date,
    /// newest first, with the page the caller asked for.
    func attachments(matching filter: MessageAttachmentFilter) throws -> [MessageAttachment] {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("attachment", in: handle), tableExists("message_attachment_join", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the attachment table")
        }
        if !filter.participantHandles.isEmpty {
            guard tableExists("chat_handle_join", in: handle), tableExists("handle", in: handle) else {
                throw MessagesDatabaseReaderError.schemaMissing("the chat participant tables")
            }
        }

        var conditions: [String] = []
        var binders: [(OpaquePointer?, Int32) -> Void] = []

        if let chatGUID = filter.chatGUID {
            conditions.append("c.guid = ?")
            binders.append { statement, index in
                sqlite3_bind_text(statement, index, chatGUID, -1, sqliteTransient)
            }
        }
        if !filter.participantHandles.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.participantHandles.count)
                .joined(separator: ", ")
            conditions.append(
                """
                c.ROWID IN (
                    SELECT chj.chat_id FROM chat_handle_join chj
                    JOIN handle h ON h.ROWID = chj.handle_id
                    WHERE h.id IN (\(placeholders))
                )
                """
            )
            for participant in filter.participantHandles {
                binders.append { statement, index in
                    sqlite3_bind_text(statement, index, participant, -1, sqliteTransient)
                }
            }
        }
        if let mimeType = filter.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !mimeType.isEmpty
        {
            if mimeType.hasSuffix("/") || mimeType.hasSuffix("/*") {
                // "image/" and "image/*" both mean "every image type".
                let family = mimeType.hasSuffix("/*") ? String(mimeType.dropLast(1)) : mimeType
                let pattern = Self.escapedLikePrefix(family.lowercased()) + "%"
                conditions.append("LOWER(a.mime_type) LIKE ? ESCAPE '\\'")
                binders.append { statement, index in
                    sqlite3_bind_text(statement, index, pattern, -1, sqliteTransient)
                }
            } else {
                conditions.append("LOWER(a.mime_type) = ?")
                let exact = mimeType.lowercased()
                binders.append { statement, index in
                    sqlite3_bind_text(statement, index, exact, -1, sqliteTransient)
                }
            }
        }
        if let start = filter.start {
            let seconds = Self.appleSeconds(from: start)
            conditions.append("\(Self.normalizedCreatedSeconds) >= ?")
            binders.append { statement, index in
                sqlite3_bind_int64(statement, index, seconds)
            }
        }
        if let end = filter.end {
            let seconds = Self.appleSeconds(from: end)
            conditions.append("\(Self.normalizedCreatedSeconds) < ?")
            binders.append { statement, index in
                sqlite3_bind_int64(statement, index, seconds)
            }
        }

        let rows = try attachmentRows(
            in: handle,
            conditions: conditions,
            binders: binders,
            limit: max(filter.limit, 1),
            offset: max(filter.offset, 0)
        )
        return rows
    }

    /// One attachment by the identifier `attachments` handed out. Returns nil
    /// rather than throwing when nothing matches, so the caller can say which
    /// id was not found.
    func attachment(id: String) throws -> MessageAttachment? {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("attachment", in: handle), tableExists("message_attachment_join", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the attachment table")
        }

        let guidColumn = columnExists("guid", onTable: "attachment", in: handle) ? "a.guid" : "NULL"
        let conditions = ["(\(guidColumn) = ? OR CAST(a.ROWID AS TEXT) = ?)"]
        let binders: [(OpaquePointer?, Int32) -> Void] = [
            { statement, index in sqlite3_bind_text(statement, index, id, -1, sqliteTransient) },
            { statement, index in sqlite3_bind_text(statement, index, id, -1, sqliteTransient) },
        ]
        return try attachmentRows(
            in: handle,
            conditions: conditions,
            binders: binders,
            limit: 1,
            offset: 0
        ).first
    }

    /// Conversations, most recently active first.
    ///
    /// The GUID is the stable identifier: renaming a group changes
    /// `display_name` and leaves `guid` alone, and two conversations with
    /// identical participants keep distinct GUIDs.
    func chats(limit: Int, offset: Int = 0) throws -> [MessagesChatSummary] {
        try chats(limit: limit, offset: offset, guid: nil)
    }

    /// One conversation by GUID, or nil when no such chat exists.
    func chat(guid: String) throws -> MessagesChatSummary? {
        try chats(limit: 1, offset: 0, guid: guid).first
    }

    private func chats(limit: Int, offset: Int, guid: String?) throws -> [MessagesChatSummary] {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("chat", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the chat table")
        }

        let identifierColumn =
            columnExists("chat_identifier", onTable: "chat", in: handle) ? "c.chat_identifier" : "NULL"
        let serviceColumn =
            columnExists("service_name", onTable: "chat", in: handle) ? "c.service_name" : "NULL"
        let hasMessages =
            tableExists("message", in: handle)
            && tableExists("chat_message_join", in: handle)
            && columnExists("date", onTable: "message", in: handle)
        let lastDate = hasMessages ? "MAX(\(Self.normalizedMessageSeconds))" : "NULL"
        let messageJoin =
            hasMessages
            ? """
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = cmj.message_id
            """
            : ""
        let messageCount = hasMessages ? "COUNT(m.ROWID)" : "0"

        let sql = """
            SELECT c.guid, c.display_name, \(identifierColumn), \(serviceColumn),
                   \(lastDate), \(messageCount)
            FROM chat c
            \(messageJoin)
            \(guid == nil ? "" : "WHERE c.guid = ?")
            GROUP BY c.ROWID
            ORDER BY \(hasMessages ? "\(lastDate) DESC," : "") c.guid ASC
            LIMIT ? OFFSET ?
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        var index: Int32 = 1
        if let guid {
            sqlite3_bind_text(statement, index, guid, -1, sqliteTransient)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(limit, 1)))
        sqlite3_bind_int(statement, index + 1, Int32(max(offset, 0)))

        var rows: [(String, String?, String?, String?, Date?, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let chatGUID = Self.text(statement, 0) else { continue }
            let displayName = Self.text(statement, 1)
            let lastMessage =
                sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil : Self.date(fromAppleSeconds: sqlite3_column_int64(statement, 4))
            rows.append(
                (
                    chatGUID,
                    (displayName?.isEmpty ?? true) ? nil : displayName,
                    Self.text(statement, 2),
                    Self.text(statement, 3),
                    lastMessage,
                    Int(sqlite3_column_int64(statement, 5))
                )
            )
        }

        return try rows.map { row in
            MessagesChatSummary(
                chatGUID: row.0,
                displayName: row.1,
                chatIdentifier: row.2,
                serviceName: row.3,
                participants: try participants(ofChat: row.0, in: handle),
                lastMessageDate: row.4,
                messageCount: row.5
            )
        }
    }

    private func participants(ofChat guid: String, in handle: OpaquePointer) throws -> [String] {
        guard tableExists("chat_handle_join", in: handle), tableExists("handle", in: handle) else {
            return []
        }
        let sql = """
            SELECT h.id
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE c.guid = ? AND h.id IS NOT NULL
            ORDER BY h.id ASC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_text(statement, 1, guid, -1, sqliteTransient)

        var found: [String] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = Self.text(statement, 0) else { continue }
            if seen.insert(identifier).inserted { found.append(identifier) }
        }
        return found
    }

    /// The shared projection behind both attachment queries.
    private func attachmentRows(
        in handle: OpaquePointer,
        conditions: [String],
        binders: [(OpaquePointer?, Int32) -> Void],
        limit: Int,
        offset: Int
    ) throws -> [MessageAttachment] {
        let guidColumn = columnExists("guid", onTable: "attachment", in: handle) ? "a.guid" : "NULL"
        let filenameColumn =
            columnExists("filename", onTable: "attachment", in: handle) ? "a.filename" : "NULL"

        var sql = """
            SELECT a.transfer_name, a.mime_type, a.uti, a.total_bytes, a.is_sticker,
                   c.guid, m.guid, a.created_date, \(guidColumn), a.ROWID, \(filenameColumn)
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            """
        if !conditions.isEmpty {
            sql += "\nWHERE " + conditions.joined(separator: "\n  AND ")
        }
        sql += "\nORDER BY \(Self.normalizedCreatedSeconds) DESC, a.ROWID DESC\nLIMIT ? OFFSET ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }

        var index: Int32 = 1
        for bind in binders {
            bind(statement, index)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(limit))
        sqlite3_bind_int(statement, index + 1, Int32(offset))

        var results: [MessageAttachment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 9)
            let guid = Self.text(statement, 8)
            results.append(
                MessageAttachment(
                    id: (guid?.isEmpty ?? true) ? String(rowID) : guid!,
                    name: Self.text(statement, 0),
                    mimeType: Self.text(statement, 1),
                    uti: Self.text(statement, 2),
                    sizeBytes: Int(sqlite3_column_int64(statement, 3)),
                    isSticker: sqlite3_column_int(statement, 4) == 1,
                    chatGUID: Self.text(statement, 5),
                    messageGUID: Self.text(statement, 6),
                    created: Self.date(fromAppleNanoseconds: sqlite3_column_int64(statement, 7)),
                    storedPath: Self.text(statement, 10)
                )
            )
        }
        return results
    }

    private func columnExists(_ column: String, onTable table: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // PRAGMA does not take a bound parameter for the table name, and the
        // table names here are all compile-time constants from this file.
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if Self.text(statement, 1) == column { return true }
        }
        return false
    }

    /// chat.db holds nanoseconds on modern macOS and seconds on pre-High
    /// Sierra rows. Normalizing inside SQL keeps range filters and ordering
    /// correct across both, using the same magnitude test as `date(from:)`.
    private static let normalizedCreatedSeconds =
        "(CASE WHEN a.created_date > 1000000000000 THEN a.created_date / 1000000000 ELSE a.created_date END)"
    private static let normalizedMessageSeconds =
        "(CASE WHEN m.date > 1000000000000 THEN m.date / 1000000000 ELSE m.date END)"

    /// Per-message metadata for a page of GUIDs.
    ///
    /// Every column is checked for existence first: chat.db gained
    /// `associated_message_emoji`, `date_edited` and `date_retracted` in
    /// different releases, and a reader that assumes them fails whole on an
    /// older system instead of returning what it can.
    func messageMetadata(forGUIDs guids: [String]) throws -> [String: MessageMetadata] {
        guard !guids.isEmpty else { return [:] }
        let handle = try open()
        defer { sqlite3_close(handle) }
        guard tableExists("message", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the message table")
        }

        func column(_ name: String, default fallback: String = "NULL") -> String {
            columnExists(name, onTable: "message", in: handle) ? "m.\(name)" : fallback
        }

        let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
        let sql = """
            SELECT m.guid,
                   \(column("service")),
                   \(column("is_read", default: "0")),
                   \(column("date_read", default: "0")),
                   \(column("date_delivered", default: "0")),
                   \(column("subject")),
                   \(column("associated_message_type", default: "0")),
                   \(column("associated_message_guid")),
                   \(column("associated_message_emoji")),
                   \(column("item_type", default: "0")),
                   \(column("group_action_type", default: "0")),
                   \(column("group_title")),
                   \(column("date_edited", default: "0")),
                   \(column("date_retracted", default: "0")),
                   \(column("thread_originator_guid")),
                   \(column("reply_to_guid")),
                   \(column("expressive_send_style_id")),
                   \(column("balloon_bundle_id")),
                   \(column("text"))
            FROM message m
            WHERE m.guid IN (\(placeholders))
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        for (offset, guid) in guids.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), guid, -1, sqliteTransient)
        }

        let attachments = try attachmentNames(forGUIDs: guids, in: handle)

        var results: [String: MessageMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = Self.text(statement, 0) else { continue }
            let text = Self.text(statement, 18)
            let names = attachments[guid] ?? []
            let annotation = MessageAnnotator.annotate(
                MessageAnnotationInput(
                    associatedMessageType: Int(sqlite3_column_int64(statement, 6)),
                    associatedMessageGUID: Self.text(statement, 7),
                    associatedMessageEmoji: Self.text(statement, 8),
                    itemType: Int(sqlite3_column_int64(statement, 9)),
                    groupActionType: Int(sqlite3_column_int64(statement, 10)),
                    groupTitle: Self.text(statement, 11),
                    dateEdited: Self.date(fromAppleNanoseconds: sqlite3_column_int64(statement, 12)),
                    dateRetracted: Self.date(
                        fromAppleNanoseconds: sqlite3_column_int64(statement, 13)
                    ),
                    attachmentCount: names.count,
                    hasText: !(text?.isEmpty ?? true)
                )
            )
            // An inline reply records its parent in thread_originator_guid on
            // modern systems and reply_to_guid on older ones; either is the
            // message being replied to.
            let replyTo =
                MessageAnnotator.normalizedTargetGUID(Self.text(statement, 14))
                ?? MessageAnnotator.normalizedTargetGUID(Self.text(statement, 15))
            results[guid] = MessageMetadata(
                guid: guid,
                service: MessageServiceName.normalized(Self.text(statement, 1)),
                isRead: sqlite3_column_int64(statement, 2) == 1,
                dateRead: Self.date(fromAppleNanoseconds: sqlite3_column_int64(statement, 3)),
                dateDelivered: Self.date(fromAppleNanoseconds: sqlite3_column_int64(statement, 4)),
                subject: Self.text(statement, 5).flatMap { $0.isEmpty ? nil : $0 },
                annotation: annotation,
                replyToGUID: replyTo,
                expressiveSendStyle: Self.text(statement, 16),
                balloonBundleID: Self.text(statement, 17),
                attachmentNames: names
            )
        }
        return results
    }

    private func attachmentNames(forGUIDs guids: [String], in handle: OpaquePointer) throws
        -> [String: [String]]
    {
        guard tableExists("attachment", in: handle),
            tableExists("message_attachment_join", in: handle)
        else { return [:] }
        let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
        let sql = """
            SELECT m.guid, COALESCE(a.transfer_name, a.mime_type, a.uti, '')
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            WHERE m.guid IN (\(placeholders))
            ORDER BY a.ROWID ASC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        for (offset, guid) in guids.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), guid, -1, sqliteTransient)
        }
        var found: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = Self.text(statement, 0) else { continue }
            found[guid, default: []].append(Self.text(statement, 1) ?? "")
        }
        return found
    }

    private static func appleSeconds(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince(appleEpoch).rounded(.down))
    }

    private static func date(fromAppleSeconds raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        return appleEpoch.addingTimeInterval(Double(raw))
    }

    /// Escapes the LIKE metacharacters so a MIME filter such as "image_/x"
    /// cannot widen the match.
    private static func escapedLikePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Unread counts per chat, busiest first. Only counts incoming messages —
    /// an unread flag on something the user sent is not something to report.
    func unreadCounts(limit: Int) throws -> [ChatUnreadCount] {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("message", in: handle), tableExists("chat", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the message table")
        }

        let sql = """
            SELECT c.guid, c.display_name, COUNT(*)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.is_read = 0 AND m.is_from_me = 0
            GROUP BY c.guid, c.display_name
            ORDER BY COUNT(*) DESC
            LIMIT ?
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [ChatUnreadCount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = Self.text(statement, 0) else { continue }
            let name = Self.text(statement, 1)
            results.append(
                ChatUnreadCount(
                    chatGUID: guid,
                    displayName: (name?.isEmpty ?? true) ? nil : name,
                    unreadCount: Int(sqlite3_column_int(statement, 2))
                )
            )
        }
        return results
    }

    /// Total unread messages across every conversation. Deliberately not
    /// derived from `unreadCounts(limit:)`: that query truncates to the
    /// busiest N chats, and summing the truncated page understated the
    /// total whenever more conversations than the limit held unreads.
    func totalUnreadCount() throws -> Int {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("message", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the message table")
        }

        let sql = """
            SELECT COUNT(*)
            FROM message m
            WHERE m.is_read = 0 AND m.is_from_me = 0
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
