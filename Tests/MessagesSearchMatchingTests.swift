// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// Approximate search has to be loose enough to find a misremembered phrase
/// and tight enough that it does not return the whole inbox. Both halves are
/// tested here, over literal strings: no Messages database is opened.
@Suite("Messages search matching")
struct MessagesSearchMatchingTests {
    @Test("An exact phrase is a phrase match at full score")
    func exactPhrase() throws {
        let match = try #require(
            MessagesSearchMatching.match(query: "dinner tonight", text: "Are we still on for dinner tonight?")
        )
        #expect(match.kind == .phrase)
        #expect(match.score == 1)
    }

    @Test("Case and accents do not prevent a phrase match")
    func foldsCaseAndDiacritics() throws {
        let match = try #require(
            MessagesSearchMatching.match(query: "cafe rene", text: "Meet me at Café René at six")
        )
        #expect(match.kind == .phrase)
    }

    @Test("The same words in another order match as all-words, not as a phrase")
    func reorderedWords() throws {
        let match = try #require(
            MessagesSearchMatching.match(query: "tonight dinner", text: "dinner is at eight tonight")
        )
        #expect(match.kind == .allWords)
        #expect(match.score < 1)
    }

    @Test("A misspelling still matches, and is labeled approximate")
    func misspellingIsApproximate() throws {
        let match = try #require(
            MessagesSearchMatching.match(query: "resturant", text: "the restaurant was closed")
        )
        #expect(match.kind == .approximate)
        #expect(match.matchedWords == ["resturant"])
    }

    @Test("Short words get no edit slack, so \"cat\" does not match \"car\"")
    func shortWordsAreStrict() {
        #expect(MessagesSearchMatching.match(query: "cat", text: "the car is here") == nil)
        #expect(MessagesSearchMatching.editAllowance(for: "cat") == 0)
    }

    @Test("An unrelated message does not match at all")
    func unrelatedDoesNotMatch() {
        #expect(
            MessagesSearchMatching.match(query: "dentist appointment", text: "pick up milk") == nil
        )
    }

    @Test("Half a two-word query is below the default threshold")
    func partialBelowThreshold() {
        // One word of two is half coverage, which sits under the default.
        #expect(
            MessagesSearchMatching.match(query: "dentist appointment", text: "the dentist called") == nil
        )
    }

    @Test("A lower threshold surfaces partial matches, and labels them partial")
    func partialAtLowerThreshold() throws {
        let match = try #require(
            MessagesSearchMatching.match(
                query: "dentist appointment",
                text: "the dentist called",
                minimumScore: 0.2
            )
        )
        #expect(match.kind == .partial)
        #expect(match.matchedWords == ["dentist"])
    }

    @Test("A phrase match outranks an all-words match, which outranks an approximate one")
    func scoresOrderAsExpected() throws {
        let phrase = try #require(
            MessagesSearchMatching.match(query: "beach house", text: "the beach house was lovely")
        )
        let allWords = try #require(
            MessagesSearchMatching.match(query: "beach house", text: "the house near the beach")
        )
        let approximate = try #require(
            MessagesSearchMatching.match(query: "beach housse", text: "the beach house was lovely")
        )
        #expect(phrase.score > allWords.score)
        #expect(allWords.score > approximate.score)
        #expect(MessageMatchKind.phrase > MessageMatchKind.allWords)
        #expect(MessageMatchKind.allWords > MessageMatchKind.approximate)
    }

    @Test("An empty query or empty message matches nothing")
    func emptyInputs() {
        #expect(MessagesSearchMatching.match(query: "   ", text: "anything") == nil)
        #expect(MessagesSearchMatching.match(query: "anything", text: "") == nil)
        #expect(MessagesSearchMatching.match(query: "!!!", text: "hello") == nil)
    }

    @Test("Edit distance gives up once the limit is exceeded")
    func boundedEditDistance() {
        #expect(MessagesSearchMatching.editDistance("kitten", "sitting", limit: 3) == 3)
        #expect(MessagesSearchMatching.editDistance("kitten", "sitting", limit: 1) > 1)
        #expect(MessagesSearchMatching.editDistance("same", "same", limit: 0) == 0)
    }

    @Test("Normalization collapses punctuation and whitespace")
    func normalization() {
        #expect(MessagesSearchMatching.normalize("  Hello,   world!! ") == "hello world")
        #expect(MessagesSearchMatching.words("it's a test") == ["it", "s", "a", "test"])
    }
}
