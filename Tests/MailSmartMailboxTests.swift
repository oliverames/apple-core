import Foundation
import Testing

/// The smart-mailbox reader, which parses a private file with no published
/// schema. Every test here is about the reader refusing to pretend: an
/// unreadable file, an unrecognized layout and an empty list are three
/// different answers.
@Suite("Mail smart mailboxes")
struct MailSmartMailboxTests {

    private func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }

    @Test("A dictionary holding a mailboxes array is read")
    func recognizedLayout() {
        let data = plist([
            "mailboxes": [
                [
                    "name": "Unread from Bob",
                    "allCriteriaMustBeSatisfied": true,
                    "criteria": [
                        [
                            "header": "From",
                            "qualifier": "does contain value",
                            "expression": "bob@example.com",
                        ]
                    ],
                ]
            ]
        ])
        let listing = MailSmartMailboxes.parse(data, path: "/x.plist")
        #expect(listing.state == "available")
        #expect(listing.mailboxes.count == 1)
        let box = listing.mailboxes[0]
        #expect(box.name == "Unread from Bob")
        #expect(box.allConditionsMustMatch == true)
        #expect(box.conditions.count == 1)
        #expect(box.conditions[0].field == "From")
        #expect(box.conditions[0].comparison == "does contain value")
        #expect(box.conditions[0].value == "bob@example.com")
        #expect(box.conditions[0].unmappedKeys.isEmpty)
        #expect(box.unmappedKeys.isEmpty)
    }

    @Test("A root that is itself an array of mailboxes is read")
    func arrayRoot() {
        let data = plist([["name": "Flagged", "criteria": [["header": "Flagged"]]]])
        let listing = MailSmartMailboxes.parse(data, path: "/x.plist")
        #expect(listing.state == "available")
        #expect(listing.mailboxes.first?.name == "Flagged")
    }

    @Test("A key this reader cannot place is reported, not dropped")
    func unmappedKeysReported() {
        let data = plist([
            "mailboxes": [
                [
                    "name": "Box",
                    "UUID": "1234",
                    "someFutureFlag": true,
                    "criteria": [["header": "From", "unknownThing": "x"]],
                ]
            ]
        ])
        let box = MailSmartMailboxes.parse(data, path: "/x.plist").mailboxes[0]
        #expect(box.unmappedKeys.contains("UUID"))
        #expect(box.unmappedKeys.contains("someFutureFlag"))
        #expect(box.conditions[0].unmappedKeys.contains("unknownThing"))
    }

    @Test("A layout with no recognizable mailbox array is unrecognized, not empty")
    func unrecognizedLayout() {
        let data = plist(["version": 3, "state": "whatever"])
        let listing = MailSmartMailboxes.parse(data, path: "/x.plist")
        #expect(listing.state == "unrecognized")
        #expect(listing.mailboxes.isEmpty)
        #expect(listing.topLevelKeys == ["state", "version"])
        #expect(listing.detail.contains("no published schema"))
    }

    @Test("Two candidate arrays with no mailbox-like name are refused rather than guessed")
    func ambiguousLayout() {
        let data = plist([
            "alpha": [["name": "a"]],
            "beta": [["name": "b"]],
        ])
        let listing = MailSmartMailboxes.parse(data, path: "/x.plist")
        #expect(listing.state == "unrecognized")
    }

    @Test("A single unnamed array of dictionaries is still read")
    func singleCandidateArray() {
        let data = plist(["entries": [["name": "Only"]]])
        let listing = MailSmartMailboxes.parse(data, path: "/x.plist")
        #expect(listing.state == "available")
        #expect(listing.mailboxes.first?.name == "Only")
    }

    @Test("An empty mailboxes array is available with none, not unrecognized")
    func emptyList() {
        let listing = MailSmartMailboxes.parse(plist(["mailboxes": [Any]()]), path: "/x.plist")
        #expect(listing.state == "available")
        #expect(listing.mailboxes.isEmpty)
        #expect(listing.detail.contains("Read 0 smart mailbox"))
    }

    @Test("A file that is not a property list is unreadable, not empty")
    func notAPropertyList() {
        let listing = MailSmartMailboxes.parse(Data("not a plist".utf8), path: "/x.plist")
        #expect(listing.state == "unreadable")
        #expect(listing.mailboxes.isEmpty)
    }

    @Test("A structured condition value is left unmapped rather than flattened")
    func structuredValue() {
        let data = plist([
            "mailboxes": [["name": "Box", "criteria": [["expression": ["a", "b"]]]]]
        ])
        let condition = MailSmartMailboxes.parse(data, path: "/x.plist").mailboxes[0].conditions[0]
        #expect(condition.value == nil)
        #expect(condition.unmappedKeys == ["expression"])
    }

    @Test("A numeric or boolean condition value is rendered as text")
    func scalarValues() {
        let data = plist([
            "mailboxes": [["name": "Box", "criteria": [["header": "Size", "value": 1024]]]]
        ])
        let condition = MailSmartMailboxes.parse(data, path: "/x.plist").mailboxes[0].conditions[0]
        #expect(condition.value == "1024")
    }

    @Test("A long list is capped and says so")
    func cappedList() {
        let entries = (0 ..< (MailSmartMailboxes.maximumMailboxes + 5)).map {
            ["name": "Box \($0)"]
        }
        let listing = MailSmartMailboxes.parse(plist(["mailboxes": entries]), path: "/x.plist")
        #expect(listing.mailboxes.count == MailSmartMailboxes.maximumMailboxes)
        #expect(listing.detail.contains("of \(MailSmartMailboxes.maximumMailboxes + 5)"))
    }

    // MARK: - Against a fixture store on disk

    @Test("A store with no smart mailbox file reports not_found")
    func missingFileInFixtureStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-\(UUID().uuidString)", isDirectory: true)
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = MailSmartMailboxes.list(store: MailLocalStore(root: root))
        #expect(listing.state == "not_found")
        #expect(listing.path.hasSuffix("SyncedSmartMailboxes.plist"))
    }

    @Test("A fixture store with a smart mailbox file is read end to end")
    func fixtureStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-\(UUID().uuidString)", isDirectory: true)
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try plist(["mailboxes": [["name": "Receipts"]]])
            .write(to: mailData.appendingPathComponent(MailSmartMailboxes.fileName))

        let listing = MailSmartMailboxes.list(store: MailLocalStore(root: root))
        #expect(listing.state == "available")
        #expect(listing.mailboxes.first?.name == "Receipts")
    }
}
