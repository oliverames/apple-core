// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@Suite("Mail header block parsing")
struct MailHeaderBlockTests {
    /// A header block with the three shapes that break naive parsers: a
    /// folded value, a repeated field, and CRLF line endings.
    private let sample = [
        "Received: from relay-b.example.net (relay-b.example.net [203.0.113.9])",
        "\tby inbound.example.com with ESMTPS id abc123",
        "\tfor <oliver@example.com>; Tue, 9 Sep 2026 08:15:02 -0400",
        "Received: from sender.example.org (sender.example.org [198.51.100.4])",
        "\tby relay-b.example.net with SMTP id def456",
        "From: Notifications <no-reply@example.org>",
        "Subject: Your weekly digest",
        "Authentication-Results: inbound.example.com; spf=pass; dkim=pass",
        "Message-ID: <digest-2026-09-09@example.org>",
    ].joined(separator: "\r\n")

    @Test("Folded continuations rejoin as a single space")
    func unfolding() {
        let fields = MailHeaderBlock.parse(sample)
        let first = MailHeaderBlock.first("received", in: fields)
        #expect(first?.contains("by inbound.example.com with ESMTPS id abc123") == true)
        #expect(first?.contains("\t") == false)
        #expect(first?.contains("\n") == false)
        #expect(first?.contains("id abc123 for <oliver@example.com>") == true)
    }

    @Test("Repeated headers keep their order, because Received is a path")
    func repeatedHeadersOrdered() {
        let fields = MailHeaderBlock.parse(sample)
        let hops = MailHeaderBlock.all("Received", in: fields)
        #expect(hops.count == 2)
        #expect(hops[0].contains("inbound.example.com"))
        #expect(hops[1].contains("relay-b.example.net with SMTP"))
    }

    @Test("Lookup ignores case")
    func caseInsensitiveLookup() {
        let fields = MailHeaderBlock.parse(sample)
        #expect(MailHeaderBlock.first("MESSAGE-ID", in: fields) == "<digest-2026-09-09@example.org>")
        #expect(MailHeaderBlock.first("subject", in: fields) == "Your weekly digest")
        #expect(MailHeaderBlock.first("x-absent", in: fields) == nil)
    }

    @Test("The body is split off at the first empty line and never parsed")
    func bodySplit() {
        let message = "Subject: Hi\r\nFrom: a@example.com\r\n\r\nNot: a header\r\nJust prose.\r\n"
        let split = MailHeaderBlock.split(rawMessage: message)
        #expect(split.body?.hasPrefix("Not: a header") == true)
        let fields = MailHeaderBlock.parse(split.headers)
        #expect(fields.count == 2)
        #expect(MailHeaderBlock.first("Not", in: fields) == nil)
    }

    @Test("A block with no empty line is all headers")
    func noBody() {
        let split = MailHeaderBlock.split(rawMessage: "Subject: Only headers\nFrom: a@b.test")
        #expect(split.body == nil)
        #expect(MailHeaderBlock.parse(split.headers).count == 2)
    }

    @Test("A line with no colon is skipped, not invented into a field")
    func nonHeaderLineSkipped() {
        let fields = MailHeaderBlock.parse("From oliver@example.com Tue Sep 9\nSubject: Real\n")
        #expect(fields.count == 1)
        #expect(fields[0].name == "Subject")
    }

    @Test("An empty value is kept, because an empty header is still present")
    func emptyValue() {
        let fields = MailHeaderBlock.parse("X-Spam-Flag:\nSubject: Hi")
        #expect(fields.first?.name == "X-Spam-Flag")
        #expect(fields.first?.value == "")
    }

    @Test("Clamping reports what it cut and never splits a scalar")
    func clamping() {
        let text = "aaaa"
        #expect(MailHeaderBlock.clamp(text, toBytes: 100).text == text)
        #expect(MailHeaderBlock.clamp(text, toBytes: 100).omittedBytes == 0)

        let clamped = MailHeaderBlock.clamp(text, toBytes: 2)
        #expect(clamped.text == "aa")
        #expect(clamped.omittedBytes == 2)

        // "é" is two UTF-8 bytes; a one-byte budget must not return half of it.
        let accented = MailHeaderBlock.clamp("é", toBytes: 1)
        #expect(accented.text == "")
        #expect(accented.omittedBytes == 2)
        #expect(MailHeaderBlock.clamp("é", toBytes: 2).text == "é")
    }

    @Test("A zero budget keeps nothing and says so")
    func zeroBudget() {
        let clamped = MailHeaderBlock.clamp("hello", toBytes: 0)
        #expect(clamped.text == "")
        #expect(clamped.omittedBytes == 5)
    }
}
