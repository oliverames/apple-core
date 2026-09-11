// SPDX-License-Identifier: GPL-3.0-or-later
//
// Read-only inspection of Mail's smart mailboxes.
//
// Mail's scripting dictionary has no smart mailbox in it at all: `sdef
// /System/Applications/Mail.app` contains `rule` and `rule condition` classes
// but no smart-mailbox class, element or property (checked September 11,
// 2026, macOS 27). The only place a smart mailbox exists outside Mail's own
// UI is `MailData/SyncedSmartMailboxes.plist`, which is a private file with
// no published schema.
//
// So this reader is deliberately schema-agnostic. It does not assert Apple's
// key names. It walks whatever property list is there, recognizes keys by
// meaning when it can, and reports every key it could not place in
// `unmappedKeys` instead of dropping it. A file whose shape it cannot follow
// at all comes back as `unrecognized` with the top-level keys listed, which is
// a usable bug report, rather than as an empty list, which would read as "you
// have no smart mailboxes".
//
// Shape confirmed against a real file on 2026-09-11 (Home Server, macOS 26.6.2),
// reading key names and value types only. The root is an array of mailbox
// dictionaries carrying MailboxName, MailboxID, MailboxType, MailboxCriteria,
// MailboxAllCriteriaMustBeSatisfied, MailboxChildren and
// IMAPMailboxAttributes. Three of those map here; the rest are reported as
// unmapped rather than dropped, which is the intended contract and not a
// failure to parse.
//
// Nothing here writes. Writing a smart mailbox means writing a private plist
// behind a running app's back, and that needs account-specific fixtures and a
// verified schema first.

import Foundation

/// One condition inside a smart mailbox, as far as it could be read.
struct MailSmartMailboxCondition: Codable, Sendable, Equatable {
    /// What the condition looks at, when a key could be recognized as that.
    let field: String?
    /// How it compares, when a key could be recognized as that.
    let comparison: String?
    /// What it compares against, when a key could be recognized as that.
    let value: String?
    /// Keys present in the file that this reader did not place.
    let unmappedKeys: [String]
}

struct MailSmartMailbox: Codable, Sendable, Equatable {
    let name: String?
    /// True when every condition must match, false when any may, nil when the
    /// file did not say in a way this reader recognized.
    let allConditionsMustMatch: Bool?
    let conditions: [MailSmartMailboxCondition]
    let unmappedKeys: [String]
}

struct MailSmartMailboxListing: Codable, Sendable, Equatable {
    /// `available`, `not_found`, `unreadable` or `unrecognized`.
    let state: String
    let path: String
    let detail: String
    let mailboxes: [MailSmartMailbox]
    /// The shape actually found at the top of the file, so an unrecognized
    /// file can be diagnosed without anyone having to send the file itself.
    let topLevelKeys: [String]
}

enum MailSmartMailboxes {
    /// Cap on one listing. A pathological file cannot turn into an unbounded
    /// response.
    static let maximumMailboxes = 200

    static let fileName = "SyncedSmartMailboxes.plist"

    /// Where the file lives, given Mail's store. Nil when the store itself is
    /// not readable.
    static func path(in store: MailLocalStore = .default) -> String? {
        guard let version = store.versionDirectory else { return nil }
        return
            version
            .appendingPathComponent("MailData", isDirectory: true)
            .appendingPathComponent(fileName)
            .path
    }

    static func list(store: MailLocalStore = .default) -> MailSmartMailboxListing {
        let access = store.access
        guard access.isAvailable, let path = path(in: store) else {
            return MailSmartMailboxListing(
                state: access.isAvailable ? "not_found" : "unreadable",
                path: path(in: store) ?? store.root.path,
                detail: access.explanation,
                mailboxes: [],
                topLevelKeys: []
            )
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return MailSmartMailboxListing(
                state: "not_found",
                path: path,
                detail:
                    "NOT_FOUND: \(path) does not exist. Mail writes this file when the first "
                    + "smart mailbox is created, so this most likely means there are none.",
                mailboxes: [],
                topLevelKeys: []
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return MailSmartMailboxListing(
                state: "unreadable",
                path: path,
                detail:
                    "UNREADABLE: \(path) could not be read: \(error.localizedDescription). "
                    + ServicePermissionRequirement.fullDiskAccess.grantInstruction,
                mailboxes: [],
                topLevelKeys: []
            )
        }
        return parse(data, path: path)
    }

    /// The whole parse, separated from the file system so it can be tested
    /// against fixtures rather than against somebody's real mail.
    static func parse(_ data: Data, path: String) -> MailSmartMailboxListing {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            return MailSmartMailboxListing(
                state: "unreadable",
                path: path,
                detail: "UNREADABLE: \(path) is not a readable property list: \(error.localizedDescription)",
                mailboxes: [],
                topLevelKeys: []
            )
        }

        let topLevelKeys = (object as? [String: Any]).map { $0.keys.sorted() } ?? []
        guard let entries = mailboxEntries(in: object) else {
            return MailSmartMailboxListing(
                state: "unrecognized",
                path: path,
                detail:
                    "UNRECOGNIZED: \(path) was read, but this build does not recognize its "
                    + "layout, so no smart mailbox is reported rather than an empty list being "
                    + "passed off as none. This file is private to Mail and has no published "
                    + "schema. Top-level keys: "
                    + (topLevelKeys.isEmpty ? "(none)" : topLevelKeys.joined(separator: ", ")),
                mailboxes: [],
                topLevelKeys: topLevelKeys
            )
        }

        let mailboxes = entries.prefix(maximumMailboxes).map(mailbox(from:))
        let capped = entries.count > maximumMailboxes
        return MailSmartMailboxListing(
            state: "available",
            path: path,
            detail: capped
                ? "Read \(maximumMailboxes) of \(entries.count) smart mailbox(es); the rest were "
                    + "not returned. Field names come from a private file, so a field reported as "
                    + "unmapped is a gap in this reader, not a fault in Mail."
                : "Read \(entries.count) smart mailbox(es). Field names come from a private file, "
                    + "so a field reported as unmapped is a gap in this reader, not a fault in "
                    + "Mail.",
            mailboxes: mailboxes,
            topLevelKeys: topLevelKeys
        )
    }

