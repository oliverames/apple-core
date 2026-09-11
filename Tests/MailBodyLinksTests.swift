// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@Suite("Mail body link extraction")
struct MailBodyLinksTests {
    @Test("An anchor yields its href and its visible label")
    func anchorWithLabel() {
        let result = MailBodyLinks.extract(
            from: #"<p>See <a href="https://example.com/report">the report</a>.</p>"#
        )
        #expect(result.links.count == 1)
        #expect(result.links[0].url == "https://example.com/report")
        #expect(result.links[0].text == "the report")
        #expect(result.links[0].scheme == "https")
        #expect(result.links[0].host == "example.com")
        #expect(result.links[0].displayHostMismatch == false)
    }

    @Test("Single-quoted and unquoted hrefs are read too")
    func hrefQuotingVariants() {
        let result = MailBodyLinks.extract(
            from: "<a href='https://a.test/x'>A</a><a href=https://b.test/y >B</a>"
        )
        #expect(result.links.map(\.url) == ["https://a.test/x", "https://b.test/y"])
    }

    @Test("Entities in an href are decoded so query parameters survive")
    func entityDecoding() {
        let result = MailBodyLinks.extract(
            from: #"<a href="https://example.com/p?a=1&amp;b=2">go</a>"#
        )
        #expect(result.links[0].url == "https://example.com/p?a=1&b=2")
    }

    @Test("Identical URLs merge and are counted once")
    func deduplication() {
        let html = """
            <a href="https://news.test/home">Home</a>
            <a href="https://news.test/home">Home again</a>
            <a href="https://news.test/story">Story</a>
            """
        let result = MailBodyLinks.extract(from: html)
        #expect(result.links.count == 2)
        #expect(result.total == 2)
        let home = result.links.first { $0.url == "https://news.test/home" }
        #expect(home?.occurrences == 2)
        // The first label seen wins, rather than the last overwriting it.
        #expect(home?.text == "Home")
    }

    @Test("A label naming a different host is flagged, not filtered")
    func displayMismatchFlagged() {
        let result = MailBodyLinks.extract(
            from: #"<a href="https://tracking.evil.test/r?x=1">secure.yourbank.com</a>"#
        )
        #expect(result.links.count == 1)
        #expect(result.links[0].displayHostMismatch == true)
        // Still returned: this is a signal for the caller, never a decision.
        #expect(result.links[0].url == "https://tracking.evil.test/r?x=1")
    }

    @Test("A matching label is not a mismatch, www and scheme aside")
    func matchingLabelsAreNotMismatches() {
        #expect(MailBodyLinks.mismatch(label: "example.com", host: "www.example.com") == false)
        #expect(MailBodyLinks.mismatch(label: "www.example.com", host: "example.com") == false)
        #expect(MailBodyLinks.mismatch(label: "https://example.com/a", host: "example.com") == false)
        #expect(MailBodyLinks.mismatch(label: "EXAMPLE.com", host: "example.com") == false)
    }

    @Test("Prose labels say nothing about the destination")
    func proseLabelsAreNeverMismatches() {
        // No dot, so not host-shaped.
        #expect(MailBodyLinks.mismatch(label: "Click here", host: "evil.test") == false)
        // A dot, but it is a sentence.
        #expect(MailBodyLinks.mismatch(label: "Read it. Now", host: "evil.test") == false)
        // A dot with no plausible TLD.
        #expect(MailBodyLinks.mismatch(label: "version 2.0", host: "evil.test") == false)
        #expect(MailBodyLinks.mismatch(label: nil, host: "evil.test") == false)
    }

    @Test("Plain-text bodies give up their bare URLs")
    func plainTextBody() {
        let result = MailBodyLinks.extract(
            from: "Details at https://example.com/a, or mail help@example.com.\nEnd."
        )
        #expect(result.links.contains { $0.url == "https://example.com/a" })
        // Trailing sentence punctuation is prose, not URL.
        #expect(result.links.allSatisfy { !$0.url.hasSuffix(",") && !$0.url.hasSuffix(".") })
    }

    @Test("mailto links carry their scheme and their host")
    func mailtoLinks() {
        let result = MailBodyLinks.extract(from: #"<a href="mailto:sam@example.org">Sam</a>"#)
        #expect(result.links[0].scheme == "mailto")
        #expect(result.links[0].host == "example.org")
    }

    @Test("Anchors are not double-counted by the bare-URL sweep")
    func anchorsNotDoubleCounted() {
        let result = MailBodyLinks.extract(
            from: #"<a href="https://example.com/x">https://example.com/x</a>"#
        )
        #expect(result.links.count == 1)
        #expect(result.links[0].occurrences == 1)
    }

    @Test("Anchors, fragments and javascript hrefs are excluded")
    func unusableHrefsDropped() {
        let result = MailBodyLinks.extract(
            from: ##"<a href="#top">Top</a><a href="javascript:void(0)">X</a>"##
        )
        #expect(result.links.isEmpty)
    }

    @Test("A limit caps the rows but not the reported total")
    func limitReportsTheTruth() {
        let html = (1 ... 5).map { #"<a href="https://example.com/\#($0)">L</a>"# }.joined()
        let result = MailBodyLinks.extract(from: html, limit: 2)
        #expect(result.links.count == 2)
        #expect(result.total == 5)
        #expect(result.links[0].url == "https://example.com/1")
    }

    @Test("Malformed markup still yields the links it contains")
    func malformedHTML() {
        let result = MailBodyLinks.extract(
            from: #"<div><a href="https://example.com/ok">ok</a><p>unclosed<a href="https://example.com/two">two</a>"#
        )
        #expect(result.links.count == 2)
    }

    @Test("A body with no links returns nothing rather than failing")
    func emptyBody() {
        let result = MailBodyLinks.extract(from: "<p>No links at all.</p>")
        #expect(result.links.isEmpty)
        #expect(result.total == 0)
    }
}
