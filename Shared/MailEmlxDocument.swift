// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parsing for the files Apple Mail keeps on disk.
//
// Mail stores every downloaded message as an `.emlx` file: a decimal byte
// count, a newline, that many bytes of RFC 5322 message, then an XML property
// list holding Mail's own flags. A message whose body has not been fetched
// yet is written as `.partial.emlx` with the same envelope but a truncated or
// stubbed body.
//
// Everything here is a pure function over bytes, so the whole format can be
// exercised against fixtures rather than against somebody's real mail. The
// header work is deliberately handed to MailThreadResolver: Message-ID,
// In-Reply-To and References already have one parser in this codebase, and a
// second one would drift.
//
// Two honesty rules run through the file. A body that cannot be decoded is
// reported as absent with a reason rather than as empty text, and a partial
// file is never described as a complete message.

import Foundation

/// The Mail-specific state that lives in the trailing property list rather
/// than in the message headers.
///
/// The flag word is Mail's own and undocumented. The low bits below have been
/// stable for many releases, but a value this code does not recognise is
/// ignored rather than guessed at.
struct MailEmlxFlags: Sendable, Equatable {
    var isRead = false
    var isFlagged = false
    var isAnswered = false
    var isDraft = false
    var attachmentCount = 0

    init() {}

    init(rawValue: Int) {
        isRead = rawValue & 0b1 != 0
        isAnswered = rawValue & 0b100 != 0
        isFlagged = rawValue & 0b1_0000 != 0
        isDraft = rawValue & 0b100_0000 != 0
        attachmentCount = (rawValue >> 10) & 0b11_1111
    }
}

/// One message as Mail wrote it to disk.
struct MailEmlxDocument: Sendable, Equatable {
    let messageID: String?
    let references: [String]
    let subject: String
    let sender: String
    let recipients: [String]
    let dateSent: Date?
    /// The unfolded header block, kept so thread resolution can run off the
    /// index without a second read of the file.
    let rawHeaders: String
    /// Plain text for indexing. Empty when `bodyUnavailableReason` is set.
    let bodyText: String
    /// False for a `.partial.emlx` file, and for a body this parser could not
    /// decode. Callers report it rather than quietly treating the text as the
    /// whole message.
    let bodyIsComplete: Bool
    let bodyUnavailableReason: String?
    let isPartial: Bool
    let flags: MailEmlxFlags
}

enum MailEmlxParseError: LocalizedError, Equatable {
    case empty
    case noHeaders

    var errorDescription: String? {
        switch self {
        case .empty: return "the message file is empty"
        case .noHeaders: return "the message file carries no RFC 5322 header block"
        }
    }
}

enum MailEmlxParser {
    /// Bodies past this length are truncated before indexing. A single mail
    /// can carry megabytes of quoted history, and storing all of it would
    /// make the index rival the mailbox it describes.
    static let maximumIndexedBodyBytes = 64 * 1024

    /// Parses one `.emlx` payload.
    ///
    /// `isPartial` comes from the filename rather than the contents, because a
    /// `.partial.emlx` file is well formed and says nothing about itself.
    static func parse(data: Data, isPartial: Bool = false) throws -> MailEmlxDocument {
        guard !data.isEmpty else { throw MailEmlxParseError.empty }
        let (messageData, plistData) = split(data)

        let message = decodeText(messageData)
        guard let separator = headerBodySeparator(in: message) else {
            throw MailEmlxParseError.noHeaders
        }
        let rawHeaders = String(message[message.startIndex ..< separator.lowerBound])
        let rawBody = String(message[separator.upperBound...])

        let headers = MailThreadResolver.unfoldedHeaders(rawHeaders)
        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var flags = MailEmlxFlags()
        if let plistData,
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any],
            let raw = plist["flags"] as? Int
        {
            flags = MailEmlxFlags(rawValue: raw)
        }

        let body = plainText(body: rawBody, headers: headers)
        // A partial file's decoded text is real as far as it goes, but it is
        // not the message, so it is reported as incomplete either way.
        let complete = !isPartial && body.reason == nil

