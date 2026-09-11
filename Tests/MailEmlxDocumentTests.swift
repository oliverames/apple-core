import Foundation
import Testing

/// Exercises the `.emlx` reader against fixtures built to Mail's own file
/// shape, so the format is verified without opening anybody's mail.
@Suite("Mail emlx document")
struct MailEmlxDocumentTests {
    /// Mail's envelope: a decimal byte count, a newline, the RFC 5322
    /// message, then an XML property list of Mail's own flags.
    static func emlx(message: String, flags: Int? = nil) -> Data {
        var data = Data()
        let body = Data(message.utf8)
        data.append(Data("\(body.count)\n".utf8))
        data.append(body)
        if let flags {
            data.append(
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    <plist version="1.0"><dict><key>flags</key>\
                    <integer>\(flags)</integer></dict></plist>
                    """.utf8
                )
            )
        }
        return data
    }

    @Test("The byte count, message and trailing plist are separated")
    func envelopeSplit() throws {
        let data = Self.emlx(
            message: "Subject: Hello\nMessage-ID: <a@example.com>\n\nBody text\n",
            flags: 1
        )
        let document = try MailEmlxParser.parse(data: data)
        #expect(document.subject == "Hello")
        #expect(document.messageID == "a@example.com")
        #expect(document.bodyText == "Body text")
        #expect(document.flags.isRead)
        #expect(document.bodyIsComplete)
    }

    @Test("Mail's flag word decodes read, flagged and attachment count")
    func flagWord() {
        // Bit 0 read, bit 4 flagged, attachment count in bits 10 and up.
        let flags = MailEmlxFlags(rawValue: 1 | 0b1_0000 | (2 << 10))
        #expect(flags.isRead)
        #expect(flags.isFlagged)
        #expect(flags.attachmentCount == 2)
        #expect(!flags.isDraft)
    }

    @Test("An RFC 2047 encoded subject arrives as text")
    func encodedSubject() throws {
        let data = Self.emlx(
            message: """
                Subject: =?UTF-8?B?SW52b2ljZSDihpI=?= =?UTF-8?Q?_March?=
                Message-ID: <b@example.com>

                x
                """
        )
        let document = try MailEmlxParser.parse(data: data)
        #expect(document.subject == "Invoice → March")
    }

    @Test("A quoted-printable body decodes, and a folded References header survives")
    func quotedPrintableBody() throws {
        let data = Self.emlx(
            message: """
                Subject: Re: Quote
                Message-ID: <c@example.com>
                References: <a@example.com>
                \t<b@example.com>
                Content-Type: text/plain; charset="utf-8"
                Content-Transfer-Encoding: quoted-printable

                Caf=C3=A9 =
                bill
                """
        )
        let document = try MailEmlxParser.parse(data: data)
        #expect(document.bodyText == "Café bill")
        #expect(document.references == ["a@example.com", "b@example.com"])
    }

    @Test("A multipart message indexes its plain-text part, not its HTML")
    func multipartPrefersPlainText() throws {
        let data = Self.emlx(
            message: """
                Subject: Newsletter
                Message-ID: <d@example.com>
                Content-Type: multipart/alternative; boundary="edge"

                --edge
                Content-Type: text/plain; charset=utf-8

                The plain words
                --edge
                Content-Type: text/html; charset=utf-8

                <html><body>The marked up words</body></html>
                --edge--
                """
        )
        let document = try MailEmlxParser.parse(data: data)
        #expect(document.bodyText == "The plain words")
        #expect(document.bodyUnavailableReason == nil)
    }

    @Test("A body this reader cannot extract is reported as absent, not as empty")
    func undecodableBodyHasAReason() throws {
        let data = Self.emlx(
            message: """
                Subject: Scan
                Message-ID: <e@example.com>
                Content-Type: application/pdf

                %PDF-1.4 binary
                """
        )
        let document = try MailEmlxParser.parse(data: data)
        #expect(document.bodyText.isEmpty)
        #expect(document.bodyIsComplete == false)
        #expect(document.bodyUnavailableReason?.contains("application/pdf") == true)
    }

    @Test("A partial file is never described as a complete message")
    func partialFileIsNeverComplete() throws {
        let data = Self.emlx(
            message: """
                Subject: Big attachment
                Message-ID: <f@example.com>
                Content-Type: text/plain

                The first paragraph only
                """
        )
        let document = try MailEmlxParser.parse(data: data, isPartial: true)
        #expect(document.isPartial)
        #expect(!document.bodyIsComplete)
        #expect(document.bodyUnavailableReason?.contains("downloaded") == true)
        // The text that is there is still indexed; it is simply not the whole
        // message, and the reason says so.
        #expect(document.bodyText == "The first paragraph only")
    }

    @Test("An RFC 5322 date parses, and a missing one is absent rather than now")
    func dateParsing() throws {
        let withDate = try MailEmlxParser.parse(
            data: Self.emlx(
                message: """
                    Subject: Old
                    Date: Tue, 3 Feb 2009 09:15:00 +0000
                    Message-ID: <g@example.com>

                    x
                    """
            )
        )
        #expect(
            withDate.dateSent == Date(timeIntervalSince1970: 1_233_652_500)
        )
        let withoutDate = try MailEmlxParser.parse(
            data: Self.emlx(message: "Subject: No date\n\nx")
        )
        #expect(withoutDate.dateSent == nil)
    }

    @Test("An empty file is an error rather than an empty message")
    func emptyFile() {
        #expect(throws: MailEmlxParseError.empty) {
            try MailEmlxParser.parse(data: Data())
        }
    }
}
