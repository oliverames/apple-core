// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure directory logic for Contacts: stable paging, ranked duplicate
// suggestions, and ranked recipient resolution.
//
// None of this touches CNContactStore. The service layer converts live
// contacts into `ContactRecord` values and hands them here, which is what
// makes the ranking testable and what keeps the risky parts, name and number
// comparison, away from anything that can write to the address book.
//
// Two rules shape the whole file. Duplicate suggestions never merge and never
// offer to: merging contacts is irreversible from a tool call. Recipient
// resolution never reports confidence it has not earned, because a weak name
// match that reads as certain is how a message reaches the wrong person.

import Foundation

// MARK: - Records

/// One contact as the directory sees it. `linkedIdentifiers` carries the
/// underlying records a unified contact was assembled from, so two entries
/// that macOS already links are never proposed as duplicates of each other.
public struct ContactRecord: Sendable, Equatable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let nickname: String
    public let organizationName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]
    public let linkedIdentifiers: [String]

    public init(
        identifier: String,
        givenName: String = "",
        familyName: String = "",
        nickname: String = "",
        organizationName: String = "",
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        linkedIdentifiers: [String] = []
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organizationName = organizationName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.linkedIdentifiers = linkedIdentifiers
    }

    public var displayName: String {
        let personal = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !personal.isEmpty { return personal }
        if !nickname.isEmpty { return nickname }
        return organizationName
    }
}

// MARK: - Normalization

public enum ContactNormalization {
    /// Case- and diacritic-insensitive, punctuation stripped, whitespace
    /// collapsed. "Renée O'Neill" and "renee oneill" compare equal.
    public static func name(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        // Apostrophes close up rather than split, so "O'Neill" and "ONeill"
        // are the same name. Every other separator becomes a space.
        let withoutApostrophes = folded.filter { $0 != "'" && $0 != "\u{2019}" }
        let cleaned = withoutApostrophes.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func nameTokens(_ raw: String) -> [String] {
        name(raw).split(separator: " ").map(String.init)
    }

    /// A phone number in a comparable form. Numbers are only ever widened, not
    /// truncated: matching on a suffix would make two different international
    /// numbers that end alike look like the same person.
    public static func phone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return "+" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        return digits
    }

    public static func email(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else { return nil }
        return trimmed
    }

    /// Local parts that belong to a household or a desk rather than a person.
    /// A match on one of these is not evidence that two records are the same
    /// human being, which is the classic duplicate-detection false positive.
    static let sharedLocalParts: Set<String> = [
        "admin", "contact", "family", "hello", "home", "house", "household",
        "info", "mail", "office", "sales", "support", "team", "us",
    ]

    public static func isSharedAddress(_ email: String) -> Bool {
        guard let normalized = self.email(email) else { return false }
        let local = normalized.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let base = local.split(separator: "+", maxSplits: 1).first.map(String.init) ?? local
        return sharedLocalParts.contains(base)
    }
}

// MARK: - Paging

public struct ContactPage: Sendable, Equatable {
    public let records: [ContactRecord]
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let hasMore: Bool
    public let nextOffset: Int?
}

public enum ContactDirectory {
    public static let defaultLimit = 50
    public static let maximumLimit = 500

    public static func clampedLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultLimit, 1), maximumLimit)
    }

    public static func clampedOffset(_ requested: Int?) -> Int {
        max(requested ?? 0, 0)
    }

    /// Family name, then given name, then organization, with the identifier
    /// breaking every remaining tie. CNContactStore returns contacts in no
    /// documented order, so without a total order page 2 could repeat or skip
    /// what page 1 already showed.
    public static func sorted(_ records: [ContactRecord]) -> [ContactRecord] {
        records.sorted { left, right in
            let keys: [(String, String)] = [
                (ContactNormalization.name(left.familyName), ContactNormalization.name(right.familyName)),
                (ContactNormalization.name(left.givenName), ContactNormalization.name(right.givenName)),
                (
                    ContactNormalization.name(left.organizationName),
                    ContactNormalization.name(right.organizationName)
                ),
            ]
            for (a, b) in keys where a != b {
                // Empty sorts last: a company with no family name should not
                // lead the address book.
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                return a < b
            }
            return left.identifier < right.identifier
        }
    }

    /// Filters by a case-insensitive prefix on family, given, nickname or
    /// organization name. Used for "everyone under M" style paging.
    public static func matchesPrefix(_ record: ContactRecord, prefix: String) -> Bool {
        let needle = ContactNormalization.name(prefix)
        guard !needle.isEmpty else { return true }
        return [record.familyName, record.givenName, record.nickname, record.organizationName]
            .map(ContactNormalization.name)
            .contains { !$0.isEmpty && $0.hasPrefix(needle) }
    }

    public static func page(_ ordered: [ContactRecord], offset: Int, limit: Int) -> ContactPage {
        let total = ordered.count
        guard offset < total else {
            return ContactPage(
                records: [],
                offset: offset,
                limit: limit,
                total: total,
                hasMore: false,
                nextOffset: nil
            )
        }
        // Saturating rather than wrapping: a caller may pass Int.max.
        let end = offset > total - limit ? total : offset + limit
        return ContactPage(
            records: Array(ordered[offset ..< end]),
            offset: offset,
            limit: limit,
            total: total,
            hasMore: end < total,
            nextOffset: end < total ? end : nil
        )
    }
}