        return MailEmlxDocument(
            messageID: MailThreadResolver.messageIdentifier(inHeaders: rawHeaders),
            references: MailThreadResolver.referencedIdentifiers(inHeaders: rawHeaders),
            subject: decodedHeaderText(value("Subject") ?? ""),
            sender: decodedHeaderText(value("From") ?? ""),
            recipients: [value("To"), value("Cc")]
                .compactMap { $0 }
                .map(decodedHeaderText)
                .filter { !$0.isEmpty },
            dateSent: value("Date").flatMap(date(fromRFC5322:)),
            rawHeaders: rawHeaders,
            bodyText: body.text,
            bodyIsComplete: complete,
            bodyUnavailableReason: isPartial
                ? (body.reason
                    ?? "the message body has not been downloaded from the server yet")
                : body.reason,
            isPartial: isPartial,
            flags: flags
        )
    }

    // MARK: - File envelope

    /// Splits the leading byte count from the message and the trailing plist.
    ///
    /// A file whose first line is not a byte count is still read as a plain
    /// RFC 5322 message, because that is what a caller handing over a `.eml`
    /// fixture means and refusing it buys nothing.
    static func split(_ data: Data) -> (message: Data, plist: Data?) {
        guard let newline = data.firstIndex(of: 0x0A) else { return (data, nil) }
        let prefix = data[data.startIndex ..< newline]
        let digits = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let count = Int(digits) else {
            return (data, nil)
        }
        let bodyStart = data.index(after: newline)
        // Mail's count has been seen to run past the end of a truncated file,
        // so it narrows the range rather than defining it.
        let bodyEnd =
            data.index(bodyStart, offsetBy: count, limitedBy: data.endIndex)
            ?? data.endIndex
        let trailing = data[bodyEnd...]
        return (data[bodyStart ..< bodyEnd], trailing.isEmpty ? nil : Data(trailing))
    }

    /// Decodes bytes as UTF-8, falling back to Latin-1, which cannot fail.
    static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func headerBodySeparator(in message: String) -> Range<String.Index>? {
        if let range = message.range(of: "\r\n\r\n") { return range }
        if let range = message.range(of: "\n\n") { return range }
        // A header-only file is legal; the body is simply empty.
        return message.isEmpty ? nil : message.endIndex ..< message.endIndex
    }

    // MARK: - Header text

    /// Decodes RFC 2047 encoded words so a subject arrives as text rather
    /// than as `=?UTF-8?B?...?=`.
    static func decodedHeaderText(_ value: String) -> String {
        guard value.contains("=?") else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var output = ""
        var rest = Substring(value)
        // RFC 2047 §6.2: whitespace separating two encoded words is an
        // artifact of folding and is not part of the decoded text.
        var previousWasEncodedWord = false
        while let start = rest.range(of: "=?") {
            let gap = rest[rest.startIndex ..< start.lowerBound]
            if !(previousWasEncodedWord && gap.allSatisfy(\.isWhitespace)) {
                output += gap
            }
            let afterStart = rest[start.upperBound...]
            guard let end = afterStart.range(of: "?=") else {
                output += rest[start.lowerBound...]
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let token = afterStart[afterStart.startIndex ..< end.lowerBound]
            let parts = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3,
                let decoded = decodeEncodedWord(
                    charset: String(parts[0]),
                    encoding: String(parts[1]),
                    text: String(parts[2])
                )
            {
                output += decoded
                previousWasEncodedWord = true
            } else {
                output += "=?" + token + "?="
                previousWasEncodedWord = false
            }
            rest = afterStart[end.upperBound...]
        }
        output += rest
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEncodedWord(
        charset: String,
        encoding: String,
        text: String
    ) -> String? {
        let bytes: Data?
        switch encoding.uppercased() {
        case "B": bytes = Data(base64Encoded: text)
        case "Q": bytes = quotedPrintable(text.replacingOccurrences(of: "_", with: " "))
        default: return nil
        }
        guard let bytes else { return nil }
        let encoding = textEncoding(named: charset)
        return String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func textEncoding(named charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cf != kCFStringEncodingInvalidId else { return .utf8 }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    // MARK: - Dates

    private static let rfc5322Formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
    ]

    static func date(fromRFC5322 value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in rfc5322Formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - Bodies

    /// The first `text/plain` part, decoded, or a reason it is unavailable.
    ///
    /// This is not a general MIME reader. It walks `multipart/*` one level at
    /// a time looking for plain text and gives up cleanly on anything else,
    /// which keeps a format surprise out of the index instead of putting
    /// base64 noise into it.
    static func plainText(
        body: String,
        headers: [(name: String, value: String)]
    ) -> (text: String, reason: String?) {
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        return plainText(
            body: body,
            contentType: header("Content-Type") ?? "text/plain",
            transferEncoding: header("Content-Transfer-Encoding") ?? "7bit",
            depth: 0
        )
    }

    private static func plainText(
        body: String,
        contentType: String,
        transferEncoding: String,
        depth: Int
    ) -> (text: String, reason: String?) {
        let type =
            contentType.split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            } ?? "text/plain"

        if type.hasPrefix("multipart/") {
            guard depth < 4, let boundary = parameter("boundary", in: contentType) else {
                return ("", "the message body is a nested MIME structure this index does not read")
            }
            for part in body.components(separatedBy: "--" + boundary).dropFirst() {
                if part.hasPrefix("--") { break }
                guard let separator = part.range(of: "\n\n") ?? part.range(of: "\r\n\r\n") else {
                    continue
                }
                let partHeaders = MailThreadResolver.unfoldedHeaders(
                    String(part[part.startIndex ..< separator.lowerBound])
                )
                func partHeader(_ name: String) -> String? {
                    partHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
                        .value
                }
                let resolved = plainText(
                    body: String(part[separator.upperBound...]),
                    contentType: partHeader("Content-Type") ?? "text/plain",
                    transferEncoding: partHeader("Content-Transfer-Encoding") ?? "7bit",
                    depth: depth + 1
                )
                if !resolved.text.isEmpty { return resolved }
            }
            return ("", "the message body carries no plain-text part")
        }

        guard type.hasPrefix("text/") else {
            return ("", "the message body is \(type), which this index does not extract text from")
        }

        let charset = parameter("charset", in: contentType) ?? "utf-8"
        let decoded: String
        switch transferEncoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            let joined = body.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: joined) else {
                return ("", "the message body is base64 this index could not decode")
            }
            decoded =
                String(data: data, encoding: textEncoding(named: charset))
                ?? String(decoding: data, as: UTF8.self)
        case "quoted-printable":
            guard let data = quotedPrintable(body) else {
                return ("", "the message body is quoted-printable this index could not decode")
            }
            decoded =
                String(data: data, encoding: textEncoding(named: charset))
                ?? String(decoding: data, as: UTF8.self)
        default:
            decoded = body
        }

        if type == "text/html" {
            return (strippingTags(decoded).truncatedForIndexing(), nil)
        }
        return (decoded.truncatedForIndexing(), nil)
    }

    static func parameter(_ name: String, in contentType: String) -> String? {
        for piece in contentType.split(separator: ";").dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex ..< equals]).lowercased()
            guard key == name.lowercased() else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func quotedPrintable(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        var characters = Array(text.unicodeScalars)
        var index = 0
        while index < characters.count {
            let scalar = characters[index]
            if scalar == "=" {
                if index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 2
                    continue
                }
                if index + 2 < characters.count, characters[index + 1] == "\r",
                    characters[index + 2] == "\n"
                {
                    index += 3
                    continue
                }
                guard index + 2 < characters.count,
                    let value = UInt8(
                        String(String.UnicodeScalarView(characters[index + 1 ... index + 2])),
                        radix: 16
                    )
                else { return nil }
                bytes.append(value)
                index += 3
                continue
            }
            guard scalar.value < 0x100 else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                index += 1
                continue
            }
            bytes.append(UInt8(scalar.value))
            index += 1
        }
        characters = []
        return Data(bytes)
    }

    /// Enough HTML flattening to make a message searchable. It is not a
    /// renderer, and the index says so nowhere because the stored text is
    /// only ever used for matching, never shown as the message.
    static func strippingTags(_ html: String) -> String {
        var output = ""
        var depth = 0
        for character in html {
            if character == "<" {
                depth += 1
                continue
            }
            if character == ">" {
                depth = max(0, depth - 1)
                if depth == 0 { output.append(" ") }
                continue
            }
            if depth == 0 { output.append(character) }
        }
        return output.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    fileprivate func truncatedForIndexing() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > MailEmlxParser.maximumIndexedBodyBytes else { return trimmed }
        return String(
            decoding: Array(trimmed.utf8.prefix(MailEmlxParser.maximumIndexedBodyBytes)),
            as: UTF8.self
        )
    }
}
