// SPDX-License-Identifier: GPL-3.0-or-later
//
// Read-only NoteStore.sqlite reads for what Notes' scripting dictionary does
// not expose.
//
// BUILD_PLAN §3.5 originally ruled this out, and its reasoning still stands on
// its own terms: the schema is undocumented, Apple can change it at any
// release, and encrypted notes stay unreadable without the user's password.
// What changed is not the risk but how it is carried. MessagesDatabaseReader
// established the shape — open read-only, check that each table and column is
// really there, and answer "unavailable, because X" instead of throwing the
// surface down — and that shape makes a schema change degrade a few tools
// rather than break the service. See BUILD_PLAN §3.5 for the reversal.
//
// Three of the four callers here are ordinary SELECTs. The fourth, checklist
// state, has to decompress a gzip blob and walk Apple's undocumented protobuf,
// and it is the one most likely to be the first casualty of a macOS update.
// It is written to fail soft for exactly that reason.
//
// The app is not sandboxed, so nothing here needs an entitlement. It needs the
// user to grant Full Disk Access in System Settings, and it reports plainly
// when they have not.

import Compression
import Foundation
import SQLite3

struct NoteChecklistItem: Sendable, Codable {
    let text: String
    let isDone: Bool
}

struct NoteStoreMetadata: Sendable, Codable {
    let noteId: String
    let identifier: String?
    let title: String?
    let snippet: String?
    let isPinned: Bool
    let isTrashed: Bool
    let isPasswordProtected: Bool
    let passwordHint: String?
}

struct NoteStoreSyncStatus: Sendable, Codable {
    let pendingDownload: Int
    let withoutServerRecord: Int
    let note: String
}

enum NotesDatabaseReaderError: LocalizedError, Equatable {
    case unavailable(String)
    case foreignStore(expected: String, found: String)
    case malformedId(String)
    case notFound(String)
    case schemaMissing(String)
    case bodyUnreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(detail):
            return
                "NO_DATABASE_ACCESS: the Notes database could not be read (\(detail)). Grant "
                + "Apple Core Full Disk Access in System Settings > Privacy & Security, then "
                + "quit and reopen it. Every other Notes tool works without this."
        case let .foreignStore(expected, found):
            return
                "FOREIGN_ID: that note id was minted on a different Mac (store \(found), this "
                + "one is \(expected)). Notes' CoreData keys are per-device, so reading it here "
                + "would silently return a different note. Look the note up on this Mac first."
        case let .malformedId(id):
            return "MALFORMED_ID: \"\(id)\" is not a Notes CoreData id."
        case let .notFound(id):
            return "NOT_FOUND: the Notes database has no note for id \(id)."
        case let .schemaMissing(what):
            return
                "SCHEMA_CHANGED: this version of macOS stores Notes differently than expected "
                + "(\(what) is missing), so that information is unavailable."
        case let .bodyUnreadable(why):
            return "BODY_UNREADABLE: the note's stored body could not be decoded (\(why))."
        }
    }
}

/// Opens NoteStore.sqlite read-only for the fields AppleScript cannot reach.
struct NotesDatabaseReader {
    let path: String

