// SPDX-License-Identifier: GPL-3.0-or-later
//
// The links inside a message, pulled out and told apart from their labels.
//
// Asking "what does this email actually want me to click" is a common thing to
// want and an expensive thing to do by hand: the body arrives as HTML, the
// interesting URLs are in `href` attributes, and the visible text beside them
// is frequently not the destination. Reading the whole body into a model to
// find three URLs wastes a context window; this extracts them instead.
//
// Two decisions are worth stating.
//
// The first is that an anchor whose visible text is itself a host, and a
// different host from the one it links to, is reported with
// `displayHostMismatch`. That is the shape of a phishing link and also the
// shape of a perfectly ordinary tracking redirect, so it is a flag and never
// a filter: this file marks it and lets the caller judge. Marking it costs a
// string compare and not marking it means the caller cannot see the thing
// most worth seeing.
//
// The second is that links are deduplicated by exact URL and counted, because
// a newsletter links its own homepage nine times and nine identical rows tell
// a caller nothing the count does not.
//
// Extraction is deliberately lenient about malformed HTML. This runs on mail,
// which is the worst HTML on earth, and a strict parser that gives up on a
// stray unclosed tag would return nothing exactly when it matters.

import Foundation

/// One distinct destination found in a message body.
struct MailBodyLink: Sendable, Codable, Equatable {
    /// The destination, exactly as the body carried it.
    let url: String
    /// The visible label, when the body was HTML and the anchor had one.
    let text: String?
    /// Lowercased URL scheme: `https`, `mailto`, and so on. Empty if absent.
    let scheme: String
    /// The destination host, when the URL has one.
    let host: String?
    /// How many times this exact URL appeared.
    let occurrences: Int
    /// The label looks like a host, and it is not this link's host.
    let displayHostMismatch: Bool
}

enum MailBodyLinks {
    /// Pulls every link out of a message body, HTML or plain text.
    ///
    /// `limit` caps the number of distinct links returned, keeping the ones
    /// that appeared first; the caller is told the total separately so a cap
    /// never reads as "that was all of them".
    static func extract(from body: String, limit: Int = 200) -> (
        links: [MailBodyLink], total: Int
    ) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var labels: [String: String] = [:]

        func record(url rawURL: String, text rawText: String?) {
            let url = decodeEntities(rawURL).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !url.hasPrefix("#"), !url.lowercased().hasPrefix("javascript:")
            else { return }
            if counts[url] == nil {
                order.append(url)
                counts[url] = 0
            }
            counts[url, default: 0] += 1
            if labels[url] == nil, let rawText {
                let text = decodeEntities(stripTags(rawText))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { labels[url] = text }
            }
        }

        // Anchors first, so an href's own visible label is attached to it
        // before the bare-URL sweep sees the same URL in the raw markup.
        var sawAnchor = false
        for match in regex(#"<a\b[^>]*?href\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))[^>]*>(.*?)</a\s*>"#)
            .matches(in: body, range: NSRange(body.startIndex..., in: body))
        {
            sawAnchor = true
            let href =
                capture(match, 2, in: body) ?? capture(match, 3, in: body)
                ?? capture(match, 4, in: body)
            guard let href else { continue }
            record(url: href, text: capture(match, 5, in: body))
        }

        // Then bare URLs, which is all a plain-text body has. On an HTML body
        // this also catches URLs that were written out rather than linked.
        let scanned = sawAnchor ? stripAnchors(body) : body
        for match in regex(#"\b((?:https?|mailto|ftp)://[^\s<>"')\]]+|mailto:[^\s<>"')\]]+)"#)
            .matches(in: scanned, range: NSRange(scanned.startIndex..., in: scanned))
        {
            guard var url = capture(match, 1, in: scanned) else { continue }
            // Trailing sentence punctuation is prose, not part of the URL.
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            record(url: url, text: nil)
        }

        let links = order.prefix(max(0, limit)).map { url -> MailBodyLink in
            let label = labels[url]
            let host = hostOf(url)
            return MailBodyLink(
                url: url,
                text: label,
                scheme: schemeOf(url),
                host: host,
                occurrences: counts[url] ?? 1,
                displayHostMismatch: mismatch(label: label, host: host)
            )
        }
        return (Array(links), order.count)
    }

    /// True when the label reads as a host and names a different one.
    ///
    /// A label that is not host-shaped ("Click here", "Read the report") says
    /// nothing about the destination and is never a mismatch. `www.` is
    /// ignored on both sides because nobody means it as a distinction.
    static func mismatch(label: String?, host: String?) -> Bool {
        guard let host, let label else { return false }
        let candidate = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip a scheme and any path, so a label that is a whole URL still
        // compares as the host it points at.
        var bare = candidate
        if let schemeEnd = bare.range(of: "://") { bare = String(bare[schemeEnd.upperBound...]) }
        if let slash = bare.firstIndex(of: "/") { bare = String(bare[bare.startIndex ..< slash]) }
        guard bare.contains("."), !bare.contains(" ") else { return false }
        // A label with a dot but no plausible TLD is prose, not a host.
        guard let tld = bare.split(separator: ".").last, tld.count >= 2,
            tld.allSatisfy({ $0.isLetter })
        else { return false }
        return normalizeHost(bare) != normalizeHost(host.lowercased())
    }

    private static func normalizeHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func schemeOf(_ url: String) -> String {
        guard let colon = url.firstIndex(of: ":") else { return "" }
        let scheme = url[url.startIndex ..< colon].lowercased()
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
            ? scheme : ""
    }

    private static func hostOf(_ url: String) -> String? {
        if url.lowercased().hasPrefix("mailto:") {
            let address = url.dropFirst("mailto:".count)
            guard let at = address.firstIndex(of: "@") else { return nil }
            return String(address[address.index(after: at)...])
                .split(separator: "?").first.map(String.init)?.lowercased()
        }
        guard let components = URLComponents(string: url), let host = components.host,
            !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Removes whole anchor elements, label and all.
    ///
    /// The anchor sweep has already recorded these, and an anchor whose label
    /// is written out as a URL would otherwise be counted a second time by the
    /// bare-URL sweep as though the message linked it twice.
    private static func stripAnchors(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: #"<a\b[^>]*>.*?</a\s*>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        // An unclosed anchor leaves its opening tag behind; drop the bare tags
        // so an href is never re-read out of raw markup as a bare URL.
        return stripped.replacingOccurrences(
            of: #"<a\b[^>]*>|</a\s*>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// The handful of entities that actually turn up inside mail hrefs.
    ///
    /// A full entity table is not worth carrying: `&amp;` between query
    /// parameters is the one that matters and the rest are label cosmetics.
    private static func decodeEntities(_ text: String) -> String {
        var output = text
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ] {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Every pattern here is a literal in this file, so a compile failure
        // is a programming error and not a runtime condition.
        // swift-format-ignore
        return try! NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        _ index: Int,
        in source: String
    ) -> String? {
        guard index < match.numberOfRanges,
            let range = Range(match.range(at: index), in: source)
        else { return nil }
        return String(source[range])
    }
}
