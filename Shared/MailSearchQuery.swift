// SPDX-License-Identifier: GPL-3.0-or-later
//
// The shape of a mail search, and the SQL it becomes.
//
// Everything here is pure: a request in, a statement and bindings out. The
// point of keeping it away from SQLite is that the two decisions most likely
// to go quietly wrong — how a page resumes, and what a user's words mean to
// FTS5 — can be tested directly rather than inferred from search results.
//
// Paging is keyset paging, never OFFSET. The index is live: a refresh can
// insert or remove rows between one page and the next, and an offset that
// pointed at row 50 then points at a different message now, so a client
// walking pages would skip or repeat. A cursor instead carries the sort key
// of the last row it saw — its date and its stable id — and the next page
// asks for rows strictly after that key. Rows appearing or disappearing
// before the cursor no longer move the boundary, and the cursor keeps working
// even when the message it names has since been deleted, because it is a
// position in an ordering rather than a reference to a row.
//
// The ordering is (date descending, stable id ascending) with undated
// messages last. Undated messages are a real state on disk — a file whose
// Date header is missing or unparsable — so they are ordered explicitly
// rather than left to whatever NULL sorting the database happens to do.

import Foundation

/// Which indexed text a query is matched against.
enum MailSearchScope: String, Sendable, Equatable, CaseIterable, Codable {
    case all
    case subject
    case sender
    case body
}

/// One bound value, kept typed so the executor does not have to guess.
enum MailSearchBinding: Sendable, Equatable {
    case text(String)
    case double(Double)
    case int(Int)
}

/// A prepared statement and the values it expects, in order.
struct MailSearchStatement: Sendable, Equatable {
    let sql: String
    let bindings: [MailSearchBinding]
}

/// A position in the result ordering, not a reference to a row.
///
/// `dateSent` is nil for a cursor inside the undated tail, which is a
/// different phase of the ordering and gets a different predicate.
struct MailSearchCursor: Sendable, Equatable {
    let dateSent: Date?
    let stableID: String

    private static let prefix = "mc1"

    /// Opaque to clients, but decodable here, and stable across builds.
    var token: String {
        // The seconds are written as the double's bit pattern in hex: it
        // round-trips exactly and, unlike a decimal, contains no "." to
        // confuse the token's own separator.
        let date = dateSent.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) } ?? "-"
        let encoded = Data(stableID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(Self.prefix).\(date).\(encoded)"
    }

    /// Returns nil for anything this build did not write, so a malformed or
    /// foreign cursor is refused rather than silently treated as "start over"
    /// — a silent restart is how a caller ends up re-reading page one forever.
    static func decode(_ token: String) -> MailSearchCursor? {
        let parts = token.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.prefix else { return nil }
        let date: Date?
        if parts[1] == "-" {
            date = nil
        } else if let bits = UInt64(parts[1], radix: 16) {
            date = Date(timeIntervalSince1970: Double(bitPattern: bits))
        } else {
            return nil
        }
        var encoded = parts[2]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded),
            let stableID = String(data: data, encoding: .utf8),
            !stableID.isEmpty
        else { return nil }
        return MailSearchCursor(dateSent: date, stableID: stableID)
    }
}

/// Everything a search asks for, already resolved: mailbox keys are index
/// keys, not display names, and the caller has already been told whether
/// body matching is possible on this Mac.
struct MailSearchRequest: Sendable, Equatable {
    var query: String?
    var scope: MailSearchScope = .all
    /// `account/mailbox` index keys. Empty means every indexed mailbox.
    var mailboxKeys: [String] = []
    var since: Date?
    var until: Date?
    var hasAttachments: Bool?
    var isRead: Bool?
    var isFlagged: Bool?
    var bodyComplete: Bool?
    var limit: Int = 20
    var cursor: MailSearchCursor?
    /// False when this SQLite has no FTS5. Header matching still works; body
    /// matching is refused rather than quietly skipped.
    var fullTextAvailable: Bool = true
}

enum MailSearchQueryError: LocalizedError, Equatable {
    case bodySearchUnavailable
    case unusableQuery(String)
    case badCursor(String)

    var errorDescription: String? {
        switch self {
        case .bodySearchUnavailable:
            return
                "BODY_SEARCH_UNAVAILABLE: this SQLite build has no FTS5 module, so message bodies "
                + "are stored but cannot be matched. Search subject and sender instead, or report "
                + "this: every supported macOS ships FTS5."
        case let .unusableQuery(detail):
            return "UNUSABLE_QUERY: \(detail)"
        case let .badCursor(detail):
            return
                "BAD_CURSOR: \(detail) Cursors come from a previous search's next_cursor; they "
                + "cannot be constructed by hand."
        }
    }
}

