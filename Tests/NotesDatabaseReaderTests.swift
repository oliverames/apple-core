import Foundation
import Testing

@Suite("Notes database reads")
struct NotesDatabaseReaderTests {

    // MARK: - Protobuf fixtures

    /// Minimal protobuf encoders, so these tests do not depend on the user's
    /// own notes or on a copy of Apple's format sitting in the repo.
    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number) << 3 | 0) + varint(value)
    }

    private static func bytesField(_ number: Int, _ payload: Data) -> Data {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    /// One attribute run: a length, and optionally a checklist paragraph style.
    private static func run(length: Int, done: Bool?) -> Data {
        var body = varintField(1, UInt64(length))
        if let done {
            let checklist = varintField(2, done ? 1 : 0)
            let style = varintField(1, 103) + bytesField(5, checklist)
            body += bytesField(2, style)
        }
        return bytesField(5, body)
    }

    /// document → 2 note → 3 body → { 2 text, 5 runs }
    private static func document(text: String, runs: [Data]) -> Data {
        let body = bytesField(2, Data(text.utf8)) + runs.reduce(Data(), +)
        return bytesField(2, bytesField(3, body))
    }

    // MARK: - Checklist parsing

    /// The bug this guards against is subtle and silent: Apple measures
    /// attribute runs in UTF-16 code units, so an emoji anywhere earlier in
    /// the note shifts every later slice by one and each item comes back
    /// carrying its neighbour's first character.
    @Test("Checklist text is sliced by UTF-16 code units, not characters")
    func checklistRespectsUTF16Offsets() throws {
        // The pin is one Character and two UTF-16 code units.
        let text = "📌 List\nMilk\nEggs\n"
        let heading = "📌 List\n".utf16.count  // 8, not 7
        let document = Self.document(
            text: text,
            runs: [
                Self.run(length: heading, done: nil),
                Self.run(length: "Milk\n".utf16.count, done: false),
                Self.run(length: "Eggs\n".utf16.count, done: true),
            ]
        )

        let items = NotesDatabaseReader.checklistItems(inNoteProtobuf: document)
        #expect(items.count == 2)
        #expect(items.first?.text == "Milk")
        #expect(items.first?.isDone == false)
        #expect(items.last?.text == "Eggs")
        #expect(items.last?.isDone == true)
    }

    @Test("A note with no checklist runs yields no items")
    func plainNoteHasNoChecklist() throws {
        let document = Self.document(
            text: "Just prose.\n",
            runs: [Self.run(length: "Just prose.\n".utf16.count, done: nil)]
        )
        #expect(NotesDatabaseReader.checklistItems(inNoteProtobuf: document).isEmpty)
    }

    @Test("Malformed protobuf yields no items rather than guessing")
    func malformedProtobufIsEmpty() throws {
        #expect(NotesDatabaseReader.checklistItems(inNoteProtobuf: Data([0xFF, 0xFF, 0xFF])).isEmpty)
        #expect(NotesDatabaseReader.checklistItems(inNoteProtobuf: Data()).isEmpty)
    }

    // MARK: - Identifiers

    @Test("A CoreData note id splits into its store and primary key")
    func noteIdSplits() throws {
        let parsed = try NotesDatabaseReader.components(
            ofNoteId: "x-coredata://83005FC9-9820-46F5-AA25-4F7913E2B3B9/ICNote/p4496"
        )
        #expect(parsed.store == "83005FC9-9820-46F5-AA25-4F7913E2B3B9")
        #expect(parsed.primaryKey == 4496)
    }

    @Test("Anything that is not a CoreData note id is refused")
    func malformedNoteIdIsRefused() throws {
        for bad in ["", "4496", "notes://showNote?identifier=abc", "x-coredata://store/ICNote/4496"] {
            #expect(throws: NotesDatabaseReaderError.malformedId(bad)) {
                try NotesDatabaseReader.components(ofNoteId: bad)
            }
        }
    }

    // MARK: - gzip

    @Test("Non-gzip input is rejected rather than decoded as garbage")
    func gunzipRejectsNonGzip() throws {
        #expect(NotesDatabaseReader.gunzip(Data([0x00, 0x01, 0x02])) == nil)
        #expect(NotesDatabaseReader.gunzip(Data()) == nil)
    }
}
