// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// Fixtures stand in for the address book on purpose: these tests must never
/// read or write the real Contacts database, and the cases that matter, an
/// international number, a household mailbox and a linked pair, are exactly
/// the ones a live database is unlikely to contain on demand.
@Suite("Contact directory")
struct ContactDirectoryTests {
    // MARK: Fixtures

    static let alexHome = ContactRecord(
        identifier: "A1",
        givenName: "Alex",
        familyName: "Moreau",
        phoneNumbers: ["(555) 010-1234"],
        emailAddresses: ["alex.moreau@example.com", "family@example.com"]
    )
    static let alexWork = ContactRecord(
        identifier: "A2",
        givenName: "Alex",
        familyName: "Moreau",
        organizationName: "Ravel Press",
        phoneNumbers: ["+1 555 010 1234"],
        emailAddresses: ["a.moreau@ravelpress.example"]
    )
    static let jordanHousehold = ContactRecord(
        identifier: "B1",
        givenName: "Jordan",
        familyName: "Whitfield",
        emailAddresses: ["family@example.com"]
    )
    static let priyaHousehold = ContactRecord(
        identifier: "B2",
        givenName: "Priya",
        familyName: "Raman",
        emailAddresses: ["family@example.com"]
    )
    static let londonOne = ContactRecord(
        identifier: "C1",
        givenName: "Ian",
        familyName: "Blackwood",
        phoneNumbers: ["+44 20 7946 0958"]
    )
    static let londonTwo = ContactRecord(
        identifier: "C2",
        givenName: "Nora",
        familyName: "Blackwood",
        phoneNumbers: ["+44 20 7946 0959"]
    )
    static let linkedICloud = ContactRecord(
        identifier: "D1",
        givenName: "Renée",
        familyName: "O'Neill",
        phoneNumbers: ["+1 555 222 3333"],
        linkedIdentifiers: ["raw-icloud", "raw-exchange"]
    )
    static let linkedExchange = ContactRecord(
        identifier: "D2",
        givenName: "Renee",
        familyName: "ONeill",
        phoneNumbers: ["+1 555 222 3333"],
        linkedIdentifiers: ["raw-exchange"]
    )

    static let everyone: [ContactRecord] = [
        alexHome, alexWork, jordanHousehold, priyaHousehold,
        londonOne, londonTwo, linkedICloud, linkedExchange,
    ]

    // MARK: Normalization

    @Test("Phone numbers normalize without truncating international numbers")
    func phoneNormalization() {
        #expect(ContactNormalization.phone("(555) 010-1234") == "+15550101234")
        #expect(ContactNormalization.phone("+1 555 010 1234") == "+15550101234")
        #expect(ContactNormalization.phone("15550101234") == "+15550101234")
        #expect(ContactNormalization.phone("+44 20 7946 0958") == "+442079460958")
        #expect(ContactNormalization.phone("+44 20 7946 0958") != ContactNormalization.phone("+44 20 7946 0959"))
        #expect(ContactNormalization.phone("x204") == nil)
    }

    @Test("Names fold case, diacritics and punctuation")
    func nameNormalization() {
        #expect(ContactNormalization.name("Renée  O'Neill") == "renee oneill")
        #expect(ContactNormalization.name("  ") == "")
    }

    // MARK: Paging

    @Test("Directory order is total, so pages neither repeat nor skip")
    func stablePaging() {
        let ordered = ContactDirectory.sorted(Self.everyone)
        let reversed = ContactDirectory.sorted(Self.everyone.reversed())
        #expect(ordered.map(\.identifier) == reversed.map(\.identifier))

        var seen: [String] = []
        var offset = 0
        while true {
            let page = ContactDirectory.page(ordered, offset: offset, limit: 3)
            seen.append(contentsOf: page.records.map(\.identifier))
            guard let next = page.nextOffset else {
                #expect(page.hasMore == false)
                break
            }
            offset = next
        }
        #expect(seen == ordered.map(\.identifier))
        #expect(Set(seen).count == seen.count)
    }

