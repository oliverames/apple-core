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
        // immutable=1: Reminders.app writes this store constantly, and taking
        // a lock on it or creating sidecar files would be our bug to explain.
        let uri = "file:\(path)?immutable=1"
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