// MARK: - Duplicate suggestions

public enum DuplicateConfidence: String, Sendable {
    case high
    case medium
    case low
}

/// One pair worth a human look. There is deliberately no merge affordance:
/// the pair, its score and the reasons behind it are the whole output.
public struct DuplicateSuggestion: Sendable, Equatable {
    public let identifiers: [String]
    public let names: [String]
    public let score: Double
    public let confidence: String
    public let reasons: [String]
    public let cautions: [String]
}

/// A record with its comparable forms worked out once. Duplicate detection
/// compares every candidate pair, so normalizing inside the loop would redo
/// the same folding thousands of times on a real address book.
struct NormalizedContact {
    let record: ContactRecord
    let fullName: String
    let familyName: String
    let givenName: String
    let organization: String
    let phones: Set<String>
    let emails: Set<String>
    let links: Set<String>

    init(_ record: ContactRecord) {
        self.record = record
        fullName = ContactNormalization.name(record.displayName)
        familyName = ContactNormalization.name(record.familyName)
        givenName = ContactNormalization.name(record.givenName)
        organization = ContactNormalization.name(record.organizationName)
        phones = Set(record.phoneNumbers.compactMap(ContactNormalization.phone))
        emails = Set(record.emailAddresses.compactMap(ContactNormalization.email))
        links = Set(record.linkedIdentifiers + [record.identifier])
    }
}

public enum ContactDuplicates {
    public static let minimumScore = 0.45

    private static func confidence(for score: Double) -> DuplicateConfidence {
        if score >= 0.8 { return .high }
        if score >= 0.6 { return .medium }
        return .low
    }