    @Test("Paging clamps hostile offsets and limits")
    func pagingBounds() {
        let ordered = ContactDirectory.sorted(Self.everyone)
        let past = ContactDirectory.page(ordered, offset: Int.max, limit: 10)
        #expect(past.records.isEmpty)
        #expect(past.hasMore == false)
        #expect(past.nextOffset == nil)

        let huge = ContactDirectory.page(ordered, offset: 1, limit: Int.max)
        #expect(huge.records.count == ordered.count - 1)
        #expect(huge.hasMore == false)

        #expect(ContactDirectory.clampedLimit(nil) == ContactDirectory.defaultLimit)
        #expect(ContactDirectory.clampedLimit(0) == 1)
        #expect(ContactDirectory.clampedLimit(100_000) == ContactDirectory.maximumLimit)
        #expect(ContactDirectory.clampedOffset(-5) == 0)
    }

    @Test("Prefix filtering matches any name field")
    func prefixFilter() {
        #expect(ContactDirectory.matchesPrefix(Self.alexWork, prefix: "mor"))
        #expect(ContactDirectory.matchesPrefix(Self.alexWork, prefix: "Ravel"))
        #expect(ContactDirectory.matchesPrefix(Self.alexWork, prefix: "") == true)
        #expect(ContactDirectory.matchesPrefix(Self.alexWork, prefix: "z") == false)
    }

    // MARK: Duplicates

    @Test("The same person under two records ranks highest")
    func duplicatesRankRealPairFirst() throws {
        let suggestions = ContactDuplicates.suggestions(for: Self.everyone)
        let top = try #require(suggestions.first)
        #expect(top.identifiers == ["A1", "A2"])
        #expect(top.confidence == "high")
        #expect(top.reasons.contains("Shares a phone number"))
        // Ranked, descending, every time.
        #expect(suggestions.map(\.score) == suggestions.map(\.score).sorted(by: >))
        let repeated = ContactDuplicates.suggestions(for: Self.everyone.reversed())
        #expect(repeated.map(\.identifiers) == suggestions.map(\.identifiers))
    }

    @Test("A shared household mailbox alone is not a duplicate")
    func householdEmailIsNotEvidence() {
        let suggestions = ContactDuplicates.suggestions(for: Self.everyone)
        let householdPair = suggestions.first { $0.identifiers == ["B1", "B2"] }
        #expect(householdPair == nil)
        #expect(ContactNormalization.isSharedAddress("family@example.com"))
        #expect(ContactNormalization.isSharedAddress("alex.moreau@example.com") == false)
    }

    @Test("An address on three or more records counts as shared even when it looks personal")
    func widelyUsedAddressIsShared() {
        let shared = "smiths@example.com"
        let records = (1 ... 3).map {
            ContactRecord(
                identifier: "S\($0)",
                givenName: "Person\($0)",
                familyName: "Smith",
                emailAddresses: [shared]
            )
        }
        #expect(ContactDuplicates.sharedEmailAddresses(in: records).contains(shared))
        #expect(ContactDuplicates.suggestions(for: records).isEmpty)
    }

    @Test("Neighbouring international numbers are never treated as the same line")
    func internationalNumbersDoNotCollide() {
        let suggestions = ContactDuplicates.suggestions(for: [Self.londonOne, Self.londonTwo])
        #expect(suggestions.isEmpty)
    }

    @Test("Records macOS already links are not proposed as duplicates")
    func linkedRecordsAreSkipped() {
        let suggestions = ContactDuplicates.suggestions(for: [Self.linkedICloud, Self.linkedExchange])
        #expect(suggestions.isEmpty)
    }

    @Test("A shared number is found even when the names look unrelated")
    func sharedNumberAcrossDifferentNames() throws {
        let nickname = ContactRecord(
            identifier: "F1",
            givenName: "Bo",
            phoneNumbers: ["+1 555 777 8888"]
        )
        let formal = ContactRecord(
            identifier: "F2",
            givenName: "Robert",
            familyName: "Ferreira",
            phoneNumbers: ["555-777-8888"]
        )
        let pair = try #require(ContactDuplicates.suggestions(for: [nickname, formal]).first)
        #expect(pair.identifiers == ["F1", "F2"])
        #expect(pair.reasons == ["Shares a phone number"])
        #expect(pair.confidence == "low")
    }

