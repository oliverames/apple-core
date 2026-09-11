// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apple Core's own index of Mail's local store.
//
// This is a separate artifact, kept beside the template store at
// ~/.config/apple-core/mail-index.sqlite with 0600 permissions, and
// APPLECORE_CONFIG_HOME moves it so tests never touch the real one. Mail's
// own storage is opened read-only and never written, locked or migrated; if
// this file is deleted the next refresh rebuilds it and nothing is lost.
//
// The schema carries a version. A database written by a newer build, or by a
// version of this code whose columns have moved, is discarded and rebuilt
// rather than read through guesses — the same posture the Messages and Notes
// readers take toward Apple's schemas, applied to our own.
//
// Full-text search lives here as an FTS5 table but is not yet exposed as a
// tool. The search contract is issue #3; this file is the storage it will sit
// on. When FTS5 is missing the index still builds and reports that matching
// on bodies is unavailable, rather than failing to index at all.

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One indexed message, as clients see it.
struct MailIndexedMessage: Sendable, Equatable, Codable {
    let stableID: String
    let accountID: String
    let mailbox: String
    let emlxID: String
    let messageID: String?
    let subject: String
    let sender: String
    let recipients: [String]
    let dateSent: Date?
    let isRead: Bool
    let isFlagged: Bool
    let attachmentCount: Int
    /// False for a message whose body is not fully on this Mac, or whose body
    /// this index could not decode. `bodyUnavailableReason` says which.
    let bodyComplete: Bool
    let bodyUnavailableReason: String?
    let isPartial: Bool
}

enum MailIndexStoreError: LocalizedError, Equatable {
    case cannotOpen(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(detail):
            return "INDEX_UNAVAILABLE: Apple Core's mail index could not be opened (\(detail))."
        case let .statementFailed(detail):
            return "INDEX_WRITE_FAILED: \(detail)"
        }
    }
}

struct MailIndexStore: Sendable {
    /// Bumped whenever the columns below change. A mismatch rebuilds.
    static let schemaVersion = 1

    let fileURL: URL

    /// `~/.config/apple-core/mail-index.sqlite`, or the same file under
    /// `APPLECORE_CONFIG_HOME`. Resolved per call for the same reason the
    /// template store resolves per call: a test has to be able to redirect it.
    static var `default`: MailIndexStore {
        let configDirectory: URL
        if let override = ProcessInfo.processInfo.environment["APPLECORE_CONFIG_HOME"],
            !override.isEmpty
        {
            configDirectory = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/apple-core", isDirectory: true)
        }
        return MailIndexStore(
            fileURL: configDirectory.appendingPathComponent("mail-index.sqlite")
        )
    }

    // MARK: - Connection