enum MailSearchQuery {
    /// The columns every hit is built from, in bind order.
    static let selectedColumns = """
        m.stable_id, m.account_id, m.mailbox, m.emlx_id, m.message_id, m.subject, m.sender, \
        m.recipients, m.date_sent, m.is_read, m.is_flagged, m.attachment_count, \
        m.body_complete, m.body_reason, m.is_partial
        """

    static let ordering = "ORDER BY (m.date_sent IS NULL) ASC, m.date_sent DESC, m.stable_id ASC"

    // MARK: - Query text

    /// Splits user text into the words FTS5 will be asked about.
    ///
    /// Double quotes group a phrase. A trailing `*` on an unquoted word is a
    /// prefix match, because that is the one FTS operator worth exposing
    /// without teaching the client FTS5's grammar.
    static func terms(in query: String) -> [(text: String, prefix: Bool)] {
        var result: [(text: String, prefix: Bool)] = []
        var current = ""
        var quoted = false
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty else { return }
            if !quoted, trimmed.hasSuffix("*"), trimmed.count > 1 {
                result.append((String(trimmed.dropLast()), true))
            } else {
                result.append((trimmed, false))
            }
        }
        for character in query {
            if character == "\"" {
                flush()
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    /// An FTS5 MATCH expression, with every term quoted so punctuation in a
    /// user's words cannot be read as FTS syntax.
    static func ftsExpression(query: String, scope: MailSearchScope) -> String? {
        let parsed = terms(in: query)
        guard !parsed.isEmpty else { return nil }
        let joined =
            parsed
            .map { term -> String in
                let escaped = term.text.replacingOccurrences(of: "\"", with: "\"\"")
                return term.prefix ? "\"\(escaped)\"*" : "\"\(escaped)\""
            }
            .joined(separator: " AND ")
        switch scope {
        case .all: return joined
        case .subject: return "{subject} : (\(joined))"
        case .sender: return "{sender} : (\(joined))"
        case .body: return "{body} : (\(joined))"
        }
    }

    // MARK: - Statements

    /// The page query. `limit` is bound one higher than requested so the
    /// executor can tell a full page from a last page without a count.
    static func page(_ request: MailSearchRequest) throws -> MailSearchStatement {
        var bindings: [MailSearchBinding] = []
        let source = from(request)
        var clauses = try predicates(request, bindings: &bindings)
        if let clause = cursorPredicate(request.cursor, bindings: &bindings) {
            clauses.append(clause)
        }
        let body = hasQuery(request) && request.fullTextAvailable ? ", messages_fts.body" : ""
        var sql = "SELECT \(selectedColumns)\(body) FROM \(source)"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " \(ordering) LIMIT ?"
        bindings.append(.int(max(1, request.limit) + 1))
        return MailSearchStatement(sql: sql, bindings: bindings)
    }

    /// Counts messages the date filter alone removed, so a search bounded by
    /// date can say how many undated messages it could not consider rather
    /// than pretending they were not there.
    static func undatedExcluded(_ request: MailSearchRequest) throws -> MailSearchStatement? {
        guard request.since != nil || request.until != nil else { return nil }
        var undated = request
        undated.since = nil
        undated.until = nil
        undated.cursor = nil
        var bindings: [MailSearchBinding] = []
        let source = from(undated)
        var clauses = try predicates(undated, bindings: &bindings)
        clauses.append("m.date_sent IS NULL")
        return MailSearchStatement(
            sql: "SELECT COUNT(*) FROM \(source) WHERE " + clauses.joined(separator: " AND "),
            bindings: bindings
        )
    }

    /// The FROM clause. The full-text table is joined only when there is a
    /// query to match and an FTS5 module to match it with; the MATCH itself
    /// is a WHERE clause, where SQLite's full-text documentation puts it.
    private static func from(_ request: MailSearchRequest) -> String {
        guard hasQuery(request), request.fullTextAvailable else { return "messages m" }
        return "messages m JOIN messages_fts ON messages_fts.stable_id = m.stable_id"
    }

    private static func hasQuery(_ request: MailSearchRequest) -> Bool {
        guard let query = request.query else { return false }
        return !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func predicates(
        _ request: MailSearchRequest,
        bindings: inout [MailSearchBinding]
    ) throws -> [String] {
        var clauses: [String] = []

        if hasQuery(request), request.fullTextAvailable, let query = request.query {
            guard let expression = ftsExpression(query: query, scope: request.scope) else {
                throw MailSearchQueryError.unusableQuery(
                    "the query \"\(query)\" contains no searchable words."
                )
            }
            clauses.append("messages_fts MATCH ?")
            bindings.append(.text(expression))
        }

        // Without FTS5 the query has to fall back to substring matching on
        // the header columns, and asking for bodies is refused outright.
        if hasQuery(request), let query = request.query, !request.fullTextAvailable {
            guard request.scope != .body else { throw MailSearchQueryError.bodySearchUnavailable }
            let parsed = terms(in: query)
            guard !parsed.isEmpty else {
                throw MailSearchQueryError.unusableQuery(
                    "the query \"\(query)\" contains no searchable words."
                )
            }
            for term in parsed {
                let pattern = "%\(escapedForLike(term.text))%"
                switch request.scope {
                case .subject:
                    clauses.append("m.subject LIKE ? ESCAPE '\\'")
                    bindings.append(.text(pattern))
                case .sender:
                    clauses.append("m.sender LIKE ? ESCAPE '\\'")
                    bindings.append(.text(pattern))
                case .all, .body:
                    clauses.append("(m.subject LIKE ? ESCAPE '\\' OR m.sender LIKE ? ESCAPE '\\')")
                    bindings.append(.text(pattern))
                    bindings.append(.text(pattern))
                }
            }
        }

        if !request.mailboxKeys.isEmpty {
            let placeholders = Array(repeating: "?", count: request.mailboxKeys.count)
                .joined(separator: ", ")
            clauses.append("(m.account_id || '/' || m.mailbox) IN (\(placeholders))")
            bindings.append(contentsOf: request.mailboxKeys.map { .text($0) })
        }
        if let since = request.since {
            clauses.append("m.date_sent >= ?")
            bindings.append(.double(since.timeIntervalSince1970))
        }
        if let until = request.until {
            clauses.append("m.date_sent <= ?")
            bindings.append(.double(until.timeIntervalSince1970))
        }
        if let hasAttachments = request.hasAttachments {
            clauses.append(hasAttachments ? "m.attachment_count > 0" : "m.attachment_count = 0")
        }
        if let isRead = request.isRead {
            clauses.append("m.is_read = ?")
            bindings.append(.int(isRead ? 1 : 0))
        }
        if let isFlagged = request.isFlagged {
            clauses.append("m.is_flagged = ?")
            bindings.append(.int(isFlagged ? 1 : 0))
        }
        if let bodyComplete = request.bodyComplete {
            clauses.append("m.body_complete = ?")
            bindings.append(.int(bodyComplete ? 1 : 0))
        }
        return clauses
    }

    /// Rows strictly after the cursor in the page ordering.
    ///
    /// A dated cursor is followed by older dated rows, by rows sharing its
    /// date with a larger stable id, and then by the whole undated tail. A
    /// cursor already in that tail is followed only by undated rows with a
    /// larger stable id.
    static func cursorPredicate(
        _ cursor: MailSearchCursor?,
        bindings: inout [MailSearchBinding]
    ) -> String? {
        guard let cursor else { return nil }
        guard let date = cursor.dateSent else {
            bindings.append(.text(cursor.stableID))
            return "(m.date_sent IS NULL AND m.stable_id > ?)"
        }
        bindings.append(.double(date.timeIntervalSince1970))
        bindings.append(.double(date.timeIntervalSince1970))
        bindings.append(.text(cursor.stableID))
        return
            "(m.date_sent IS NULL OR m.date_sent < ? OR (m.date_sent = ? AND m.stable_id > ?))"
    }

    private static func escapedForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Snippets

    /// A short window of body text around the first matched word, so a hit
    /// can show why it matched. Built here rather than by FTS5's own snippet
    /// function because it has to behave identically on the substring
    /// fallback path, where there is no FTS5 to ask.
    static func snippet(body: String, query: String?, width: Int = 160) -> String? {
        let collapsed =
            body
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: " +",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard let query, !query.isEmpty else { return String(collapsed.prefix(width)) }

        let needles = terms(in: query).map { $0.text.lowercased() }.filter { !$0.isEmpty }
        let lowered = collapsed.lowercased()
        var found: Range<String.Index>?
        for needle in needles {
            if let range = lowered.range(of: needle) {
                found = range
                break
            }
        }
        guard let range = found else { return String(collapsed.prefix(width)) }

        let distance = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
        let start = max(0, distance - width / 3)
        let begin = collapsed.index(collapsed.startIndex, offsetBy: start)
        let text = String(collapsed[begin...].prefix(width))
        let prefix = start > 0 ? "…" : ""
        let suffix = collapsed.distance(from: begin, to: collapsed.endIndex) > width ? "…" : ""
        return prefix + text + suffix
    }
}
