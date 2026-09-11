// SPDX-License-Identifier: GPL-3.0-or-later
//
// Read-only access to the Reminders CoreData store for what EventKit omits.
//
// EventKit models lists, reminders, priority, recurrence and alarms, and none
// of sections, subtasks, tags or attachments. Those live only in the iCloud
// Reminders CoreData store, which is why `remctl` reads that store directly
// and writes back through EventKit.
//
// This follows the same shape and the same caution: the store is Apple's
// private schema and moves between releases, so every query checks the tables
// and columns it needs and reports a reason rather than throwing the surface
// down. Nothing here writes; writes stay on EventKit, where they are
// supported.
//
// Scope note: only sections are implemented. Subtasks and tags have the
// columns (`ZREMCDREMINDER.ZPARENTREMINDER`, `ZREMCDHASHTAGLABEL`) but no rows
// on the machine this was written against, and a reader verified against zero
// rows is a reader whose empty result is indistinguishable from a correct one.

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ReminderSection: Sendable, Equatable {
    public let name: String
    public let listName: String?
    public let identifier: String?
}

public enum RemindersStoreError: LocalizedError {
    case storeNotFound
    case cannotOpen(String)
    case schemaMissing(String)

    public var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return
                "The Reminders database could not be found. Sections are unavailable, but the other "
                + "Reminders tools still work."
        case let .cannotOpen(detail):
            return "The Reminders database could not be read: \(detail)"
        case let .schemaMissing(what):
            return
                "This version of macOS stores Reminders differently than expected (\(what) is missing), "
                + "so sections are unavailable."
        }
    }
}

public struct RemindersStoreReader {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The Reminders store lives in a group container and is split across
    /// several `Data-*.sqlite` files. The largest is the real one; the others
    /// are small per-account stores.
    public static func locateStore(fileManager: FileManager = .default) -> String? {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        else {
            return nil
        }
        let stores = entries.filter {
            $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite"
        }
        let largest = stores.max { left, right in
            let leftSize = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rightSize = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return leftSize < rightSize
        }
        return largest?.path
    }

    private func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        // A normal read-only connection sees committed rows in the live WAL.
        // `immutable=1` read only the last checkpointed main database.
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let handle
        else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw RemindersStoreError.cannotOpen(detail)
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

    /// CoreData stores these as raw 16-byte UUIDs rather than strings.
    static func uuidString(fromBlob bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        return uuid.uuidString
    }

    /// Sections across every list, or just one list when named.
    public func sections(listName: String?) throws -> [ReminderSection] {
        let handle = try open()
        defer { sqlite3_close(handle) }

        guard tableExists("ZREMCDBASESECTION", in: handle) else {
            throw RemindersStoreError.schemaMissing("the sections table")
        }
        let hasLists = tableExists("ZREMCDBASELIST", in: handle)
        if listName != nil, !hasLists {
            // Dropping the filter here returned every section on the machine
            // dressed up as one list's sections; the sections-table twin
            // above throws, and this case deserves the same honesty.
            throw RemindersStoreError.schemaMissing("the lists table")
        }

        var sql = """
            SELECT s.ZDISPLAYNAME, \(hasLists ? "l.ZNAME" : "NULL"), s.ZIDENTIFIER
            FROM ZREMCDBASESECTION s
            """
        if hasLists { sql += "\nLEFT JOIN ZREMCDBASELIST l ON l.Z_PK = s.ZLIST" }
        sql += "\nWHERE s.ZDISPLAYNAME IS NOT NULL AND COALESCE(s.ZMARKEDFORDELETION, 0) = 0"
        if listName != nil, hasLists { sql += "\nAND l.ZNAME = ?" }
        sql += "\nORDER BY \(hasLists ? "l.ZNAME, " : "")s.ZDISPLAYNAME"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RemindersStoreError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        if let listName, hasLists {
            sqlite3_bind_text(statement, 1, listName, -1, sqliteTransient)
        }

        var results: [ReminderSection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 0) else { continue }
            let list = sqlite3_column_text(statement, 1).map { String(cString: $0) }

            var identifier: String?
            if let blob = sqlite3_column_blob(statement, 2) {
                let count = Int(sqlite3_column_bytes(statement, 2))
                let bytes = [UInt8](UnsafeRawBufferPointer(start: blob, count: count))
                identifier = Self.uuidString(fromBlob: bytes)
            }

            results.append(
                ReminderSection(
                    name: String(cString: nameC),
                    listName: list,
                    identifier: identifier
                )
            )
        }
        return results
    }
}