    // MARK: - Shape discovery

    /// The array of smart-mailbox dictionaries, wherever it is.
    ///
    /// Either the root is that array, or it is a dictionary holding it under
    /// some key. The key is chosen by name when one looks like it names
    /// mailboxes, and otherwise by being the only array of dictionaries
    /// present, so a renamed key does not break the reader but an ambiguous
    /// file is refused rather than guessed at.
    private static func mailboxEntries(in object: Any) -> [[String: Any]]? {
        if let array = object as? [Any] {
            let dictionaries = array.compactMap { $0 as? [String: Any] }
            return dictionaries.isEmpty && !array.isEmpty ? nil : dictionaries
        }
        guard let root = object as? [String: Any] else { return nil }
        let candidates = root.filter { _, value in
            guard let array = value as? [Any] else { return false }
            return array.allSatisfy { $0 is [String: Any] }
        }
        guard !candidates.isEmpty else { return nil }
        let named = candidates.first { key, _ in key.lowercased().contains("mailbox") }
        if let named { return (named.value as? [Any])?.compactMap { $0 as? [String: Any] } }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return (only.value as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    private static func mailbox(from entry: [String: Any]) -> MailSmartMailbox {
        var unmapped: [String] = []
        var name: String?
        var all: Bool?
        var conditions: [MailSmartMailboxCondition] = []

        for key in entry.keys.sorted() {
            let value = entry[key]
            let lowered = key.lowercased()
            if name == nil, isNameKey(lowered), let text = value as? String {
                name = text
                continue
            }
            if all == nil, isAllKey(lowered), let flag = value as? Bool {
                all = flag
                continue
            }
            if conditions.isEmpty, isConditionsKey(lowered),
                let array = value as? [Any]
            {
                let dictionaries = array.compactMap { $0 as? [String: Any] }
                if !dictionaries.isEmpty {
                    conditions = dictionaries.map(condition(from:))
                    continue
                }
            }
            unmapped.append(key)
        }

        return MailSmartMailbox(
            name: name,
            allConditionsMustMatch: all,
            conditions: conditions,
            unmappedKeys: unmapped
        )
    }

    private static func condition(from entry: [String: Any]) -> MailSmartMailboxCondition {
        var unmapped: [String] = []
        var field: String?
        var comparison: String?
        var value: String?

        for key in entry.keys.sorted() {
            let lowered = key.lowercased()
            let text = describe(entry[key])
            if field == nil, isFieldKey(lowered), let text {
                field = text
                continue
            }
            if comparison == nil, isComparisonKey(lowered), let text {
                comparison = text
                continue
            }
            if value == nil, isValueKey(lowered), let text {
                value = text
                continue
            }
            unmapped.append(key)
        }
        return MailSmartMailboxCondition(
            field: field,
            comparison: comparison,
            value: value,
            unmappedKeys: unmapped
        )
    }

    /// A scalar rendered as text, or nil for anything with structure. A nested
    /// value is left unmapped rather than flattened into a misleading string.
    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        default: return nil
        }
    }

    private static func isNameKey(_ key: String) -> Bool {
        key == "name" || key == "displayname" || key == "title" || key.hasSuffix("name")
    }

    private static func isAllKey(_ key: String) -> Bool {
        key.contains("all") && (key.contains("match") || key.contains("criteri") || key.contains("condition"))
    }

    private static func isConditionsKey(_ key: String) -> Bool {
        key.contains("criteri") || key.contains("condition") || key.contains("rule")
    }

    private static func isFieldKey(_ key: String) -> Bool {
        key.contains("header") || key.contains("field") || key.contains("type")
    }

    private static func isComparisonKey(_ key: String) -> Bool {
        key.contains("qualifier") || key.contains("comparison") || key.contains("operator")
    }

    private static func isValueKey(_ key: String) -> Bool {
        key.contains("expression") || key.contains("value") || key.contains("text")
    }
}