    static var defaultPath: String {
        NSHomeDirectory()
            + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    init(path: String = NotesDatabaseReader.defaultPath) {
        self.path = path
    }

    /// Cheap probe for the doctor: can the database be opened and its identity
    /// read. False almost always means Full Disk Access has not been granted.
    var isAvailable: Bool {
        (try? storeUUID()) != nil
    }

    // MARK: - Identity

    /// This store's UUID, which is the middle component of every CoreData id
    /// minted on this Mac.
    func storeUUID() throws -> String {
        let handle = try open()
        defer { sqlite3_close(handle) }
        guard tableExists("Z_METADATA", in: handle) else {
            throw NotesDatabaseReaderError.schemaMissing("the Z_METADATA table")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT Z_UUID FROM Z_METADATA LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let uuid = Self.text(statement, 0)
        else {
            throw NotesDatabaseReaderError.schemaMissing("Z_METADATA.Z_UUID")
        }
        return uuid
    }

    /// Splits `x-coredata://<STORE-UUID>/ICNote/p<PK>` into its parts.
    ///
    /// The store UUID matters. CoreData primary keys are assigned per device,
    /// so the same iCloud note is a different `Z_PK` on every Mac. An id from
    /// another machine would resolve here to a real but unrelated note, which
    /// is worse than an error, so callers must check it.
    static func components(ofNoteId id: String) throws -> (store: String, primaryKey: Int64) {
        guard let url = URL(string: id), url.scheme == "x-coredata",
            let store = url.host
        else {
            throw NotesDatabaseReaderError.malformedId(id)
        }
        let last = url.lastPathComponent
        guard last.hasPrefix("p"), let primaryKey = Int64(last.dropFirst()) else {
            throw NotesDatabaseReaderError.malformedId(id)
        }
        return (store, primaryKey)
    }

    /// Resolves a CoreData id to a primary key for this store, refusing ids
    /// minted elsewhere.
    private func primaryKey(for noteId: String) throws -> Int64 {
        let parsed = try Self.components(ofNoteId: noteId)
        let local = try storeUUID()
        guard parsed.store.caseInsensitiveCompare(local) == .orderedSame else {
            throw NotesDatabaseReaderError.foreignStore(expected: local, found: parsed.store)
        }
        return parsed.primaryKey
    }

    // MARK: - Reads

    /// The stable UUID behind `notes://showNote?identifier=`.
    func identifier(forNoteId noteId: String) throws -> String {
        let primaryKey = try primaryKey(for: noteId)
        let handle = try open()
        defer { sqlite3_close(handle) }
        try requireNoteTable(handle)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NotesDatabaseReaderError.schemaMissing("ZICCLOUDSYNCINGOBJECT.ZIDENTIFIER")
        }
        sqlite3_bind_int64(statement, 1, primaryKey)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NotesDatabaseReaderError.notFound(noteId)
        }
        guard let identifier = Self.text(statement, 0) else {
            throw NotesDatabaseReaderError.notFound(noteId)
        }
        return identifier
    }

    func metadata(forNoteId noteId: String) throws -> NoteStoreMetadata {
        let primaryKey = try primaryKey(for: noteId)
        let handle = try open()
        defer { sqlite3_close(handle) }
        try requireNoteTable(handle)

        // Column set varies by macOS release, so ask for what is present and
        // report the rest as absent rather than failing the whole read.
        let optional = [
            "ZSNIPPET", "ZPASSWORDHINT", "ZISPASSWORDPROTECTED", "ZISPINNED",
            "ZMARKEDFORDELETION", "ZTITLE1", "ZIDENTIFIER",
        ]
        let present = optional.filter { columnExists($0, on: "ZICCLOUDSYNCINGOBJECT", in: handle) }
        guard !present.isEmpty else {
            throw NotesDatabaseReaderError.schemaMissing("every expected note column")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql =
            "SELECT \(present.joined(separator: ", ")) FROM ZICCLOUDSYNCINGOBJECT "
            + "WHERE Z_PK = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NotesDatabaseReaderError.schemaMissing("the note columns")
        }
        sqlite3_bind_int64(statement, 1, primaryKey)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NotesDatabaseReaderError.notFound(noteId)
        }

        var strings: [String: String] = [:]
        var flags: [String: Bool] = [:]
        for (offset, column) in present.enumerated() {
            let index = Int32(offset)
            switch column {
            case "ZISPASSWORDPROTECTED", "ZISPINNED", "ZMARKEDFORDELETION":
                flags[column] = sqlite3_column_int64(statement, index) != 0
            default:
                if let value = Self.text(statement, index) { strings[column] = value }
            }
        }