    /// Ranked duplicate candidates, strongest first, with a stable tiebreak so
    /// repeated calls agree. Never merges and never proposes merging.
    ///
    /// Pairs are drawn from blocking keys, a shared surname, phone number or
    /// address, rather than from every pair in the book: comparing 5,000
    /// contacts pairwise is twelve million comparisons for the handful of
    /// pairs that could possibly score.
    public static func suggestions(
        for records: [ContactRecord],
        minimumScore: Double = minimumScore
    ) -> [DuplicateSuggestion] {
        let normalized = ContactDirectory.sorted(records).map(NormalizedContact.init)
        let sharedEmails = sharedEmailAddresses(in: normalized)

        var blocks: [String: [Int]] = [:]
        for (index, contact) in normalized.enumerated() {
            var keys: Set<String> = []
            if !contact.familyName.isEmpty { keys.insert("f:" + contact.familyName) }
            if !contact.fullName.isEmpty { keys.insert("n:" + contact.fullName) }
            for phone in contact.phones { keys.insert("p:" + phone) }
            for email in contact.emails where !sharedEmails.contains(email) {
                keys.insert("e:" + email)
            }
            for key in keys { blocks[key, default: []].append(index) }
        }

        var scored: [DuplicateSuggestion] = []
        var seenPairs = Set<Int>()
        for indices in blocks.values {
            for (position, left) in indices.enumerated() {
                for right in indices[(position + 1)...] {
                    let pairKey = left * normalized.count + right
                    guard seenPairs.insert(pairKey).inserted else { continue }
                    guard
                        let suggestion = compare(
                            normalized[left],
                            normalized[right],
                            sharedEmails: sharedEmails,
                            minimumScore: minimumScore
                        )
                    else { continue }
                    scored.append(suggestion)
                }
            }
        }

        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.identifiers[0] != right.identifiers[0] { return left.identifiers[0] < right.identifiers[0] }
            return left.identifiers[1] < right.identifiers[1]
        }
    }

    /// An address on three or more records is a household or a desk, not a
    /// person, whatever its local part looks like.
    static func sharedEmailAddresses(in records: [ContactRecord]) -> Set<String> {
        sharedEmailAddresses(in: records.map(NormalizedContact.init))
    }

    static func sharedEmailAddresses(in contacts: [NormalizedContact]) -> Set<String> {
        var counts: [String: Int] = [:]
        for contact in contacts {
            for address in contact.emails {
                counts[address, default: 0] += 1
            }
        }
        var shared = Set(counts.filter { $0.value >= 3 }.keys)
        for address in counts.keys where ContactNormalization.isSharedAddress(address) {
            shared.insert(address)
        }
        return shared
    }

    private static func compare(
        _ left: NormalizedContact,
        _ right: NormalizedContact,
        sharedEmails: Set<String>,
        minimumScore: Double
    ) -> DuplicateSuggestion? {
        // Records macOS already links are one contact wearing two hats.
        guard left.links.isDisjoint(with: right.links) else { return nil }

        var score = 0.0
        var reasons: [String] = []
        var cautions: [String] = []
        var hasIdentifyingEvidence = false

        if !left.fullName.isEmpty, left.fullName == right.fullName {
            score += 0.5
            reasons.append("Same full name")
            hasIdentifyingEvidence = true
        } else if !left.familyName.isEmpty, left.familyName == right.familyName {
            if !left.givenName.isEmpty, !right.givenName.isEmpty,
                left.givenName.first == right.givenName.first
            {
                score += 0.15
                reasons.append("Same family name and same first initial")
            } else {
                score += 0.1
                reasons.append("Same family name")
                cautions.append("Different first names: these may be relatives rather than duplicates")
            }
        }

        if !left.phones.isDisjoint(with: right.phones) {
            score += 0.5
            reasons.append("Shares a phone number")
            hasIdentifyingEvidence = true
        }

        let commonEmails = left.emails.intersection(right.emails)
        if !commonEmails.subtracting(sharedEmails).isEmpty {
            score += 0.45
            reasons.append("Shares an email address")
            hasIdentifyingEvidence = true
        } else if !commonEmails.isEmpty {
            score += 0.05
            reasons.append("Shares an email address used by several contacts")
            cautions.append(
                "The shared address looks like a household or shared mailbox, which is weak evidence"
            )
        }

        if !left.organization.isEmpty, left.organization == right.organization {
            score += 0.05
            reasons.append("Same organization")
        }

        guard hasIdentifyingEvidence else { return nil }
        score = min(score, 1.0)
        guard score >= minimumScore else { return nil }

        // Identifier order, not scan order, so a pair reads the same way
        // whichever record the scan reached first.
        let ordered =
            left.record.identifier <= right.record.identifier
            ? (left.record, right.record) : (right.record, left.record)
        return DuplicateSuggestion(
            identifiers: [ordered.0.identifier, ordered.1.identifier],
            names: [ordered.0.displayName, ordered.1.displayName],
            score: (score * 100).rounded() / 100,
            confidence: confidence(for: score).rawValue,
            reasons: reasons,
            cautions: cautions
        )
    }
}

// MARK: - Recipient resolution

public enum RecipientChannel: String, Sendable, CaseIterable {
    case email
    case phone
    case any
}

public struct RecipientCandidate: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let score: Double
    public let matchType: String
    public let emailAddresses: [String]
    public let phoneNumbers: [String]
}

/// The answer to "who is Alex?". `isConfident` is false far more often than
/// it is true, by design: a caller that wants to send something must either
/// get an exact address match or ask the user.
public struct RecipientResolution: Sendable, Equatable {
    public let query: String
    public let channel: String
    public let candidates: [RecipientCandidate]
    public let isConfident: Bool
    public let isAmbiguous: Bool
    public let needsAddressChoice: Bool
    public let guidance: String
}

public enum ContactRecipients {
    public static let maximumCandidates = 10

