import Foundation
import Testing

@Suite("Notes Markdown conversion")
struct NotesHTMLMarkdownTests {

    private func item(_ text: String, _ isDone: Bool) -> NoteChecklistItem {
        NoteChecklistItem(text: text, isDone: isDone)
    }

    // MARK: - Existing conversion is unchanged

    @Test("Headings, emphasis and links convert as before")
    func plainConversion() {
        let html =
            "<h2>Title</h2><div><b>bold</b> and <i>italic</i></div>"
            + "<div><a href=\"https://example.com\">link</a></div>"
        #expect(
            NotesHTMLMarkdown.convert(html)
                == "## Title\n**bold** and *italic*\n[link](https://example.com)"
        )
    }

    @Test("An ordinary list with no checklist state is untouched")
    func ordinaryList() {
        let html = "<ul><li>one</li><li>two</li></ul>"
        #expect(NotesHTMLMarkdown.convert(html) == "- one\n- two")
        #expect(NotesHTMLMarkdown.convert(html, checklist: []) == "- one\n- two")
    }

    // MARK: - Checklist state

    @Test("Ticked and unticked rows become [x] and [ ]")
    func checklistState() {
        let html = "<ul class=\"checklist\"><li>Milk</li><li>Eggs</li><li>Bread</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [item("Milk", true), item("Eggs", false), item("Bread", true)]
        )
        #expect(markdown == "- [x] Milk\n- [ ] Eggs\n- [x] Bread")
    }

    @Test("Duplicate labels keep their own states, in order")
    func duplicateLabels() {
        let html = "<ul class=\"checklist\"><li>Milk</li><li>Milk</li><li>Milk</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [item("Milk", false), item("Milk", true), item("Milk", false)]
        )
        #expect(markdown == "- [ ] Milk\n- [x] Milk\n- [ ] Milk")
    }

    @Test("Nested checklists keep both their indentation and their states")
    func nestedChecklist() {
        let html = """
            <ul class="checklist">
                <li>Pack</li>
                <ul class="checklist"><li>Socks</li><li>Charger</li></ul>
                <li>Leave</li>
            </ul>
            """
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [
                item("Pack", false), item("Socks", true), item("Charger", false),
                item("Leave", false),
            ]
        )
        #expect(
            markdown == """
                - [ ] Pack
                    - [x] Socks
                    - [ ] Charger
                - [ ] Leave
                """
        )
    }

    @Test("Emoji and combining marks do not shift the state onto the next row")
    func unicodeOffsets() {
        // The database reports run lengths in UTF-16 code units, so an emoji
        // is the case where a naive character walk drifts by one.
        let html = "<ul class=\"checklist\"><li>Café ☕️</li><li>👩🏽‍💻 Ship it</li><li>Done</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [item("Café ☕️", true), item("👩🏽‍💻 Ship it", false), item("Done", true)]
        )
        #expect(markdown == "- [x] Café ☕️\n- [ ] 👩🏽‍💻 Ship it\n- [x] Done")
    }

    @Test("An emphasised row still matches its plain database text")
    func emphasisedRow() {
        let html = "<ul class=\"checklist\"><li><b>Milk</b></li></ul>"
        let markdown = NotesHTMLMarkdown.convert(html, checklist: [item("Milk", true)])
        #expect(markdown == "- [x] **Milk**")
    }

    @Test("A linked row matches on its label, not its target")
    func linkedRow() {
        let html = "<ul class=\"checklist\"><li><a href=\"https://example.com\">Renew</a></li></ul>"
        let markdown = NotesHTMLMarkdown.convert(html, checklist: [item("Renew", false)])
        #expect(markdown == "- [ ] [Renew](https://example.com)")
    }

    @Test("An ordinary list beside a marked checklist is left alone")
    func mixedLists() {
        let html = "<ul><li>Milk</li></ul><ul class=\"checklist\"><li>Milk</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(html, checklist: [item("Milk", true)])
        #expect(markdown == "- Milk\n- [x] Milk")
    }

    @Test("An unmarked checklist still picks up state from matching rows")
    func unmarkedChecklist() {
        // Bodies that carry no class attribute fall back to matching every
        // bullet, which is the older Notes HTML shape.
        let html = "<ul><li>Milk</li><li>Eggs</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [item("Milk", true), item("Eggs", false)]
        )
        #expect(markdown == "- [x] Milk\n- [ ] Eggs")
    }

    @Test("A row that matches nothing is left unspent rather than guessed at")
    func noMatch() {
        let html = "<ul class=\"checklist\"><li>Milk</li></ul>"
        let markdown = NotesHTMLMarkdown.convert(html, checklist: [item("Something else", true)])
        #expect(markdown == "- Milk")
    }

    @Test("The sentinel never reaches the output, with or without state")
    func noSentinelLeaks() {
        let html = "<ul class=\"checklist\"><li>Milk</li><li>Eggs</li></ul>"
        for checklist in [[], [item("Milk", true)], [item("Milk", true), item("Eggs", false)]] {
            #expect(!NotesHTMLMarkdown.convert(html, checklist: checklist).contains("\u{0}"))
        }
    }

    @Test("Numbered checklists keep their numbering")
    func orderedChecklist() {
        let html = "<ol class=\"checklist\"><li>First</li><li>Second</li></ol>"
        let markdown = NotesHTMLMarkdown.convert(
            html,
            checklist: [item("First", true), item("Second", false)]
        )
        #expect(markdown == "1. [x] First\n2. [ ] Second")
    }

    @Test("Body text around a checklist is preserved")
    func surroundingText() {
        let html = "<h1>Trip</h1><ul class=\"checklist\"><li>Passport</li></ul><div>Leave at 6.</div>"
        let markdown = NotesHTMLMarkdown.convert(html, checklist: [item("Passport", true)])
        #expect(markdown == "# Trip\n- [x] Passport\nLeave at 6.")
    }
}
