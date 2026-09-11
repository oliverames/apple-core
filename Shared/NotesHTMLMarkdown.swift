// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Rendered result

/// Markdown plus the facts about it a caller has to relay.
///
/// `attachmentPlaceholders` is the number of attachment slots the body
/// actually contains, and `attachmentsNamed` says whether the names supplied
/// by the caller were spent on them. The two are separate because a note can
/// hold attachments the body never references, and a caller that is told only
/// "3 attachments" cannot tell an unnamed placeholder from a missing one.
struct NotesMarkdownResult: Sendable, Equatable {
    let markdown: String
    let attachmentPlaceholders: Int
    let attachmentsNamed: Bool
}

// MARK: - HTML to Markdown

/// Converts the constrained HTML that Apple Notes emits into Markdown.
///
/// Notes bodies use a small, predictable subset: one `<div>` per line,
/// `<h1>`-`<h3>` headings, `<b>`/`<i>`/`<u>`/`<strike>` inline styles,
/// `<ul>`/`<ol>` lists (nested via nested list tags), `<a href>` links,
/// `<tt>` monospace, `<table>`/`<tr>`/`<td>` tables, and `<br>` for blank
/// lines. This is a deliberately small hand-rolled converter for exactly that
/// subset; anything unrecognized is dropped, keeping only its text content.
///
/// Two things in a note body are not in the HTML at all and arrive by other
/// routes:
///
///   - Checklist ticked-state, which Notes strips before handing the body to
///     AppleScript. It is read out of NoteStore.sqlite by NotesDatabaseReader
///     and merged back in here.
///   - Attachment names, which the body references only as an empty `<object>`
///     or `<img>`. They are listed by Notes' own `attachments` element and
///     merged back in here the same way.
///
/// Neither is guessed at when it does not line up. See `annotate` and
/// `spendAttachments`.
enum NotesHTMLMarkdown {
    /// Marks a bullet the HTML said belongs to a checklist. Stripped before
    /// the converter returns; U+0000 cannot survive in note text.
    private static let checklistMark = "\u{0}"

    /// Marks the position of an attachment in the body, before it is either
    /// named or written out as a bare placeholder. U+0001, for the same
    /// reason.
    private static let attachmentMark = "\u{1}"

    static func convert(_ html: String) -> String {
        convert(html, checklist: [])
    }

    /// Converts `html`, spending `checklist` on the list items it produces in
    /// document order so each renders as `- [x]` or `- [ ]`.
    ///
    /// The two sources are matched positionally, not by identity, because the
    /// database rows carry no HTML anchor. Position is what Notes itself
    /// guarantees, and it is what makes duplicate labels come out right:
    /// two rows both reading "Milk" keep their own states because they are
    /// consumed in order. Text is compared after stripping the Markdown the
    /// converter just added, so an emphasised item still matches its plain
    /// database row.
    ///
    /// When the HTML marks its checklist lists (`<ul class="checklist">`),
    /// only those bullets are candidates. Older bodies that do not are
    /// matched against every bullet, so an ordinary bullet whose text happens
    /// to equal the next unconsumed checklist row can take that row's state.
    /// A row that matches nothing is left unspent rather than guessed at.
    static func convert(_ html: String, checklist: [NoteChecklistItem]) -> String {
        convert(html, checklist: checklist, attachmentNames: []).markdown
    }

    /// Converts `html`, merging in checklist state and attachment names.
    ///
    /// `attachmentNames` must be in the order Notes lists them. They are spent
    /// on the body's attachment placeholders only when there are exactly as
    /// many names as placeholders: Notes' `attachments` element is not
    /// promised to be in document order, so a mismatched count is the one
    /// signal available that the two lists cannot be lined up. When they
    /// cannot, every placeholder stays an unnamed `[attachment]` rather than
    /// carrying a name that might belong to a different file.
    static func convert(
        _ html: String,
        checklist: [NoteChecklistItem],
        attachmentNames: [String]
    ) -> NotesMarkdownResult {
        let rendered = annotate(render(html), with: checklist)
        return spendAttachments(rendered, names: attachmentNames)
    }

