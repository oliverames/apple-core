// SPDX-License-Identifier: GPL-3.0-or-later
//
// The raw header block of a message, turned into something a caller can read.
//
// Mail exposes two properties nothing in this service surfaced before:
// `all headers`, the RFC 5322 header block exactly as it arrived, and
// `source`, the whole message including its body and MIME parts. They are the
// ground truth behind every question that message metadata cannot answer:
// which relay added the delay, whether SPF and DKIM passed, what the real
// List-Unsubscribe target is, which mailing list stamped the message.
//
// This file does the parsing, because parsing RFC 5322 in JXA and trusting
// the result is how you get a threading bug that only shows up on Outlook
// mail. Three details matter and each one is tested:
//
//   - Folding. A long header is split across lines and continued with leading
//     whitespace. Unfolding rejoins them, collapsing the fold to one space,
//     which is what RFC 5322 §2.2.3 says the folded whitespace means.
//   - Repeats. `Received` appears once per hop and the order is the delivery
//     path in reverse. An API that returns a dictionary loses that, so this
//     one returns an ordered array and offers lookup on top of it.
//   - The body boundary. The header block ends at the first empty line, and
//     `source` carries a body after it that must not be parsed as headers.
//
// Nothing here truncates on its own. The caller decides the byte budget,
// because the honest thing to tell a caller is how much was cut, and only the
// caller knows how much it asked for.

import Foundation

/// One header field, in the order it appeared.
struct MailHeaderField: Sendable, Codable, Equatable {
    let name: String
    let value: String
}

enum MailHeaderBlock {
    /// Splits a raw message into its header block and its body.
    ///
    /// Accepts CRLF, LF, and the lone-CR that some Mail versions hand back.
    /// A message with no empty line is all headers and no body, which is what
    /// `all headers` gives you.
    static func split(rawMessage: String) -> (headers: String, body: String?) {
        let normalized = normalizeLineEndings(rawMessage)
        guard let separator = normalized.range(of: "\n\n") else {
            return (normalized, nil)
        }
        let headers = String(normalized[normalized.startIndex ..< separator.lowerBound])
        let body = String(normalized[separator.upperBound...])
        return (headers, body.isEmpty ? nil : body)
    }

    /// Parses a header block into ordered fields, unfolding continuations.
    ///
    /// A line that is not a continuation and has no colon is not a header. It
    /// is skipped rather than guessed at: the usual cause is an mbox `From `
    /// line or a preamble, and inventing a field name for it would put a
    /// fictional header in the result.
    static func parse(_ rawHeaders: String) -> [MailHeaderField] {
        var fields: [MailHeaderField] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                fields.append(
                    MailHeaderField(
                        name: name,
                        value: currentValue.trimmingCharacters(in: .whitespaces)
                    )
                )
            }
            currentName = nil
            currentValue = ""
        }

        for line in normalizeLineEndings(rawHeaders).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            if line.isEmpty {
                // The header block ends here; anything after it is a body.
                break
            }
            if let first = line.first, first == " " || first == "\t" {
                // A folded continuation. RFC 5322 §2.2.3: the fold and its
                // whitespace mean a single space.
                guard currentName != nil else { continue }
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            flush()
            currentName = String(line[line.startIndex ..< colon])
                .trimmingCharacters(in: .whitespaces)
            currentValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        flush()
        return fields.filter { !$0.name.isEmpty }
    }

    /// The first value for a header name, matched case-insensitively.
    static func first(_ name: String, in fields: [MailHeaderField]) -> String? {
        let wanted = name.lowercased()
        return fields.first { $0.name.lowercased() == wanted }?.value
    }

    /// Every value for a header name, in the order they appeared.
    ///
    /// Order is the point for `Received`, where the list read top to bottom is
    /// the delivery path walked backwards from the recipient.
    static func all(_ name: String, in fields: [MailHeaderField]) -> [String] {
        let wanted = name.lowercased()
        return fields.filter { $0.name.lowercased() == wanted }.map(\.value)
    }

    /// Cuts text to a byte budget on a UTF-8 boundary, reporting the cut.
    ///
    /// `source` on a message with a photo attached is megabytes of base64, and
    /// a tool that returns all of it is a tool that blows up a context window.
    /// Cutting silently is worse than not cutting, so the omitted byte count
    /// comes back with the text.
    static func clamp(_ text: String, toBytes budget: Int) -> (text: String, omittedBytes: Int) {
        guard budget > 0 else { return ("", text.utf8.count) }
        let bytes = Array(text.utf8)
        guard bytes.count > budget else { return (text, 0) }
        var end = budget
        // Back off to the start of a UTF-8 scalar so the cut never splits one.
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let kept = String(decoding: bytes[0 ..< end], as: UTF8.self)
        return (kept, bytes.count - end)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
