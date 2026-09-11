// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thread identity for Apple Mail, decided on headers rather than on subject
// text.
//
// `mail_get_thread` used to answer with "every message in this one mailbox
// whose subject contains the anchor's subject with Re:/Fwd: stripped". That
// is wrong in both directions at once. It pulls in unrelated messages that
// happen to share a common subject ("Invoice", "Lunch?", "Re: hello"), and it
// drops the half of the conversation that lives in Sent, because Sent is a
// different mailbox.
//
// RFC 5322 already answers the question. Every message carries a Message-ID,
// a reply carries In-Reply-To naming its parent, and References carries the
// chain back to the root. Two messages are in the same conversation when the
// identifier sets they span overlap, transitively.
//
// This file is the whole decision, as a pure function over header values, so
// it can be tested against fixtures without Mail.app running. Mail.swift is
// left with the part that only the Apple Event interface can do: finding
// candidate messages and reading their raw header blocks.
//
// Subject grouping is kept, but only as a disclosed fallback for a message
// whose headers carry no usable identifier at all, and the result says so.

import Foundation

/// One candidate message, reduced to what threading actually needs.
public struct MailThreadCandidate: Sendable, Equatable {
    public let id: Int
    public let mailbox: String
    public let accountName: String
    public let subject: String
    /// Raw `all headers` text from Mail, or any subset containing the
    /// Message-ID, In-Reply-To and References fields.
    public let rawHeaders: String

    public init(
        id: Int,
        mailbox: String,
        accountName: String,
        subject: String,
        rawHeaders: String
    ) {
        self.id = id
        self.mailbox = mailbox
        self.accountName = accountName
        self.subject = subject
        self.rawHeaders = rawHeaders
    }
}

/// How a thread was decided, which the tool result discloses to the caller.
public enum MailThreadMatching: String, Codable, Sendable, Equatable {
    /// Message-ID, In-Reply-To and References. Exact.
    case headers
    /// Normalized subject text. Approximate, and labelled as such.
    case subject
}

public struct MailThreadMembership: Sendable, Equatable {
    public let id: Int
    public let mailbox: String
    public let accountName: String
    public let messageId: String?

    public init(id: Int, mailbox: String, accountName: String, messageId: String?) {
        self.id = id
        self.mailbox = mailbox
        self.accountName = accountName
        self.messageId = messageId
    }
}

public struct MailThreadResolution: Sendable, Equatable {
    public let matching: MailThreadMatching
    /// True whenever the answer may contain unrelated messages. Always true
    /// for the subject fallback, always false for header matching.
    public let approximate: Bool
    /// One sentence a client can show or reason about, explaining which rule
    /// produced this thread and what it can get wrong.
    public let note: String
    public let subjectRoot: String
    public let members: [MailThreadMembership]

    public init(
        matching: MailThreadMatching,
        approximate: Bool,
        note: String,
        subjectRoot: String,
        members: [MailThreadMembership]
    ) {
        self.matching = matching
        self.approximate = approximate
        self.note = note
        self.subjectRoot = subjectRoot
        self.members = members
    }
}

public enum MailThreadResolver {
    // MARK: - Header parsing

