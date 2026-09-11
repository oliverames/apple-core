// SPDX-License-Identifier: GPL-3.0-or-later
//
// Running a search against the index, read-only.
//
// This is an extension on MailIndexStore rather than an edit to it: the
// storage file owns writing and reconciliation, and the query path can be
// read, reviewed and changed on its own. It opens the index with
// SQLITE_OPEN_READONLY, which is not decoration — a search must not create,
// migrate or lock the index as a side effect of being asked a question, and
// it must never write to Mail's own storage, which it does not open at all.
//
// The executor asks for one row more than the page size. That extra row is
// the only thing it needs to distinguish "this is the last page" from "there
// is more", and it is cheaper and more truthful than a COUNT over a live
// index that may change before the next page is asked for.

import Foundation
import SQLite3

private let searchTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One search result, carrying its own cursor so a client can resume from any
/// row it has actually seen rather than only from the end of a page.
struct MailSearchHit: Sendable, Equatable, Codable {
    let stableID: String
    let accountID: String
    let mailbox: String
    /// `account/mailbox`, the vocabulary the index itself uses.
    let mailboxKey: String
    let emlxID: String
    let messageID: String?
    let subject: String
    let sender: String
    let recipients: [String]
    let dateSent: String?
    let isRead: Bool
    let isFlagged: Bool
    let attachmentCount: Int
    /// False when the body is not fully on this Mac, which also means the
    /// body text was not available to match against.
    let bodyComplete: Bool
    let bodyUnavailableReason: String?
    let isPartial: Bool
    let snippet: String?
    let cursor: String
}

struct MailSearchResult: Sendable, Equatable {
    let hits: [MailSearchHit]
    let hasMore: Bool
    let nextCursor: String?
    /// Messages excluded purely because they have no parsable date, when a
    /// date filter was applied. Nil when no date filter was applied.
    let undatedExcluded: Int?
}

extension MailIndexStore {
    /// Runs one page of a search. Never writes, and never opens Mail's store.
    func search(_ request: MailSearchRequest) throws -> MailSearchResult {
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw MailIndexStoreError.cannotOpen(detail)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5_000)

        let statement = try MailSearchQuery.page(request)
        let rows = try run(statement, on: handle, request: request)
        let limit = max(1, request.limit)
        let hasMore = rows.count > limit
        let page = Array(rows.prefix(limit))

        var undated: Int?
        if let counter = try MailSearchQuery.undatedExcluded(request) {
            undated = try scalar(counter, on: handle)
        }

        return MailSearchResult(
            hits: page,
            hasMore: hasMore,
            nextCursor: hasMore ? page.last?.cursor : nil,
            undatedExcluded: undated
        )
    }

    // MARK: - Execution

    private func run(
        _ statement: MailSearchStatement,
        on handle: OpaquePointer,
        request: MailSearchRequest
    ) throws -> [MailSearchHit] {
        var prepared: OpaquePointer?
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_prepare_v2(handle, statement.sql, -1, &prepared, nil) == SQLITE_OK else {
            throw MailIndexStoreError.statementFailed(
                "the search could not be prepared (\(String(cString: sqlite3_errmsg(handle))))."
            )
        }
        bind(statement.bindings, to: prepared)

        var hits: [MailSearchHit] = []
        let formatter = ISO8601DateFormatter()
        while sqlite3_step(prepared) == SQLITE_ROW {
            let date =
                sqlite3_column_type(prepared, 8) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(prepared, 8))
            let stableID = Self.string(prepared, 0) ?? ""
            let accountID = Self.string(prepared, 1) ?? ""
            let mailbox = Self.string(prepared, 2) ?? ""
            let body = sqlite3_column_count(prepared) > 15 ? Self.string(prepared, 15) : nil
            hits.append(
                MailSearchHit(
                    stableID: stableID,
                    accountID: accountID,
                    mailbox: mailbox,
                    mailboxKey: "\(accountID)/\(mailbox)",
                    emlxID: Self.string(prepared, 3) ?? "",
                    messageID: Self.string(prepared, 4),
                    subject: Self.string(prepared, 5) ?? "",
                    sender: Self.string(prepared, 6) ?? "",
                    recipients: (Self.string(prepared, 7) ?? "")
                        .split(separator: "\n").map(String.init),
                    dateSent: date.map { formatter.string(from: $0) },
                    isRead: sqlite3_column_int(prepared, 9) != 0,
                    isFlagged: sqlite3_column_int(prepared, 10) != 0,
                    attachmentCount: Int(sqlite3_column_int(prepared, 11)),
                    bodyComplete: sqlite3_column_int(prepared, 12) != 0,
                    bodyUnavailableReason: Self.string(prepared, 13),
                    isPartial: sqlite3_column_int(prepared, 14) != 0,
                    snippet: body.flatMap {
                        MailSearchQuery.snippet(body: $0, query: request.query)
                    },
                    cursor: MailSearchCursor(dateSent: date, stableID: stableID).token
                )
            )
        }
        return hits
    }

    private func scalar(_ statement: MailSearchStatement, on handle: OpaquePointer) throws -> Int {
        var prepared: OpaquePointer?
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_prepare_v2(handle, statement.sql, -1, &prepared, nil) == SQLITE_OK else {
            throw MailIndexStoreError.statementFailed(
                "the search could not be counted (\(String(cString: sqlite3_errmsg(handle))))."
            )
        }
        bind(statement.bindings, to: prepared)
        guard sqlite3_step(prepared) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(prepared, 0))
    }

    private func bind(_ bindings: [MailSearchBinding], to statement: OpaquePointer?) {
        for (offset, binding) in bindings.enumerated() {
            let position = Int32(offset + 1)
            switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, position, value, -1, searchTransient)
            case let .double(value):
                sqlite3_bind_double(statement, position, value)
            case let .int(value):
                sqlite3_bind_int64(statement, position, Int64(value))
            }
        }
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
