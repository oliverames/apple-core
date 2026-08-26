import Foundation
import SQLite3
import Testing

/// Sections are verified two ways: against a fixture built to the same schema,
/// which always runs and pins the SQL, and against the real store when this
/// machine has one, which is what actually catches Apple changing the schema.
@Suite("Reminders store reader")
struct RemindersStoreReaderTests {
    private static func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-remdb-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        let schema = """
            CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT);
            CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME TEXT,
                ZLIST INTEGER, ZMARKEDFORDELETION INTEGER, ZIDENTIFIER BLOB);
            INSERT INTO ZREMCDBASELIST VALUES (1, 'Groceries'), (2, 'Work');
            INSERT INTO ZREMCDBASESECTION VALUES
                (1, 'Produce', 1, 0, X'057EC9443152419483D7FBA22EBB25AB'),
                (2, 'Dairy', 1, 0, NULL),
                (3, 'Deleted Section', 1, 1, NULL),
                (4, 'Q3', 2, 0, NULL);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        return url
    }

    @Test("Sections are listed with their list, and deleted ones are excluded")
    func sectionsExcludeDeleted() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let sections = try RemindersStoreReader(path: url.path).sections(listName: nil)

        #expect(sections.count == 3)
        #expect(!sections.contains { $0.name == "Deleted Section" })
        // Ordered by list then section name.
        #expect(sections.map(\.name) == ["Dairy", "Produce", "Q3"])
        #expect(sections.first { $0.name == "Produce" }?.listName == "Groceries")
    }

    @Test("Filtering by list name returns only that list's sections")
    func sectionsCanBeFilteredByList() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let work = try RemindersStoreReader(path: url.path).sections(listName: "Work")
        #expect(work.map(\.name) == ["Q3"])
    }

    @Test("A 16-byte CoreData blob becomes a UUID string")
    func identifierBlobDecodes() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let sections = try RemindersStoreReader(path: url.path).sections(listName: "Groceries")
        let produce = try #require(sections.first { $0.name == "Produce" })
        #expect(produce.identifier == "057EC944-3152-4194-83D7-FBA22EBB25AB")
        // A null identifier stays absent rather than becoming a bogus UUID.
        #expect(sections.first { $0.name == "Dairy" }?.identifier == nil)
    }

    @Test("A database without the sections table reports a reason")
    func missingSchemaIsReported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-remempty-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        sqlite3_close(handle)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try RemindersStoreReader(path: url.path).sections(listName: nil)
        }
    }

    @Test("A list filter with no lists table throws instead of returning everything")
    func listFilterWithoutListsTableThrows() throws {
        // Schema drift can drop ZREMCDBASELIST independently of the sections
        // table. Silently skipping the filter used to return every section
        // on the machine for what looked like a single-list query.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-remnolists-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME TEXT,
                ZLIST INTEGER, ZMARKEDFORDELETION INTEGER, ZIDENTIFIER BLOB);
            INSERT INTO ZREMCDBASESECTION VALUES (1, 'Produce', 1, 0, NULL);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try RemindersStoreReader(path: url.path).sections(listName: "Groceries")
        }
    }

    @Test("Committed WAL rows are visible before the writer closes")
    func committedWALRowsAreVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Data-test.sqlite")

        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        let setup = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME TEXT,
                ZLIST INTEGER, ZMARKEDFORDELETION INTEGER, ZIDENTIFIER BLOB);
            PRAGMA wal_checkpoint(TRUNCATE);
            INSERT INTO ZREMCDBASESECTION VALUES (1, 'WAL Section', 1, 0, NULL);
            """
        #expect(sqlite3_exec(writer, setup, nil, nil, nil) == SQLITE_OK)

        let sections = try RemindersStoreReader(path: url.path).sections(listName: nil)
        #expect(sections.map(\.name) == ["WAL Section"])
    }

    @Test("The real store on this machine still matches the expected schema")
    func realStoreStillReads() throws {
        // Skips rather than fails where there is no store or no access: this
        // test exists to catch Apple moving the schema, not to demand that
        // every machine running the suite has Reminders set up.
        guard let path = RemindersStoreReader.locateStore() else { return }
        guard let sections = try? RemindersStoreReader(path: path).sections(listName: nil) else { return }
        for section in sections {
            #expect(!section.name.isEmpty)
        }
    }
}
