import Foundation
import Testing

/// A coverage audit on 2026-09-11 found every MIME part being parsed as though
/// it carried no headers. Splitting on the boundary leaves each part starting
/// with a newline, and the header parser stops at the first blank line, so each
/// part fell back to text/plain and 7bit. The mail index therefore stored
/// base64 and quoted-printable bodies still encoded, and HTML unstripped, which
/// is most real mail. Body search could not match any of it.
@Suite("Mail MIME part decoding")
struct MailMimePartDecodingTests {
    private static func multipart(encoding: String, body: String, type: String = "text/plain") -> String {
        [
            "--b0undary",
            "Content-Type: \(type); charset=utf-8",
            "Content-Transfer-Encoding: \(encoding)",
            "",
            body,
            "--b0undary--",
            "",
        ].joined(separator: "\n")
    }

    private static let topHeaders: [(name: String, value: String)] = [
        (name: "Content-Type", value: "multipart/alternative; boundary=\"b0undary\"")
    ]

    @Test("A base64 part is decoded rather than indexed as its encoding")
    func base64PartDecodes() {
        let encoded = Data("Hello from the decoded part".utf8).base64EncodedString()
        let result = MailEmlxParser.plainText(
            body: Self.multipart(encoding: "base64", body: encoded),
            headers: Self.topHeaders
        )
        #expect(result.text.contains("Hello from the decoded part"))
        #expect(!result.text.contains(encoded))
        #expect(result.reason == nil)
    }

    @Test("A quoted-printable part is decoded")
    func quotedPrintablePartDecodes() {
        let result = MailEmlxParser.plainText(
            body: Self.multipart(encoding: "quoted-printable", body: "Invoice =E2=82=AC42 due"),
            headers: Self.topHeaders
        )
        #expect(result.text.contains("Invoice"))
        #expect(!result.text.contains("=E2=82=AC"))
    }

    @Test("A plain 7bit part still reads exactly as before")
    func plainPartUnchanged() {
        let result = MailEmlxParser.plainText(
            body: Self.multipart(encoding: "7bit", body: "Straightforward body text"),
            headers: Self.topHeaders
        )
        #expect(result.text.contains("Straightforward body text"))
        #expect(result.reason == nil)
    }

    @Test("Carriage returns from real mail do not defeat the header block")
    func crlfPartDecodes() {
        let encoded = Data("Windows line endings here".utf8).base64EncodedString()
        let body = Self.multipart(encoding: "base64", body: encoded)
            .replacingOccurrences(of: "\n", with: "\r\n")
        let result = MailEmlxParser.plainText(body: body, headers: Self.topHeaders)
        #expect(result.text.contains("Windows line endings here"))
    }

    @Test("A message whose only part is HTML reports why rather than indexing markup")
    func htmlOnlyPartIsExplained() {
        let result = MailEmlxParser.plainText(
            body: Self.multipart(
                encoding: "7bit",
                body: "<p>Marked up</p>",
                type: "text/html"
            ),
            headers: Self.topHeaders
        )
        // Either it extracts the text or it says why, but it never stores tags
        // as though they were body text the user wrote.
        #expect(result.text.contains("Marked up") || result.reason != nil)
        #expect(!result.text.contains("<p>"))
    }

    @Test("A single-part message is unaffected by the fix")
    func singlePartUnaffected() {
        let encoded = Data("Top level base64".utf8).base64EncodedString()
        let result = MailEmlxParser.plainText(
            body: encoded,
            headers: [
                (name: "Content-Type", value: "text/plain; charset=utf-8"),
                (name: "Content-Transfer-Encoding", value: "base64"),
            ]
        )
        #expect(result.text.contains("Top level base64"))
    }
}