    /// Splits a raw RFC 5322 header block into unfolded `(name, value)` pairs.
    ///
    /// Folding matters here: References is the header most likely to run past
    /// 78 characters, so in practice it almost always arrives wrapped across
    /// continuation lines that begin with a space or a tab. Reading it line by
    /// line loses every identifier after the first.
    public static func unfoldedHeaders(_ raw: String) -> [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                pairs.append((name: name, value: currentValue))
            }
            currentName = nil
            currentValue = ""
        }

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").components(
            separatedBy: "\n"
        ) {
            // An empty line ends the header block; anything after it is body.
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                break
            }
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") {
                guard currentName != nil else { continue }
                currentValue += " " + rawLine.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            currentName = String(rawLine[rawLine.startIndex ..< separator])
                .trimmingCharacters(in: .whitespaces)
            currentValue = String(rawLine[rawLine.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        flush()
        return pairs
    }

    /// Every `<...>` identifier in a header value, normalized.
    ///
    /// Normalization lowercases, because the domain half of a message
    /// identifier is case-insensitive and mail software rewrites case freely
    /// enough that a case-sensitive comparison loses real matches. Two
    /// distinct identifiers differing only in the case of the local part are
    /// possible in theory and absent in practice.
    public static func identifiers(in value: String) -> [String] {
        var found: [String] = []
        var current = ""
        var inside = false
        for character in value {
            if character == "<" {
                inside = true
                current = ""
                continue
            }
            if character == ">" {
                if inside {
                    let identifier = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !identifier.isEmpty, !found.contains(identifier) {
                        found.append(identifier)
                    }
                }
                inside = false
                current = ""
                continue
            }
            if inside { current.append(character) }
        }
        // A bare identifier with no angle brackets is malformed but common
        // enough in Message-ID that ignoring it loses threads.
        if found.isEmpty {
            let bare = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !bare.isEmpty, !bare.contains(" "), bare.contains("@") {
                found.append(bare)
            }
        }
        return found
    }

    /// The message's own identifier, if it declares one.
    public static func messageIdentifier(inHeaders raw: String) -> String? {
        for pair in unfoldedHeaders(raw)
        where pair.name.caseInsensitiveCompare("Message-ID") == .orderedSame {
            if let first = identifiers(in: pair.value).first { return first }
        }
        return nil
    }

    /// Every identifier this message points at: In-Reply-To plus References.
    public static func referencedIdentifiers(inHeaders raw: String) -> [String] {
        var found: [String] = []
        for pair in unfoldedHeaders(raw) {
            let isReference =
                pair.name.caseInsensitiveCompare("References") == .orderedSame
                || pair.name.caseInsensitiveCompare("In-Reply-To") == .orderedSame
            guard isReference else { continue }
            for identifier in identifiers(in: pair.value) where !found.contains(identifier) {
                found.append(identifier)
            }
        }
        return found
    }

    // MARK: - Subject normalization

    /// The subject with any run of reply and forward prefixes removed.
    ///
    /// Kept from the previous implementation, and still used for two things:
    /// narrowing the candidate set before the expensive header reads, and the
    /// disclosed fallback below.
    public static func subjectRoot(_ subject: String) -> String {
        var working = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            guard let colon = working.firstIndex(of: ":") else { break }
            let prefix = String(working[working.startIndex ..< colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            // "re", "fw", "fwd", and the "re[2]" form some clients emit.
            let stripped = prefix.replacingOccurrences(
                of: "[",
                with: ""
            ).replacingOccurrences(of: "]", with: "")
            let base = stripped.prefix(while: { !$0.isNumber })
            guard ["re", "fw", "fwd"].contains(String(base)),
                stripped.dropFirst(base.count).allSatisfy(\.isNumber)
            else { break }
            working = String(working[working.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return working
    }

    // MARK: - Resolution

    public static let headerNote =
        "Thread membership was decided on RFC 5322 Message-ID, In-Reply-To and References "
        + "headers, across every mailbox searched, so unrelated messages sharing this subject "
        + "are excluded."

    public static let subjectNote =
        "APPROXIMATE: the anchor message carries no usable Message-ID, In-Reply-To or "
        + "References header, so this thread fell back to matching the normalized subject. "
        + "Unrelated messages that share this subject may be included."

    /// Decides which candidates belong to the anchor's conversation.
    ///
    /// `candidates` is expected to already contain the anchor. Order is the
    /// caller's; it is preserved, so a caller that hands over messages sorted
    /// by date gets them back sorted by date.
    public static func resolve(
        anchorID: Int,
        candidates: [MailThreadCandidate]
    ) -> MailThreadResolution {
        guard let anchor = candidates.first(where: { $0.id == anchorID }) else {
            return MailThreadResolution(
                matching: .subject,
                approximate: true,
                note: subjectNote,
                subjectRoot: "",
                members: []
            )
        }
        let root = subjectRoot(anchor.subject)

        let anchorIdentifier = messageIdentifier(inHeaders: anchor.rawHeaders)
        let anchorReferences = referencedIdentifiers(inHeaders: anchor.rawHeaders)

        guard anchorIdentifier != nil || !anchorReferences.isEmpty else {
            let members =
                candidates
                .filter { subjectRoot($0.subject) == root }
                .map {
                    MailThreadMembership(
                        id: $0.id,
                        mailbox: $0.mailbox,
                        accountName: $0.accountName,
                        messageId: messageIdentifier(inHeaders: $0.rawHeaders)
                    )
                }
            return MailThreadResolution(
                matching: .subject,
                approximate: true,
                note: subjectNote,
                subjectRoot: root,
                members: members.isEmpty
                    ? [
                        MailThreadMembership(
                            id: anchor.id,
                            mailbox: anchor.mailbox,
                            accountName: anchor.accountName,
                            messageId: nil
                        )
                    ] : members
            )
        }

        // Parse once. Reparsing inside the closure loop below is the kind of
        // thing that turns a 40-message thread into 1,600 header parses.
        struct Parsed {
            let candidate: MailThreadCandidate
            let identifier: String?
            let references: [String]
        }
        let parsed = candidates.map {
            Parsed(
                candidate: $0,
                identifier: messageIdentifier(inHeaders: $0.rawHeaders),
                references: referencedIdentifiers(inHeaders: $0.rawHeaders)
            )
        }

        var known = Set(anchorReferences)
        if let anchorIdentifier { known.insert(anchorIdentifier) }
        var memberIDs: Set<Int> = [anchor.id]

        // Transitive closure. A reply chain split across Inbox and Sent only
        // links up once the middle message pulls its own identifier into the
        // set, so keep going until a pass adds nothing.
        var changed = true
        while changed {
            changed = false
            for entry in parsed where !memberIDs.contains(entry.candidate.id) {
                let identifierMatches = entry.identifier.map { known.contains($0) } ?? false
                let referenceMatches = entry.references.contains { known.contains($0) }
                guard identifierMatches || referenceMatches else { continue }
                memberIDs.insert(entry.candidate.id)
                if let identifier = entry.identifier { known.insert(identifier) }
                known.formUnion(entry.references)
                changed = true
            }
        }

        let members =
            parsed
            .filter { memberIDs.contains($0.candidate.id) }
            .map {
                MailThreadMembership(
                    id: $0.candidate.id,
                    mailbox: $0.candidate.mailbox,
                    accountName: $0.candidate.accountName,
                    messageId: $0.identifier
                )
            }
        return MailThreadResolution(
            matching: .headers,
            approximate: false,
            note: headerNote,
            subjectRoot: root,
            members: members
        )
    }
}