// MARK: - Tool logic that needs no store
//
// Everything below decides behaviour the Reminders tools need before they
// touch EventKit: which list a name refers to, which alarms an edit may
// replace, what a page of results contains. It is deliberately EventKit-free
// and lives in Shared/ so it is exercised against plain values rather than the
// live Reminders database. It shares this file rather than getting one of its
// own because Shared/ is an explicit file list in the Xcode project, not a
// synchronized group: a new file here would join neither target.

/// A reminder list flattened to the fields that targeting decisions need.
public struct ReminderListCandidate: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let sourceIdentifier: String
    public let sourceTitle: String
    public let isEditable: Bool
    public let isSubscribed: Bool

    public init(
        identifier: String,
        title: String,
        sourceIdentifier: String,
        sourceTitle: String,
        isEditable: Bool = true,
        isSubscribed: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.isEditable = isEditable
        self.isSubscribed = isSubscribed
    }

    /// How a list is named back to a caller that has to choose between several.
    public var disambiguation: String {
        "\"\(title)\" in \(sourceTitle) (identifier \(identifier))"
    }
}

public enum ReminderListError: LocalizedError, Equatable {
    case noTarget
    case unknownIdentifier(String)
    case unknownName(name: String, source: String?)
    case ambiguousName(name: String, candidates: [String])
    case readOnly(String)
    case duplicateName(name: String, source: String)
    case notEmpty(name: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .noTarget:
            return "Name the list to act on, by identifier or by name."
        case let .unknownIdentifier(identifier):
            return "No reminder list has the identifier \(identifier)."
        case let .unknownName(name, source):
            if let source {
                return "No reminder list named \"\(name)\" exists in \(source)."
            }
            return "No reminder list named \"\(name)\" exists."
        case let .ambiguousName(name, candidates):
            return
                "\"\(name)\" names \(candidates.count) reminder lists: \(candidates.joined(separator: "; ")). "
                + "Pass the identifier, or the account, to say which one."
        case let .readOnly(name):
            return "Reminder list \"\(name)\" is read-only and cannot be modified."
        case let .duplicateName(name, source):
            return "\(source) already has a reminder list named \"\(name)\"."
        case let .notEmpty(name, count):
            return
                "Reminder list \"\(name)\" still holds \(count) reminder\(count == 1 ? "" : "s"), and deleting "
                + "the list deletes them with it. Move or delete them first, or pass "
                + "delete_reminders: true to confirm losing them."
        }
    }
}

public enum ReminderListTarget {
    /// Exact identifier first, then name. A name matching lists in more than
    /// one account is an error rather than a guess: picking one silently would
    /// file a reminder into, or delete, the wrong account's list.
    public static func resolve(
        identifier: String?,
        name: String?,
        source: String?,
        in lists: [ReminderListCandidate]
    ) throws -> ReminderListCandidate {
        if let identifier, !identifier.isEmpty {
            guard let match = lists.first(where: { $0.identifier == identifier }) else {
                throw ReminderListError.unknownIdentifier(identifier)
            }
            return match
        }
        guard let name, !name.isEmpty else {
            throw ReminderListError.noTarget
        }

        var matches = lists.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        if let source, !source.isEmpty {
            matches = matches.filter {
                $0.sourceIdentifier == source
                    || $0.sourceTitle.caseInsensitiveCompare(source) == .orderedSame
            }
        }
        switch matches.count {
        case 0:
            throw ReminderListError.unknownName(name: name, source: source)
        case 1:
            return matches[0]
        default:
            throw ReminderListError.ambiguousName(
                name: name,
                candidates: matches.map(\.disambiguation)
            )
        }
    }

    public static func requireWritable(_ list: ReminderListCandidate) throws {
        guard list.isEditable, !list.isSubscribed else {
            throw ReminderListError.readOnly(list.title)
        }
    }

    /// Two lists with the same name in one account are indistinguishable to
    /// every later name lookup, so creation and rename refuse to make a pair.
    public static func requireNameIsFree(
        _ name: String,
        inSource sourceIdentifier: String,
        sourceTitle: String,
        among lists: [ReminderListCandidate],
        ignoring ignoredIdentifier: String? = nil
    ) throws {
        let clash = lists.contains {
            $0.sourceIdentifier == sourceIdentifier
                && $0.title.caseInsensitiveCompare(name) == .orderedSame
                && $0.identifier != ignoredIdentifier
        }
        if clash {
            throw ReminderListError.duplicateName(name: name, source: sourceTitle)
        }
    }

    /// EventKit deletes a list's reminders along with the list. That is not
    /// recoverable, so a nonempty list needs the caller to say so out loud.
    public static func checkDeletable(
        _ list: ReminderListCandidate,
        reminderCount: Int,
        deletesContainedReminders: Bool
    ) throws {
        try requireWritable(list)
        guard reminderCount == 0 || deletesContainedReminders else {
            throw ReminderListError.notEmpty(name: list.title, count: reminderCount)
        }
    }
}

