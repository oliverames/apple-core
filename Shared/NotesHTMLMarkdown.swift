// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - HTML to Markdown

/// Converts the constrained HTML that Apple Notes emits into Markdown.
///
/// Notes bodies use a small, predictable subset: one `<div>` per line,
/// `<h1>`-`<h3>` headings, `<b>`/`<i>`/`<u>`/`<strike>` inline styles,
/// `<ul>`/`<ol>` lists (nested via nested list tags), `<a href>` links,
/// `<tt>` monospace, and `<br>` for blank lines. This is a deliberately
/// small hand-rolled converter for exactly that subset; anything
/// unrecognized is dropped, keeping only its text content.
///
/// Checklist ticked-state is not in the HTML at all: Notes strips it before
/// handing the body to AppleScript. It is read separately out of
/// NoteStore.sqlite by NotesDatabaseReader and merged back in here, so the
/// two halves of a checklist arrive by two different routes and are joined
/// by `convert(_:checklist:)`.
enum NotesHTMLMarkdown {
    /// Marks a bullet the HTML said belongs to a checklist. Stripped before
    /// the converter returns; U+0000 cannot survive in note text.
    private static let checklistMark = "\u{0}"

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
        annotate(render(html), with: checklist)
    }

    private static func render(_ html: String) -> String {
        var output = ""
        var listStack: [(ordered: Bool, index: Int, checklist: Bool)] = []
        var pendingHref: String? = nil
        var index = html.startIndex

        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let rawTag = String(html[html.index(after: index) ..< close])
                index = html.index(after: close)
                handle(
                    tag: rawTag,
                    output: &output,
                    listStack: &listStack,
                    pendingHref: &pendingHref
                )
            } else if character == "&" {
                let (decoded, next) = decodeEntity(in: html, at: index)
                output.append(decoded)
                index = next
            } else if character == "\n" {
                // Literal newlines between tags are formatting noise.
                index = html.index(after: index)
            } else {
                output.append(character)
                index = html.index(after: index)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func handle(
        tag rawTag: String,
        output: inout String,
        listStack: inout [(ordered: Bool, index: Int, checklist: Bool)],
        pendingHref: inout String?
    ) {
        let isClosing = rawTag.hasPrefix("/")
        let body = isClosing ? String(rawTag.dropFirst()) : rawTag
        let name =
            body
            .prefix(while: { !$0.isWhitespace && $0 != "/" })
            .lowercased()

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if isClosing {
                endBlock(&output)
            } else {
                endBlock(&output)
                let level = Int(String(name.dropFirst())) ?? 1
                output.append(String(repeating: "#", count: level) + " ")
            }
        case "b", "strong":
            output.append("**")
        case "i", "em":
            output.append("*")
        case "strike", "s", "del":
            output.append("~~")
        case "tt", "code":
            output.append("`")
        case "pre":
            endBlock(&output)
            output.append(isClosing ? "```\n" : "```\n")
        case "blockquote":
            if !isClosing {
                endBlock(&output)
                output.append("> ")
            } else {
                endBlock(&output)
            }
        case "a":
            if isClosing {
                if let href = pendingHref {
                    output.append("](\(href))")
                    pendingHref = nil
                }
            } else if let href = attribute("href", in: body) {
                pendingHref = href
                output.append("[")
            }
        case "ul", "ol":
            if isClosing {
                if !listStack.isEmpty { listStack.removeLast() }
                if listStack.isEmpty { endBlock(&output) }
            } else {
                let classes = attribute("class", in: body)?.lowercased() ?? ""
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
                endBlock(&output)
                let depth = max(listStack.count - 1, 0)
                output.append(String(repeating: "    ", count: depth))
                if listStack.isEmpty {
                    output.append("- ")
                } else {
                    var top = listStack.removeLast()
                    top.index += 1
                    listStack.append(top)
                    output.append(top.ordered ? "\(top.index). " : "- ")
                    if top.checklist { output.append(checklistMark) }
                }
            }
        case "div", "p":
            if isClosing { endBlock(&output) }
        case "br":
            output.append("\n")
        case "img", "object":
            if !isClosing { output.append("[attachment]") }
        default:
            break
        }
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

    /// Ends the current output line: trims trailing spaces and ensures a
    /// terminating newline.
    private static func endBlock(_ output: inout String) {
        while output.hasSuffix(" ") { output.removeLast() }
        if !output.isEmpty && !output.hasSuffix("\n") {
            output.append("\n")
        }
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