        return NoteStoreMetadata(
            noteId: noteId,
            identifier: strings["ZIDENTIFIER"],
            title: strings["ZTITLE1"],
            snippet: strings["ZSNIPPET"],
            isPinned: flags["ZISPINNED"] ?? false,
            isTrashed: flags["ZMARKEDFORDELETION"] ?? false,
            isPasswordProtected: flags["ZISPASSWORDPROTECTED"] ?? false,
            passwordHint: strings["ZPASSWORDHINT"]
        )
    }

    /// Checklist items with their done state, which `body of note` strips.
    ///
    /// This is the fragile one: the body is a gzip blob wrapping Apple's own
    /// protobuf, and both the compression and the field numbering are
    /// undocumented. Every failure here is reported as such rather than being
    /// passed off as "this note has no checklist", because those two answers
    /// mean very different things to a caller.
    func checklistItems(forNoteId noteId: String) throws -> [NoteChecklistItem] {
        let primaryKey = try primaryKey(for: noteId)
        let handle = try open()
        defer { sqlite3_close(handle) }
        guard tableExists("ZICNOTEDATA", in: handle) else {
            throw NotesDatabaseReaderError.schemaMissing("the ZICNOTEDATA table")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NotesDatabaseReaderError.schemaMissing("ZICNOTEDATA.ZDATA")
        }
        sqlite3_bind_int64(statement, 1, primaryKey)
        guard sqlite3_step(statement) == SQLITE_ROW,
            let blob = sqlite3_column_blob(statement, 0)
        else {
            throw NotesDatabaseReaderError.notFound(noteId)
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0 else { return [] }
        let compressed = Data(bytes: blob, count: length)

        guard let expanded = Self.gunzip(compressed) else {
            throw NotesDatabaseReaderError.bodyUnreadable("it is not readable gzip data")
        }
        return Self.checklistItems(inNoteProtobuf: expanded)
    }

    /// Sync signals, reported as counts rather than a verdict.
    ///
    /// These columns are heuristics over an undocumented schema, so the shape
    /// of the answer says what was counted instead of claiming to know whether
    /// the account is "in sync".
    func syncStatus() throws -> NoteStoreSyncStatus {
        let handle = try open()
        defer { sqlite3_close(handle) }
        try requireNoteTable(handle)

        func count(where clause: String, requiring column: String) -> Int {
            guard columnExists(column, on: "ZICCLOUDSYNCINGOBJECT", in: handle) else { return -1 }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE \(clause)"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW
            else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        let pendingDownload = count(
            where: "ZNEEDSTOBEFETCHEDFROMCLOUD = 1",
            requiring: "ZNEEDSTOBEFETCHEDFROMCLOUD"
        )
        let withoutServerRecord = count(
            where: "ZSERVERRECORDDATA IS NULL AND ZTITLE1 IS NOT NULL",
            requiring: "ZSERVERRECORDDATA"
        )

        return NoteStoreSyncStatus(
            pendingDownload: pendingDownload,
            withoutServerRecord: withoutServerRecord,
            note:
                "Counts read from an undocumented schema. -1 means the column is absent on this "
                + "macOS. Objects with no server record include notes in local-only accounts, "
                + "which are not waiting to upload."
        )
    }

    // MARK: - SQLite plumbing

    private func open() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw NotesDatabaseReaderError.unavailable("no database at \(path)")
        }
        var handle: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw NotesDatabaseReaderError.unavailable(detail)
        }
        return handle
    }

    private func requireNoteTable(_ handle: OpaquePointer) throws {
        guard tableExists("ZICCLOUDSYNCINGOBJECT", in: handle) else {
            throw NotesDatabaseReaderError.schemaMissing("the ZICCLOUDSYNCINGOBJECT table")
        }
    }

    private func tableExists(_ name: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(_ column: String, on table: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Table name cannot be bound as a parameter in PRAGMA, so it is only
        // ever passed from the literals in this file, never from a caller.
        let sql = "SELECT 1 FROM pragma_table_info('\(table)') WHERE name = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, column, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// SQLite hands back pointers it owns and will free; copying is required.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - gzip

    /// Apple's Compression framework speaks raw DEFLATE, not gzip, so the
    /// header and trailer are stripped by hand. Header length is variable:
    /// the flag byte says which optional fields follow.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F,
            data[data.startIndex + 1] == 0x8B, data[data.startIndex + 2] == 0x08
        else { return nil }

        let flags = data[data.startIndex + 3]
        var cursor = data.startIndex + 10

        if flags & 0x04 != 0 {  // FEXTRA
            guard cursor + 2 <= data.endIndex else { return nil }
            let extra = Int(data[cursor]) | Int(data[cursor + 1]) << 8
            cursor += 2 + extra
        }
        if flags & 0x08 != 0 {  // FNAME
            while cursor < data.endIndex, data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while cursor < data.endIndex, data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if flags & 0x02 != 0 { cursor += 2 }  // FHCRC

        // The trailer is CRC32 plus the uncompressed size, both 4 bytes.
        let trailer = 8
        guard cursor < data.endIndex - trailer else { return nil }
        let deflated = data[cursor ..< (data.endIndex - trailer)]

        // The trailer's size field is a hint, not a promise; grow if it lies.
        let hinted = data.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        var capacity = max(hinted, deflated.count * 4, 64 * 1024)

        for _ in 0 ..< 4 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                deflated.withUnsafeBytes { source -> Int in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                        let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        destinationBase,
                        capacity,
                        sourceBase,
                        deflated.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0, written < capacity {
                return output.prefix(written)
            }
            if written == 0 { return nil }
            capacity *= 4
        }
        return nil
    }

    // MARK: - protobuf

    /// Walks the note document far enough to find checklist runs.
    ///
    /// Field path, which is Apple's and undocumented:
    ///   document → 2 note → 3 body → { 2 text, 5 attribute runs }
    ///   attribute run → { 1 length, 2 paragraph style }
    ///   paragraph style → { 1 style type (103 = checklist), 5 checklist }
    ///   checklist → 2 done
    ///
    /// Anything unexpected yields no items rather than a wrong answer.
    static func checklistItems(inNoteProtobuf data: Data) -> [NoteChecklistItem] {
        guard let note = field(2, in: data), let body = field(3, in: note),
            let text = field(2, in: body)
        else { return [] }

        // Run lengths are in UTF-16 code units, which is Apple's convention
        // and not the same as characters. An emoji is one Character and two
        // code units, so indexing by Character drifts one place per emoji and
        // silently returns text belonging to the neighbouring item. Verified
        // against real notes: titles here are full of emoji.
        let units = Array(String(decoding: text, as: UTF8.self).utf16)

        var items: [NoteChecklistItem] = []
        var offset = 0
        for run in fields(5, in: body) {
            let length = varintField(1, in: run).map(Int.init) ?? 0
            defer { offset = min(offset + length, units.count) }
            guard length > 0, let style = field(2, in: run),
                varintField(1, in: style) == 103,
                let checklist = field(5, in: style)
            else { continue }
            let isDone = (varintField(2, in: checklist) ?? 0) != 0
            let end = min(offset + length, units.count)
            guard offset < end else { continue }
            let line = String(decoding: units[offset ..< end], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(NoteChecklistItem(text: line, isDone: isDone))
        }
        return items
    }

    /// First length-delimited field with this number.
    private static func field(_ number: Int, in data: Data) -> Data? {
        fields(number, in: data).first
    }

    /// Every length-delimited field with this number.
    private static func fields(_ number: Int, in data: Data) -> [Data] {
        var results: [Data] = []
        forEachField(in: data) { fieldNumber, wireType, payload in
            if fieldNumber == number, wireType == 2, case let .bytes(value) = payload {
                results.append(value)
            }
        }
        return results
    }

    /// First varint field with this number.
    private static func varintField(_ number: Int, in data: Data) -> UInt64? {
        var result: UInt64?
        forEachField(in: data) { fieldNumber, wireType, payload in
            if result == nil, fieldNumber == number, wireType == 0,
                case let .number(value) = payload
            {
                result = value
            }
        }
        return result
    }

    private enum Payload {
        case number(UInt64)
        case bytes(Data)
    }

    /// Minimal protobuf scan. Stops at the first malformed byte instead of
    /// guessing, since a wrong guess here would invent checklist state.
    private static func forEachField(
        in data: Data,
        _ visit: (Int, Int, Payload) -> Void
    ) {
        var index = data.startIndex
        while index < data.endIndex {
            guard let (key, afterKey) = varint(in: data, at: index) else { return }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)
            index = afterKey
            switch wireType {
            case 0:
                guard let (value, next) = varint(in: data, at: index) else { return }
                visit(fieldNumber, wireType, .number(value))
                index = next
            case 1:
                guard index + 8 <= data.endIndex else { return }
                index += 8
            case 2:
                guard let (length, afterLength) = varint(in: data, at: index),
                    afterLength + Int(length) <= data.endIndex
                else { return }
                let end = afterLength + Int(length)
                visit(fieldNumber, wireType, .bytes(data[afterLength ..< end]))
                index = end
            case 5:
                guard index + 4 <= data.endIndex else { return }
                index += 4
            default:
                return
            }
        }
    }

    private static func varint(in data: Data, at start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            value |= UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
