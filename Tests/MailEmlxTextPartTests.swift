// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// `textPart` is the half of the MIME walker that link extraction needs: it
/// returns the part's markup rather than the flattened words `plainText`
/// produces for the search index.
@Suite("Mail MIME text part extraction")
struct MailEmlxTextPartTests {
    private func headers(_ pairs: [(String, String)]) -> [(name: String, value: String)] {
        pairs.map { (name: $0.0, value: $0.1) }
    }

    @Test("A plain text/html body comes back with its markup intact")
    func htmlKeepsMarkup() {
        let part = MailEmlxParser.textPart(
            body: #"<p><a href="https://example.com/x">click</a></p>"#,
            headers: headers([("Content-Type", "text/html; charset=utf-8")])
        )
        #expect(part?.mimeType == "text/html")
        #expect(part?.text.contains("href=\"https://example.com/x\"") == true)
    }

    @Test("multipart/alternative prefers the HTML part over the plain one")
    func prefersHTMLInAlternative() {
        let body = """
            --bnd
            Content-Type: text/plain; charset=utf-8

            Click https://example.com/x
            --bnd
            Content-Type: text/html; charset=utf-8

            <a href="https://example.com/x">click</a>
            --bnd--
            """
        let part = MailEmlxParser.textPart(
            body: body,
            headers: headers([("Content-Type", "multipart/alternative; boundary=\"bnd\"")])
        )
        #expect(part?.mimeType == "text/html")
        #expect(part?.text.contains("<a href=") == true)
    }

    @Test("With no HTML part the plain one is returned instead")
    func fallsBackToPlain() {
        let body = """
            --bnd
            Content-Type: text/plain; charset=utf-8

            Just words.
            --bnd--
            """
        let part = MailEmlxParser.textPart(
            body: body,
            headers: headers([("Content-Type", "multipart/alternative; boundary=bnd")])
        )
        #expect(part?.mimeType == "text/plain")
        #expect(part?.text.contains("Just words.") == true)
    }

    @Test("quoted-printable is decoded, so a soft-wrapped URL rejoins")
    func quotedPrintableDecoded() {
        let body = """
            --bnd
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            <a href=3D"https://example.com/a=
            /b">x</a>
            --bnd--
            """
        let part = MailEmlxParser.textPart(
            body: body,
            headers: headers([("Content-Type", "multipart/mixed; boundary=bnd")])
        )
        #expect(part?.text.contains(#"href="https://example.com/a/b""#) == true)
    }

    @Test("base64 parts are decoded")
    func base64Decoded() {
        let markup = #"<a href="https://example.com/z">z</a>"#
        let encoded = Data(markup.utf8).base64EncodedString()
        let body = """
            --bnd
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: base64

            \(encoded)
            --bnd--
            """
        let part = MailEmlxParser.textPart(
            body: body,
            headers: headers([("Content-Type", "multipart/mixed; boundary=bnd")])
        )
        #expect(part?.text == markup)
    }

    @Test("A nested multipart still finds the HTML inside it")
    func nestedMultipart() {
        let body = """
            --outer
            Content-Type: multipart/alternative; boundary="inner"

            --inner
            Content-Type: text/plain

            words
            --inner
            Content-Type: text/html

            <b>words</b>
            --inner--
            --outer
            Content-Type: application/pdf; name=report.pdf

            %PDF-1.4
            --outer--
            """
        let part = MailEmlxParser.textPart(
            body: body,
            headers: headers([("Content-Type", "multipart/mixed; boundary=outer")])
        )
        #expect(part?.mimeType == "text/html")
        #expect(part?.text.contains("<b>words</b>") == true)
    }

    @Test("A message with no text part returns nil rather than empty text")
    func noTextPart() {
        let part = MailEmlxParser.textPart(
            body: "%PDF-1.4 binary",
            headers: headers([("Content-Type", "application/pdf")])
        )
        #expect(part == nil)
    }

    @Test("textPart does not truncate, unlike the indexing path")
    func noTruncation() {
        let long = String(repeating: "a", count: 300_000)
        let part = MailEmlxParser.textPart(
            body: long,
            headers: headers([("Content-Type", "text/plain")])
        )
        #expect(part?.text.count == 300_000)
    }
}