/// An account a list can be created in.
public struct ReminderSourceCandidate: Sendable, Equatable {
    public let identifier: String
    public let title: String

    public init(identifier: String, title: String) {
        self.identifier = identifier
        self.title = title
    }

    public var disambiguation: String { "\"\(title)\" (identifier \(identifier))" }
}

public enum ReminderSourceError: LocalizedError, Equatable {
    case unknown(requested: String, available: [String])
    case ambiguous(requested: String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case let .unknown(requested, available):
            return
                "No Reminders account matches \"\(requested)\". Available accounts: "
                + "\(available.joined(separator: ", "))."
        case let .ambiguous(requested, candidates):
            return
                "\"\(requested)\" names \(candidates.count) Reminders accounts: "
                + "\(candidates.joined(separator: "; ")). Pass the identifier instead."
        }
    }
}

public enum ReminderSourceTarget {
    public static func resolve(
        _ requested: String,
        in sources: [ReminderSourceCandidate]
    ) throws -> ReminderSourceCandidate {
        if let byIdentifier = sources.first(where: { $0.identifier == requested }) {
            return byIdentifier
        }
        let byTitle = sources.filter {
            $0.title.caseInsensitiveCompare(requested) == .orderedSame
        }
        switch byTitle.count {
        case 0:
            throw ReminderSourceError.unknown(
                requested: requested,
                available: sources.map(\.title)
            )
        case 1:
            return byTitle[0]
        default:
            throw ReminderSourceError.ambiguous(
                requested: requested,
                candidates: byTitle.map(\.disambiguation)
            )
        }
    }
}

/// Alarms come in kinds EventKit stores in one flat array. Editing one kind
/// has to leave the others alone.
public enum ReminderAlarmClass: Sendable, Equatable, CaseIterable {
    case absolute
    case relative
    case location
}

public enum ReminderAlarms {
    /// Replaces only the alarms of one class. Anything the classifier does not
    /// recognise is preserved too: an unknown alarm is still the user's.
    public static func replacing<Alarm>(
        _ replaced: ReminderAlarmClass,
        in existing: [Alarm],
        with replacements: [Alarm],
        classify: (Alarm) -> ReminderAlarmClass?
    ) -> [Alarm] {
        existing.filter { classify($0) != replaced } + replacements
    }
}

public enum ReminderProximity: String, Sendable, CaseIterable {
    case arriving
    case leaving
}

public struct ReminderLocationAlarm: Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let proximity: ReminderProximity

    /// Out-of-range coordinates produce an alarm that never fires, which looks
    /// to the user like a reminder that silently failed. Reject them instead.
    public static func validated(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        proximity: String
    ) throws -> ReminderLocationAlarm {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReminderLocationError.missingName }
        guard latitude.isFinite, (-90.0 ... 90.0).contains(latitude) else {
            throw ReminderLocationError.invalidLatitude(latitude)
        }
        guard longitude.isFinite, (-180.0 ... 180.0).contains(longitude) else {
            throw ReminderLocationError.invalidLongitude(longitude)
        }
        guard radiusMeters.isFinite, radiusMeters > 0 else {
            throw ReminderLocationError.invalidRadius(radiusMeters)
        }
        guard let proximity = ReminderProximity(rawValue: proximity.lowercased()) else {
            throw ReminderLocationError.unknownProximity(proximity)
        }
        return ReminderLocationAlarm(
            name: trimmed,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            proximity: proximity
        )
    }
}

public enum ReminderLocationError: LocalizedError, Equatable {
    case missingName
    case invalidLatitude(Double)
    case invalidLongitude(Double)
    case invalidRadius(Double)
    case unknownProximity(String)

    public var errorDescription: String? {
        switch self {
        case .missingName:
            return "A location alarm needs a place name."
        case let .invalidLatitude(value):
            return "Latitude \(value) is outside -90 to 90."
        case let .invalidLongitude(value):
            return "Longitude \(value) is outside -180 to 180."
        case let .invalidRadius(value):
            return "A location alarm radius must be a positive number of meters, not \(value)."
        case let .unknownProximity(value):
            return
                "Unknown proximity \"\(value)\". Use "
                + "\(ReminderProximity.allCases.map(\.rawValue).joined(separator: " or "))."
        }
    }
}

public enum ReminderURLError: LocalizedError, Equatable {
    case malformed(String)
    case notAbsolute(String)
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(raw):
            return "\"\(raw)\" is not a URL Reminders can store."
        case let .notAbsolute(raw):
            return "\"\(raw)\" has no scheme. Reminder URLs must be absolute, such as https://example.com."
        case let .unsupportedScheme(scheme):
            return "Apple Core will not store \(scheme): URLs on a reminder."
        }
    }
}

