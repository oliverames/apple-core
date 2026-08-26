// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@Suite("Messages participant matching")
struct MessagesParticipantMatcherTests {
    @Test("Equivalent phone forms match")
    func equivalentPhoneFormsMatch() {
        #expect(messageHandle("+14155551234", matchesAny: ["(415) 555-1234"]))
    }

    @Test("SQL wildcard aliases cannot broaden matches")
    func wildcardAliasesDoNotMatch() {
        #expect(!messageHandle("+14155551234", matchesAny: ["%", "_"]))
        #expect(!messageHandle("32665", matchesAny: ["not-a-phone-32665"]))
    }

    @Test("Email matching is exact and case insensitive")
    func emailMatchingIsExact() {
        #expect(messageHandle("name_tag@example.com", matchesAny: ["NAME_TAG@example.com"]))
        #expect(!messageHandle("other_tag@example.com", matchesAny: ["name_tag@example.com"]))
    }
}