    public static func resolve(
        query rawQuery: String,
        in records: [ContactRecord],
        channel: RecipientChannel = .any,
        limit: Int = maximumCandidates
    ) -> RecipientResolution {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return RecipientResolution(
                query: rawQuery,
                channel: channel.rawValue,
                candidates: [],
                isConfident: false,
                isAmbiguous: false,
                needsAddressChoice: false,
                guidance: "No search text was supplied, so no recipient was resolved."
            )
        }

        var scored: [RecipientCandidate] = []
        for record in ContactDirectory.sorted(records) {
            guard let (score, matchType) = match(record, query: query, channel: channel) else { continue }
            scored.append(
                RecipientCandidate(
                    identifier: record.identifier,
                    name: record.displayName,
                    score: (score * 100).rounded() / 100,
                    matchType: matchType,
                    emailAddresses: record.emailAddresses,
                    phoneNumbers: record.phoneNumbers
                )
            )
        }
        // Score descending; the sorted() order above keeps ties stable.
        let ranked = Array(
            scored.enumerated()
                .sorted { left, right in
                    left.element.score == right.element.score
                        ? left.offset < right.offset
                        : left.element.score > right.element.score
                }
                .map(\.element)
                .prefix(max(limit, 1))
        )

        guard let best = ranked.first else {
            return RecipientResolution(
                query: query,
                channel: channel.rawValue,
                candidates: [],
                isConfident: false,
                isAmbiguous: false,
                needsAddressChoice: false,
                guidance: "No contact matched \"\(query)\". Ask the user for the address directly."
            )
        }

        let runnerUp = ranked.dropFirst().first?.score ?? 0
        // Confidence needs a strong match that also stands clear of the next
        // one. A unique but weak name match stays unconfirmed on purpose.
        let isConfident = best.score >= 0.8 && (best.score - runnerUp) > 0.2
        let addresses = channel == .phone ? best.phoneNumbers : best.emailAddresses
        let needsAddressChoice = isConfident && channel != .any && addresses.count > 1

        return RecipientResolution(
            query: query,
            channel: channel.rawValue,
            candidates: ranked,
            isConfident: isConfident,
            isAmbiguous: !isConfident,
            needsAddressChoice: needsAddressChoice,
            guidance: guidanceText(
                isConfident: isConfident,
                needsAddressChoice: needsAddressChoice,
                count: ranked.count,
                best: best
            )
        )
    }

    private static func guidanceText(
        isConfident: Bool,
        needsAddressChoice: Bool,
        count: Int,
        best: RecipientCandidate
    ) -> String {
        if !isConfident {
            let lead =
                count > 1
                ? "\(count) contacts match, and none of them clearly."
                : "Only a weak match was found."
            return lead + " Show the candidates and let the user pick before sending anything."
        }
        if needsAddressChoice {
            return "\(best.name) matched exactly, but has more than one address. Ask which one to use."
        }
        return "\(best.name) matched exactly on \(best.matchType)."
    }

    private static func match(
        _ record: ContactRecord,
        query: String,
        channel: RecipientChannel
    ) -> (Double, String)? {
        if channel != .phone, let email = ContactNormalization.email(query) {
            if record.emailAddresses.compactMap(ContactNormalization.email).contains(email) {
                return (1.0, "email")
            }
        }
        if channel != .email, let phone = ContactNormalization.phone(query) {
            if record.phoneNumbers.compactMap(ContactNormalization.phone).contains(phone) {
                return (1.0, "phone")
            }
        }

        let needle = ContactNormalization.name(query)
        guard !needle.isEmpty else { return nil }
        // An address-shaped query that matched nobody must not fall through to
        // fuzzy name matching on its local part.
        if query.contains("@") { return nil }

        let haystacks = [record.displayName, record.nickname, record.organizationName]
            .map(ContactNormalization.name)
            .filter { !$0.isEmpty }
        guard !haystacks.isEmpty else { return nil }

        if haystacks.contains(needle) { return (0.8, "exact name") }

        let needleTokens = Set(ContactNormalization.nameTokens(query))
        let recordTokens = Set(
            haystacks.flatMap { $0.split(separator: " ").map(String.init) }
        )
        if !needleTokens.isEmpty, needleTokens.isSubset(of: recordTokens) {
            return (0.55, "partial name")
        }
        if recordTokens.contains(where: { token in needleTokens.contains { token.hasPrefix($0) } }) {
            return (0.4, "name prefix")
        }
        return nil
    }
}