    private func open() throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw MailIndexStoreError.cannotOpen(detail)
        }
        sqlite3_busy_timeout(handle, 5_000)
        return handle
    }

    private func exec(_ sql: String, on handle: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown error"
            if let error { sqlite3_free(error) }
            throw MailIndexStoreError.statementFailed(detail)
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    /// Creates the schema, rebuilding from scratch when the stored version is
    /// not the one this build writes.
    @discardableResult
    func prepare() throws -> Bool {
        var handle = try open()
        var rebuilt = false
        let stored = try? version(on: handle)
        if let stored, stored != Self.schemaVersion {
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: fileURL)
            handle = try open()
            rebuilt = true
        }
        defer { sqlite3_close(handle) }

        try exec(
            """
            CREATE TABLE IF NOT EXISTS messages (
                stable_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                emlx_id TEXT NOT NULL,
                path TEXT NOT NULL,
                message_id TEXT,
                subject TEXT NOT NULL DEFAULT '',
                sender TEXT NOT NULL DEFAULT '',
                recipients TEXT NOT NULL DEFAULT '',
                date_sent REAL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                modified REAL NOT NULL DEFAULT 0,
                is_partial INTEGER NOT NULL DEFAULT 0,
                is_read INTEGER NOT NULL DEFAULT 0,
                is_flagged INTEGER NOT NULL DEFAULT 0,
                attachment_count INTEGER NOT NULL DEFAULT 0,
                body_complete INTEGER NOT NULL DEFAULT 0,
                body_reason TEXT,
                raw_headers TEXT NOT NULL DEFAULT '',
                indexed_at REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS messages_message_id ON messages(message_id);
            CREATE INDEX IF NOT EXISTS messages_mailbox ON messages(account_id, mailbox);
            CREATE INDEX IF NOT EXISTS messages_date ON messages(date_sent);
            CREATE TABLE IF NOT EXISTS issues (
                path TEXT PRIMARY KEY,
                reason TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """,
            on: handle
        )
        // Body matching is a bonus, not a precondition. A SQLite without FTS5
        // leaves the table absent and the index still builds.
        try? exec(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                stable_id UNINDEXED, subject, sender, body
            );
            """,
            on: handle
        )
        try exec("PRAGMA user_version = \(Self.schemaVersion);", on: handle)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return rebuilt
    }

    private func version(on handle: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Whether body matching will be possible once a search contract exists.
    var fullTextAvailable: Bool {
        guard let handle = try? open() else { return false }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM sqlite_master WHERE name='messages_fts' LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Reads

    /// Every row, in the reduced shape reconciliation works on.
    func entries() throws -> [MailIndexEntry] {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT stable_id, account_id, mailbox, message_id, size_bytes, modified, is_partial
            FROM messages
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var rows: [MailIndexEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                MailIndexEntry(
                    stableID: Self.text(statement, 0) ?? "",
                    accountID: Self.text(statement, 1) ?? "",
                    mailbox: Self.text(statement, 2) ?? "",
                    messageID: Self.text(statement, 3),
                    sizeBytes: Int(sqlite3_column_int64(statement, 4)),
                    modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    isPartial: sqlite3_column_int(statement, 6) != 0
                )
            )
        }
        return rows
    }

    /// Indexed messages, newest first. Mailbox is `account/mailbox` as the
    /// scan reports it; omitted, the whole index is paged.
    func messages(inMailbox mailbox: String? = nil, limit: Int = 50, offset: Int = 0) throws
        -> [MailIndexedMessage]
    {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var sql = """
            SELECT stable_id, account_id, mailbox, emlx_id, message_id, subject, sender,
                   recipients, date_sent, is_read, is_flagged, attachment_count,
                   body_complete, body_reason, is_partial
            FROM messages
            """
        // Either the full "account/mailbox" key the index reports, or the
        // mailbox path on its own, which is how a person names INBOX without
        // knowing Mail's account directory UUID.
        if mailbox != nil {
            sql += " WHERE (account_id || '/' || mailbox) = ?1 COLLATE NOCASE"
            sql += " OR mailbox = ?1 COLLATE NOCASE"
        }
        sql += " ORDER BY date_sent DESC, stable_id ASC LIMIT ? OFFSET ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var position: Int32 = 1
        if let mailbox {
            sqlite3_bind_text(statement, position, mailbox, -1, sqliteTransient)
            position += 1
        }
        sqlite3_bind_int(statement, position, Int32(max(0, limit)))
        sqlite3_bind_int(statement, position + 1, Int32(max(0, offset)))

        var rows: [MailIndexedMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dateValue =
                sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            rows.append(
                MailIndexedMessage(
                    stableID: Self.text(statement, 0) ?? "",
                    accountID: Self.text(statement, 1) ?? "",
                    mailbox: Self.text(statement, 2) ?? "",
                    emlxID: Self.text(statement, 3) ?? "",
                    messageID: Self.text(statement, 4),
                    subject: Self.text(statement, 5) ?? "",
                    sender: Self.text(statement, 6) ?? "",
                    recipients: (Self.text(statement, 7) ?? "")
                        .split(separator: "\n").map(String.init),
                    dateSent: dateValue,
                    isRead: sqlite3_column_int(statement, 9) != 0,
                    isFlagged: sqlite3_column_int(statement, 10) != 0,
                    attachmentCount: Int(sqlite3_column_int(statement, 11)),
                    bodyComplete: sqlite3_column_int(statement, 12) != 0,
                    bodyUnavailableReason: Self.text(statement, 13),
                    isPartial: sqlite3_column_int(statement, 14) != 0
                )
            )
        }
        return rows
    }

    /// Every `account/mailbox` key the index holds, which is the vocabulary
    /// a caller has to use to scope a read. Mail's account directories are
    /// UUIDs on disk, so this is the only place the names come from without
    /// going back through Apple Events.
    func mailboxKeys() throws -> [String] {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT DISTINCT account_id || '/' || mailbox FROM messages ORDER BY 1
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = Self.text(statement, 0) { keys.append(key) }
        }
        return keys
    }

    func counts() throws -> (messages: Int, partial: Int, mailboxes: Int, accounts: Int) {
        let handle = try open()
        defer { sqlite3_close(handle) }
        func scalar(_ sql: String) -> Int {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW
            else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
        return (
            messages: scalar("SELECT COUNT(*) FROM messages"),
            partial: scalar("SELECT COUNT(*) FROM messages WHERE body_complete = 0"),
            mailboxes: scalar("SELECT COUNT(DISTINCT account_id || '/' || mailbox) FROM messages"),
            accounts: scalar("SELECT COUNT(DISTINCT account_id) FROM messages")
        )
    }

    func issues(limit: Int = 10) throws -> [MailIndexIssue] {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT path, reason FROM issues ORDER BY path LIMIT ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        var rows: [MailIndexIssue] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                MailIndexIssue(
                    path: Self.text(statement, 0) ?? "",
                    reason: Self.text(statement, 1) ?? ""
                )
            )
        }
        return rows
    }

    func issueCount() throws -> Int {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM issues", -1, &statement, nil)
                == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func metadata(_ key: String) throws -> String? {
        let handle = try open()
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT value FROM meta WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.text(statement, 0)
    }

    // MARK: - Writes

    /// Applies one reconciliation plan as a single transaction.
    ///
    /// Removals and insertions land together, so a moved message is never
    /// both in two mailboxes and never in none, whatever happens between
    /// passes. `documents` holds the parse of every inserted and updated
    /// file, keyed by stable id; a file missing from it is skipped and
    /// belongs in `issues` instead.
    func apply(
        plan: MailIndexPlan,
        documents: [String: MailEmlxDocument],
        issues: [MailIndexIssue],
        scanComplete: Bool,
        now: Date = Date()
    ) throws {
        let handle = try open()
        defer { sqlite3_close(handle) }
        try exec("BEGIN IMMEDIATE;", on: handle)
        do {
            for stableID in plan.removedIDs {
                try delete(stableID: stableID, on: handle)
            }
            for file in plan.inserted + plan.updated {
                guard let document = documents[file.stableID] else { continue }
                try upsert(file: file, document: document, now: now, on: handle)
            }
            try exec("DELETE FROM issues;", on: handle)
            for issue in issues {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                let sql = "INSERT OR REPLACE INTO issues (path, reason) VALUES (?, ?)"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    continue
                }
                sqlite3_bind_text(statement, 1, issue.path, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, issue.reason, -1, sqliteTransient)
                _ = sqlite3_step(statement)
            }
            // Only a pass that saw the whole store may claim to be a complete
            // refresh. A truncated one still records its time, under a key
            // that says what it was.
            try setMetadata(
                scanComplete ? "last_complete_refresh" : "last_partial_refresh",
                String(now.timeIntervalSince1970),
                on: handle
            )
            try setMetadata("last_refresh", String(now.timeIntervalSince1970), on: handle)
            try exec("COMMIT;", on: handle)
        } catch {
            try? exec("ROLLBACK;", on: handle)
            throw error
        }
    }

    private func setMetadata(_ key: String, _ value: String, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MailIndexStoreError.statementFailed("could not record \(key)")
        }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MailIndexStoreError.statementFailed("could not record \(key)")
        }
    }

    private func delete(stableID: String, on handle: OpaquePointer) throws {
        for sql in [
            "DELETE FROM messages WHERE stable_id = ?",
            "DELETE FROM messages_fts WHERE stable_id = ?",
        ] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, stableID, -1, sqliteTransient)
            _ = sqlite3_step(statement)
        }
    }

    private func upsert(
        file: MailScannedMessageFile,
        document: MailEmlxDocument,
        now: Date,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO messages (
                stable_id, account_id, mailbox, emlx_id, path, message_id, subject, sender,
                recipients, date_sent, size_bytes, modified, is_partial, is_read, is_flagged,
                attachment_count, body_complete, body_reason, raw_headers, indexed_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MailIndexStoreError.statementFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, file.stableID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, file.accountID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, file.mailbox, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, file.emlxID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, file.path, -1, sqliteTransient)
        if let messageID = document.messageID {
            sqlite3_bind_text(statement, 6, messageID, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_text(statement, 7, document.subject, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, document.sender, -1, sqliteTransient)
        sqlite3_bind_text(
            statement,
            9,
            document.recipients.joined(separator: "\n"),
            -1,
            sqliteTransient
        )
        if let date = document.dateSent {
            sqlite3_bind_double(statement, 10, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_int64(statement, 11, Int64(file.sizeBytes))
        sqlite3_bind_double(statement, 12, file.modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 13, file.isPartial ? 1 : 0)
        sqlite3_bind_int(statement, 14, document.flags.isRead ? 1 : 0)
        sqlite3_bind_int(statement, 15, document.flags.isFlagged ? 1 : 0)
        sqlite3_bind_int(statement, 16, Int32(document.flags.attachmentCount))
        sqlite3_bind_int(statement, 17, document.bodyIsComplete ? 1 : 0)
        if let reason = document.bodyUnavailableReason {
            sqlite3_bind_text(statement, 18, reason, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 18)
        }
        sqlite3_bind_text(statement, 19, document.rawHeaders, -1, sqliteTransient)
        sqlite3_bind_double(statement, 20, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MailIndexStoreError.statementFailed(String(cString: sqlite3_errmsg(handle)))
        }
        try indexText(file: file, document: document, on: handle)
    }

    private func indexText(
        file: MailScannedMessageFile,
        document: MailEmlxDocument,
        on handle: OpaquePointer
    ) throws {
        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            handle,
            "DELETE FROM messages_fts WHERE stable_id = ?",
            -1,
            &deleteStatement,
            nil
        ) == SQLITE_OK {
            sqlite3_bind_text(deleteStatement, 1, file.stableID, -1, sqliteTransient)
            _ = sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO messages_fts (stable_id, subject, sender, body) VALUES (?,?,?,?)
            """
        // No FTS5 in this SQLite means no body matching, which the status
        // reports. It is not a reason to fail the refresh.
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, file.stableID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, document.subject, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, document.sender, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, document.bodyText, -1, sqliteTransient)
        _ = sqlite3_step(statement)
    }
}