    private static func render(_ html: String) -> String {
        var renderer = Renderer()
        var index = html.startIndex

        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let rawTag = String(html[html.index(after: index) ..< close])
                index = html.index(after: close)
                renderer.handle(tag: rawTag)
            } else if character == "&" {
                let (decoded, next) = decodeEntity(in: html, at: index)
                renderer.emit(decoded)
                index = next
            } else if character == "\n" {
                // Literal newlines between tags are formatting noise.
                index = html.index(after: index)
            } else {
                renderer.emit(String(character))
                index = html.index(after: index)
            }
        }
        return renderer.finish()
    }

    // MARK: - Renderer

    /// The converter's whole mutable state: the text so far, the list nesting,
    /// a half-built link, and the stack of tables being filled.
    ///
    /// Text is written through `emit`, which is what makes tables work: while
    /// a cell is open every append lands in that cell instead of in the
    /// document, so the existing inline handling (bold, links, entities) works
    /// inside a table without knowing tables exist.
    private struct Renderer {
        private var output = ""
        private var listStack: [(ordered: Bool, index: Int, checklist: Bool)] = []
        private var pendingHref: String?
        private var tables: [TableBuilder] = []

        /// True while a table cell is open, which changes what a line break
        /// means: a Markdown table row cannot contain one.
        private var inCell: Bool {
            tables.last?.hasOpenCell ?? false
        }

        mutating func emit(_ text: String) {
            if !tables.isEmpty {
                // Text between a `</td>` and the next `<td>` is layout, not
                // content, and there is nowhere in a Markdown table to put it.
                if inCell { tables[tables.count - 1].append(text) }
                return
            }
            output.append(text)
        }

        /// Ends the current output line: trims trailing spaces and ensures a
        /// terminating newline. Inside a cell there are no lines, so a break
        /// collapses to a single space instead.
        mutating func endBlock() {
            if !tables.isEmpty {
                if inCell { tables[tables.count - 1].append(" ") }
                return
            }
            while output.hasSuffix(" ") { output.removeLast() }
            if !output.isEmpty && !output.hasSuffix("\n") {
                output.append("\n")
            }
        }

        mutating func finish() -> String {
            // An unclosed <table> would otherwise swallow the rest of the
            // note. Flush what was collected instead of dropping it.
            while !tables.isEmpty { closeTable() }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private mutating func closeTable() {
            guard var table = tables.popLast() else { return }
            let markdown = table.markdown()
            guard !markdown.isEmpty else { return }
            endBlock()
            emit(markdown)
            endBlock()
        }

        mutating func handle(tag rawTag: String) {
            let isClosing = rawTag.hasPrefix("/")
            let body = isClosing ? String(rawTag.dropFirst()) : rawTag
            let name =
                body
                .prefix(while: { !$0.isWhitespace && $0 != "/" })
                .lowercased()

            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if isClosing {
                    endBlock()
                } else {
                    endBlock()
                    let level = Int(String(name.dropFirst())) ?? 1
                    emit(String(repeating: "#", count: level) + " ")
                }
            case "b", "strong":
                emit("**")
            case "i", "em":
                emit("*")
            case "strike", "s", "del":
                emit("~~")
            case "tt", "code":
                emit("`")
            case "pre":
                endBlock()
                emit("```\n")
            case "blockquote":
                endBlock()
                if !isClosing { emit("> ") }
            case "a":
                if isClosing {
                    if let href = pendingHref {
                        emit("](\(href))")
                        pendingHref = nil
                    }
                } else if let href = NotesHTMLMarkdown.attribute("href", in: body) {
                    pendingHref = href
                    emit("[")
                }
            case "table":
                if isClosing {
                    closeTable()
                } else {
                    endBlock()
                    tables.append(TableBuilder())
                }
            case "tr":
                guard !tables.isEmpty else { break }
                if isClosing {
                    tables[tables.count - 1].endRow()
                } else {
                    tables[tables.count - 1].startRow()
                }
            case "td", "th":
                guard !tables.isEmpty else { break }
                if isClosing {
                    tables[tables.count - 1].endCell()
                } else {
                    tables[tables.count - 1].startCell(header: name == "th")
                }
            case "ul", "ol":
                if isClosing {
                    if !listStack.isEmpty { listStack.removeLast() }
                    if listStack.isEmpty { endBlock() }
                } else {
                    let classes =
                        NotesHTMLMarkdown.attribute("class", in: body)?.lowercased() ?? ""
                    listStack.append(
                        (
                            ordered: name == "ol",
                            index: 0,
                            checklist: classes.contains("checklist")
                        )
                    )
                }
            case "li":
                if !isClosing {
                    endBlock()
                    let depth = max(listStack.count - 1, 0)
                    emit(String(repeating: "    ", count: depth))
                    if listStack.isEmpty {
                        emit("- ")
                    } else {
                        var top = listStack.removeLast()
                        top.index += 1
                        listStack.append(top)
                        emit(top.ordered ? "\(top.index). " : "- ")
                        if top.checklist { emit(NotesHTMLMarkdown.checklistMark) }
                    }
                }
            case "div", "p":
                if isClosing { endBlock() }
            case "br":
                if inCell {
                    emit(" ")
                } else {
                    emit("\n")
                }
            case "img", "object":
                if !isClosing { emit(NotesHTMLMarkdown.attachmentMark) }
            default:
                break
            }
        }
    }

    // MARK: - Tables

    /// Collects `<tr>`/`<td>` content and writes it out as a GitHub-flavoured
    /// pipe table.
    ///
    /// Apple Notes tables have no header row: the app's own HTML is all
    /// `<td>`. Markdown has no way to write a headerless table, so a table
    /// that never supplied a `<th>` gets an empty header row and keeps every
    /// one of its own rows as data. Promoting the first row instead would be
    /// the one change here that alters what the note says.
    private struct TableBuilder {
        private var rows: [[String]] = []
        private var currentRow: [String]?
        private var currentCell: String?
        private var headerRowIndex: Int?

        var hasOpenCell: Bool { currentCell != nil }

        /// Adds rendered text to the open cell. Text arriving with no cell
        /// open is layout between cells and is dropped by `emit`.
        mutating func append(_ text: String) {
            currentCell?.append(text)
        }

        mutating func startRow() {
            endRow()
            currentRow = []
        }

        mutating func endRow() {
            endCell()
            if let row = currentRow, !row.isEmpty { rows.append(row) }
            currentRow = nil
        }

        mutating func startCell(header: Bool) {
            endCell()
            if currentRow == nil { currentRow = [] }
            if header && headerRowIndex == nil { headerRowIndex = rows.count }
            currentCell = ""
        }

        mutating func endCell() {
            guard let cell = currentCell else { return }
            currentCell = nil
            if currentRow == nil { currentRow = [] }
            currentRow?.append(TableBuilder.clean(cell))
        }

        mutating func markdown() -> String {
            endRow()
            guard !rows.isEmpty else { return "" }
            let width = rows.map(\.count).max() ?? 0
            guard width > 0 else { return "" }

            var body = rows.map { row in
                row + Array(repeating: "", count: width - row.count)
            }
            var header = Array(repeating: "", count: width)
            // Only a header that is genuinely the first row can be lifted out
            // of the body; a `<th>` further down stays where the note put it.
            if headerRowIndex == 0 { header = body.removeFirst() }

            var lines = [line(header), line(Array(repeating: "---", count: width))]
            lines.append(contentsOf: body.map { line($0) })
            return lines.joined(separator: "\n")
        }

        private func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }

        /// A cell's text as one line: whitespace collapsed, pipes escaped so
        /// they cannot invent a column.
        private static func clean(_ text: String) -> String {
            let collapsed =
                text
                .replacingOccurrences(of: "|", with: "\\|")
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
                .joined(separator: " ")
            return collapsed.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Attachment merge

    /// Names the body's attachment placeholders, or leaves every one of them
    /// unnamed. See `convert(_:checklist:attachmentNames:)` for why it is all
    /// or nothing.
    private static func spendAttachments(
        _ markdown: String,
        names: [String]
    ) -> NotesMarkdownResult {
        let placeholders = markdown.filter { $0 == "\u{1}" }.count
        guard placeholders > 0 else {
            return NotesMarkdownResult(
                markdown: markdown,
                attachmentPlaceholders: 0,
                attachmentsNamed: false
            )
        }
        let usable =
            names.count == placeholders && names.allSatisfy { !$0.isEmpty }
        guard usable else {
            return NotesMarkdownResult(
                markdown: markdown.replacingOccurrences(of: attachmentMark, with: "[attachment]"),
                attachmentPlaceholders: placeholders,
                attachmentsNamed: false
            )
        }
        var output = ""
        var remaining = names[...]
        for character in markdown {
            if character == "\u{1}", let name = remaining.first {
                remaining = remaining.dropFirst()
                output.append("[attachment: \(name)]")
            } else if character == "\u{1}" {
                output.append("[attachment]")
            } else {
                output.append(character)
            }
        }
        return NotesMarkdownResult(
            markdown: output,
            attachmentPlaceholders: placeholders,
            attachmentsNamed: true
        )
    }

    // MARK: - Checklist merge

    /// Spends `checklist` on the rendered bullets, in order.
    private static func annotate(_ markdown: String, with checklist: [NoteChecklistItem]) -> String {
        let marked = markdown.contains(checklistMark)
        guard !checklist.isEmpty else {
            return marked ? markdown.replacingOccurrences(of: checklistMark, with: "") : markdown
        }

        var remaining = checklist[...]
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let isCandidate = marked ? line.contains(checklistMark) : bulletBody(of: line) != nil
            let clean = line.replacingOccurrences(of: checklistMark, with: "")
            guard isCandidate, let body = bulletBody(of: clean), let next = remaining.first,
                comparable(body) == comparable(next.text)
            else {
                lines.append(clean)
                continue
            }
            remaining = remaining.dropFirst()
            let box = next.isDone ? "[x] " : "[ ] "
            lines.append(clean.replacingOccurrences(of: body, with: box + body, options: [.backwards]))
        }
        return lines.joined(separator: "\n")
    }

    /// The text of a Markdown bullet or numbered item, or nil for any other
    /// line. Leading indentation is nesting, so it is deliberately ignored.
    private static func bulletBody(of line: String) -> String? {
        var rest = Substring(line).drop(while: { $0 == " " })
        if rest.hasPrefix("- ") {
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
            rest = rest.dropFirst(digits.count + 2)
        }
        return rest.isEmpty ? nil : String(rest)
    }

    /// Text stripped of the emphasis, code and link syntax the converter adds,
    /// so a rendered bullet can be compared with a plain database row. A
    /// link keeps its label and loses its target, which is what the database
    /// row holds.
    private static func comparable(_ text: String) -> String {
        var stripped = ""
        var index = text.startIndex
        var afterLinkLabel = false
        while index < text.endIndex {
            let character = text[index]
            if character == "(", afterLinkLabel, let close = text[index...].firstIndex(of: ")") {
                afterLinkLabel = false
                index = text.index(after: close)
                continue
            }
            afterLinkLabel = character == "]"
            if !"[]*~`_".contains(character) {
                stripped.append(character)
            }
            index = text.index(after: index)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts a quoted attribute value from a raw tag body.
    private static func attribute(_ attributeName: String, in tagBody: String) -> String? {
        let lowered = tagBody.lowercased()
        guard let nameRange = lowered.range(of: attributeName + "=\"") else { return nil }
        let valueStart = tagBody.index(nameRange.lowerBound, offsetBy: attributeName.count + 2)
        guard let valueEnd = tagBody[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(tagBody[valueStart ..< valueEnd])
    }

    /// Decodes the entity starting at `index`; returns the decoded text and
    /// the index to resume from. Unknown entities pass through literally.
    private static func decodeEntity(
        in html: String,
        at index: String.Index
    ) -> (String, String.Index) {
        guard let semicolon = html[index...].firstIndex(of: ";"),
            html.distance(from: index, to: semicolon) <= 10
        else {
            return ("&", html.index(after: index))
        }
        let entity = String(html[html.index(after: index) ..< semicolon])
        let next = html.index(after: semicolon)
        switch entity {
        case "amp": return ("&", next)
        case "lt": return ("<", next)
        case "gt": return (">", next)
        case "quot": return ("\"", next)
        case "apos": return ("'", next)
        case "nbsp": return (" ", next)
        default:
            if entity.hasPrefix("#"),
                let code = UInt32(entity.dropFirst()),
                let scalar = Unicode.Scalar(code)
            {
                return (String(Character(scalar)), next)
            }
            return ("&", html.index(after: index))
        }
    }
}
