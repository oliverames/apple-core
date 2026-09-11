import Foundation
import Testing

/// Tables and attachments in the Notes Markdown converter.
///
/// The fixtures are the shapes Apple Notes actually emits: tables with no
/// `<th>` anywhere, `<object>` for a file attachment, `<img>` for a pasted or
/// scanned image, and cells holding inline markup and line breaks.
@Suite("Notes rich Markdown conversion")
struct NotesRichMarkdownTests {

    // MARK: - Tables

    @Test("A Notes table renders as a pipe table with an empty header")
    func headerlessTable() {
        let html =
            "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "|  |  |\n| --- | --- |\n| a | b |\n| c | d |"
        )
    }

    @Test("A table with a th first row uses it as the header")
    func headerRow() {
        let html =
            "<table><tr><th>Name</th><th>Qty</th></tr><tr><td>Nails</td><td>12</td></tr></table>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "| Name | Qty |\n| --- | --- |\n| Nails | 12 |"
        )
    }

    @Test("Inline markup inside a cell still converts")
    func inlineMarkupInCell() {
        let html =
            "<table><tr><td><b>bold</b></td>"
            + "<td><a href=\"https://example.com\">link</a></td></tr></table>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "|  |  |\n| --- | --- |\n| **bold** | [link](https://example.com) |"
        )
    }

    @Test("A line break inside a cell becomes a space, not a new row")
    func lineBreakInCell() {
        let html = "<table><tr><td>one<br>two</td><td>three</td></tr></table>"
        let markdown = NotesHTMLMarkdown.convert(html)
        #expect(markdown == "|  |  |\n| --- | --- |\n| one two | three |")
        #expect(markdown.components(separatedBy: "\n").count == 3)
    }

    @Test("A pipe in cell text is escaped rather than inventing a column")
    func escapedPipe() {
        let html = "<table><tr><td>a|b</td><td>c</td></tr></table>"
        #expect(NotesHTMLMarkdown.convert(html) == "|  |  |\n| --- | --- |\n| a\\|b | c |")
    }

    @Test("Ragged rows are padded to the widest row")
    func raggedRows() {
        let html = "<table><tr><td>a</td><td>b</td><td>c</td></tr><tr><td>d</td></tr></table>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "|  |  |  |\n| --- | --- | --- |\n| a | b | c |\n| d |  |  |"
        )
    }

    @Test("Text before and after a table keeps its own lines")
    func tableInDocument() {
        let html =
            "<div>before</div><table><tr><td>a</td></tr></table><div>after</div>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "before\n|  |\n| --- |\n| a |\nafter"
        )
    }

    @Test("An unclosed table is still emitted instead of swallowing the note")
    func unclosedTable() {
        let html = "<div>before</div><table><tr><td>a</td></tr>"
        #expect(NotesHTMLMarkdown.convert(html) == "before\n|  |\n| --- |\n| a |")
    }

    @Test("An empty table produces nothing")
    func emptyTable() {
        #expect(NotesHTMLMarkdown.convert("<div>x</div><table></table>") == "x")
    }

    // MARK: - Attachments

    @Test("Attachment placeholders are counted and left unnamed with no names")
    func unnamedAttachments() {
        let html = "<div>see</div><div><object></object></div><div><img></div>"
        let result = NotesHTMLMarkdown.convert(html, checklist: [], attachmentNames: [])
        #expect(result.attachmentPlaceholders == 2)
        #expect(result.attachmentsNamed == false)
        #expect(result.markdown == "see\n[attachment]\n[attachment]")
    }

    @Test("Names are spent in document order when the counts match")
    func namedAttachments() {
        let html = "<div><object></object></div><div><img></div>"
        let result = NotesHTMLMarkdown.convert(
            html,
            checklist: [],
            attachmentNames: ["Invoice.pdf", "Scan.jpg"]
        )
        #expect(result.attachmentsNamed)
        #expect(result.markdown == "[attachment: Invoice.pdf]\n[attachment: Scan.jpg]")
    }

    @Test("A count mismatch names nothing rather than guessing")
    func mismatchedAttachmentCount() {
        let html = "<div><object></object></div><div><img></div>"
        let result = NotesHTMLMarkdown.convert(
            html,
            checklist: [],
            attachmentNames: ["Only.pdf"]
        )
        #expect(result.attachmentPlaceholders == 2)
        #expect(result.attachmentsNamed == false)
        #expect(result.markdown == "[attachment]\n[attachment]")
    }

    @Test("An empty name disqualifies the whole list")
    func emptyNameRefused() {
        let html = "<div><object></object></div><div><img></div>"
        let result = NotesHTMLMarkdown.convert(
            html,
            checklist: [],
            attachmentNames: ["Invoice.pdf", ""]
        )
        #expect(result.attachmentsNamed == false)
        #expect(result.markdown == "[attachment]\n[attachment]")
    }

    @Test("A note with no attachments reports no placeholders")
    func noAttachments() {
        let result = NotesHTMLMarkdown.convert("<div>hi</div>", checklist: [], attachmentNames: [])
        #expect(result.attachmentPlaceholders == 0)
        #expect(result.attachmentsNamed == false)
        #expect(result.markdown == "hi")
    }

    @Test("An attachment inside a table cell is named in place")
    func attachmentInCell() {
        let html = "<table><tr><td><object></object></td><td>caption</td></tr></table>"
        let result = NotesHTMLMarkdown.convert(
            html,
            checklist: [],
            attachmentNames: ["Receipt.pdf"]
        )
        #expect(result.attachmentPlaceholders == 1)
        #expect(
            result.markdown == "|  |  |\n| --- | --- |\n| [attachment: Receipt.pdf] | caption |"
        )
    }

    // MARK: - The old contract still holds

    @Test("Checklist state and attachments coexist")
    func checklistAndAttachments() {
        let html =
            "<ul class=\"checklist\"><li>Milk</li><li>Eggs</li></ul>"
            + "<div><object></object></div>"
        let result = NotesHTMLMarkdown.convert(
            html,
            checklist: [
                NoteChecklistItem(text: "Milk", isDone: true),
                NoteChecklistItem(text: "Eggs", isDone: false),
            ],
            attachmentNames: ["Photo.heic"]
        )
        #expect(result.markdown == "- [x] Milk\n- [ ] Eggs\n[attachment: Photo.heic]")
    }
}
