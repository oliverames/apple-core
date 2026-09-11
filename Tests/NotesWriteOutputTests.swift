import Foundation
import Testing

/// Live testing on 2026-09-11 found `notes_create` committing a note and then
/// failing, because Notes raises -1728 reading the container of a note it has
/// just made. The caller was told the write failed, retried, and produced a
/// duplicate. These pin the contract that a write which happened is reported as
/// having happened, with or without a folder name.
@Suite("Notes write output")
struct NotesWriteOutputTests {
    @Test("A full result carries the identifier, name and folder")
    func fullResult() throws {
        let parsed = try NotesWriteOutput.parse("x-coredata://ICNote/p1\nGuard test\nNotes")
        #expect(parsed.id == "x-coredata://ICNote/p1")
        #expect(parsed.name == "Guard test")
        #expect(parsed.folderName == "Notes")
    }

    @Test("A note whose container Notes would not name still parses as a success")
    func missingFolderIsNotAFailure() throws {
        // What the hardened script now emits when `name of container` raises.
        let parsed = try NotesWriteOutput.parse("x-coredata://ICNote/p1\nGuard test\n")
        #expect(parsed.id == "x-coredata://ICNote/p1")
        #expect(parsed.name == "Guard test")
        #expect(parsed.folderName == nil)
    }

    @Test("An absent folder is absent rather than a folder named empty")
    func emptyFolderIsNil() throws {
        #expect(try NotesWriteOutput.parse("id\nname\n").folderName == nil)
        #expect(try NotesWriteOutput.parse("id\nname").folderName == nil)
    }

    @Test("A truncated result still succeeds as long as the note has an identifier")
    func identifierAloneSucceeds() throws {
        let parsed = try NotesWriteOutput.parse("x-coredata://ICNote/p1")
        #expect(parsed.id == "x-coredata://ICNote/p1")
        #expect(parsed.name.isEmpty)
        #expect(parsed.folderName == nil)
    }

    @Test("Output with no identifier is the one case that is a genuine failure")
    func missingIdentifierThrows() {
        #expect(throws: NotesWriteOutput.ParseError.missingIdentifier("")) {
            try NotesWriteOutput.parse("")
        }
        #expect(throws: NotesWriteOutput.ParseError.missingIdentifier("\nname\nfolder")) {
            try NotesWriteOutput.parse("\nname\nfolder")
        }
    }

    @Test("A folder name containing spaces survives intact")
    func folderWithSpaces() throws {
        #expect(try NotesWriteOutput.parse("id\nname\nHome Inspiration").folderName == "Home Inspiration")
    }
}