public enum ReminderURLField {
    /// Schemes that carry code or inline payloads rather than a destination.
    /// A reminder's URL is something the user will tap.
    private static let refusedSchemes: Set<String> = ["javascript", "data", "vbscript"]

    /// Returns nil for an empty string, which clears the field. The native URL
    /// field is the only place a URL is written: mirroring it into a managed
    /// notes line, the way remindctl does, would rewrite the user's own notes.
    public static func parse(_ raw: String) throws -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else {
            throw ReminderURLError.malformed(raw)
        }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw ReminderURLError.notAbsolute(raw)
        }
        guard !refusedSchemes.contains(scheme) else {
            throw ReminderURLError.unsupportedScheme(scheme)
        }
        // "https://" parses but names nothing to open.
        guard url.host?.isEmpty == false || !url.path.isEmpty else {
            throw ReminderURLError.malformed(raw)
        }
        return url
    }
}

public enum ReminderSearchScope: String, Sendable, CaseIterable {
    case title
    case notes
    case url
    case all
}

public struct ReminderSearchFields: Sendable, Equatable {
    public let title: String?
    public let notes: String?
    public let url: String?

    public init(title: String?, notes: String? = nil, url: String? = nil) {
        self.title = title
        self.notes = notes
        self.url = url
    }
}

public enum ReminderTextSearch {
    public static func matches(
        _ query: String,
        in fields: ReminderSearchFields,
        scope: ReminderSearchScope
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }

        var haystacks: [String?] = []
        switch scope {
        case .title: haystacks = [fields.title]
        case .notes: haystacks = [fields.notes]
        case .url: haystacks = [fields.url]
        case .all: haystacks = [fields.title, fields.notes, fields.url]
        }
        return haystacks.contains {
            $0?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}

/// Apple's priority numbers are a 1-9 scale with named bands, not four values.
public enum ReminderPriorityBucket: String, Sendable, CaseIterable {
    case none
    case high
    case medium
    case low

    public static func bucket(forRawValue raw: Int) -> ReminderPriorityBucket {
        switch raw {
        case 1 ... 4: return .high
        case 5: return .medium
        case 6 ... 9: return .low
        default: return .none
        }
    }
}

public enum ReminderCompletionRange {
    /// With no bounds every reminder qualifies. With bounds, one that was
    /// never completed does not: an absent date is not inside a range.
    public static func matches(completionDate: Date?, start: Date?, end: Date?) -> Bool {
        guard start != nil || end != nil else { return true }
        guard let completionDate else { return false }
        if let start, completionDate < start { return false }
        if let end, completionDate > end { return false }
        return true
    }
}

/// The fields a page is ordered by. Due date alone is not a total order, and a
/// partial order gives different pages different contents between calls.
public struct ReminderOrderingKey: Sendable, Equatable {
    public let dueDate: Date?
    public let title: String
    public let identifier: String

    public init(dueDate: Date?, title: String, identifier: String) {
        self.dueDate = dueDate
        self.title = title
        self.identifier = identifier
    }
}

public struct ReminderPage<Item> {
    public let items: [Item]
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let hasMore: Bool
    public let nextOffset: Int?
}

public enum ReminderPagination {
    public static let defaultLimit = 50
    public static let maximumLimit = 500

    public static func clampedLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultLimit, 1), maximumLimit)
    }

    public static func clampedOffset(_ requested: Int?) -> Int {
        max(requested ?? 0, 0)
    }

    /// Dated reminders first in date order, then undated ones, with title and
    /// identifier breaking every remaining tie so page 2 resumes where page 1
    /// stopped rather than overlapping it.
    public static func stableSorted<Item>(
        _ items: [Item],
        key: (Item) -> ReminderOrderingKey
    ) -> [Item] {
        items.sorted { left, right in
            let a = key(left)
            let b = key(right)
            switch (a.dueDate, b.dueDate) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                break
            }
            let titles = a.title.caseInsensitiveCompare(b.title)
            if titles != .orderedSame { return titles == .orderedAscending }
            if a.title != b.title { return a.title < b.title }
            return a.identifier < b.identifier
        }
    }

    public static func page<Item>(
        _ ordered: [Item],
        offset: Int,
        limit: Int
    ) -> ReminderPage<Item> {
        let total = ordered.count
        guard offset < total else {
            return ReminderPage(
                items: [],
                offset: offset,
                limit: limit,
                total: total,
                hasMore: false,
                nextOffset: nil
            )
        }
        // Saturating rather than wrapping: a caller may pass Int.max.
        let end = offset > total - limit ? total : offset + limit
        let items = Array(ordered[offset ..< end])
        return ReminderPage(
            items: items,
            offset: offset,
            limit: limit,
            total: total,
            hasMore: end < total,
            nextOffset: end < total ? end : nil
        )
    }
}
