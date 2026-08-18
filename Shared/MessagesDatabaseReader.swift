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
    let name: String?
    let mimeType: String?
    let uti: String?
    let sizeBytes: Int
    let isSticker: Bool
    let chatGUID: String?
    let messageGUID: String?
    let created: Date?
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
        // immutable=1 avoids taking a lock on a database Messages.app is
        // actively writing, and avoids creating -wal/-shm sidecars we would
        // have no business creating in the user's Library.
        let uri = "file:\(path)?immutable=1"
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

    /// Attachments, newest first, optionally limited to one chat.
    func attachments(chatGUID: String?, limit: Int) throws -> [MessageAttachment] {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("attachment", in: handle), tableExists("message_attachment_join", in: handle) else {
            throw MessagesDatabaseReaderError.schemaMissing("the attachment table")
        }

        var sql = """
            SELECT a.transfer_name, a.mime_type, a.uti, a.total_bytes, a.is_sticker,
                   c.guid, m.guid, a.created_date
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            """
        if chatGUID != nil { sql += "\nWHERE c.guid = ?" }
        sql += "\nORDER BY a.created_date DESC\nLIMIT ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseReaderError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }

        var index: Int32 = 1
        if let chatGUID {
            sqlite3_bind_text(statement, index, chatGUID, -1, sqliteTransient)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(limit))

        var results: [MessageAttachment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                MessageAttachment(
                    name: Self.text(statement, 0),
                    mimeType: Self.text(statement, 1),
                    uti: Self.text(statement, 2),
                    sizeBytes: Int(sqlite3_column_int64(statement, 3)),
                    isSticker: sqlite3_column_int(statement, 4) == 1,
                    chatGUID: Self.text(statement, 5),
                    messageGUID: Self.text(statement, 6),
                    created: Self.date(fromAppleNanoseconds: sqlite3_column_int64(statement, 7))
                )
            )
        }
        return results
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
}