    @Test("Same surname with different first names is at most a low-confidence hint")
    func relativesStayLowConfidence() throws {
        let siblingA = ContactRecord(
            identifier: "E1",
            givenName: "Tomas",
            familyName: "Lindqvist",
            emailAddresses: ["shared.inbox@lindqvist.example"]
        )
        let siblingB = ContactRecord(
            identifier: "E2",
            givenName: "Elin",
            familyName: "Lindqvist",
            emailAddresses: ["shared.inbox@lindqvist.example"]
        )
        let suggestions = ContactDuplicates.suggestions(for: [siblingA, siblingB])
        let pair = try #require(suggestions.first)
        #expect(pair.confidence == "low")
        #expect(pair.cautions.isEmpty == false)
        #expect(pair.score < 0.6)
    }

    // MARK: Recipient resolution

    @Test("An exact address match resolves confidently")
    func exactAddressIsConfident() {
        let resolution = ContactRecipients.resolve(
            query: "a.moreau@ravelpress.example",
            in: Self.everyone,
            channel: .email
        )
        #expect(resolution.isConfident)
        #expect(resolution.isAmbiguous == false)
        #expect(resolution.candidates.first?.identifier == "A2")
        #expect(resolution.candidates.first?.matchType == "email")
    }

    @Test("Two people with the same name resolve as ambiguous, never picked")
    func duplicateNamesStayAmbiguous() {
        let resolution = ContactRecipients.resolve(query: "Alex Moreau", in: Self.everyone)
        #expect(resolution.isConfident == false)
        #expect(resolution.isAmbiguous)
        #expect(resolution.candidates.count == 2)
        #expect(resolution.guidance.contains("let the user pick"))
    }

    @Test("A single weak name match is still not confident")
    func weakNameMatchIsNotConfident() {
        let resolution = ContactRecipients.resolve(query: "Bla", in: Self.everyone)
        #expect(resolution.candidates.isEmpty == false)
        #expect(resolution.isConfident == false)
        #expect(resolution.isAmbiguous)
        #expect(resolution.candidates.allSatisfy { $0.score < 0.8 })
    }

    @Test("A unique exact name resolves, but flags an address choice when there are several")
    func uniqueNameWithSeveralAddresses() {
        let resolution = ContactRecipients.resolve(
            query: "Jordan Whitfield",
            in: Self.everyone,
            channel: .email
        )
        #expect(resolution.isConfident)
        #expect(resolution.needsAddressChoice == false)

        let multi = ContactRecipients.resolve(query: "Alex Moreau", in: [Self.alexHome], channel: .email)
        #expect(multi.isConfident)
        #expect(multi.needsAddressChoice)
        #expect(multi.guidance.contains("Ask which one"))
    }

    @Test("No match says so rather than guessing")
    func noMatch() {
        let resolution = ContactRecipients.resolve(query: "Zephyr Quartermaine", in: Self.everyone)
        #expect(resolution.candidates.isEmpty)
        #expect(resolution.isConfident == false)
        #expect(resolution.guidance.contains("No contact matched"))

        let empty = ContactRecipients.resolve(query: "   ", in: Self.everyone)
        #expect(empty.candidates.isEmpty)
        #expect(empty.isAmbiguous == false)
    }

    @Test("An unknown address never falls back to fuzzy name matching")
    func unknownAddressDoesNotFuzzyMatch() {
        let resolution = ContactRecipients.resolve(query: "alex@elsewhere.example", in: Self.everyone)
        #expect(resolution.candidates.isEmpty)
    }

    @Test("Phone lookup tolerates formatting differences")
    func phoneLookup() {
        let resolution = ContactRecipients.resolve(query: "555-010-1234", in: Self.everyone, channel: .phone)
        #expect(resolution.candidates.count == 2)
        #expect(resolution.isConfident == false)
        #expect(resolution.candidates.allSatisfy { $0.matchType == "phone" })
    }
}
