// SPDX-License-Identifier: GPL-3.0-or-later
//
// Approximate matching for Messages content search.
//
// Literal `contains` search answers "did anyone write exactly this?", which is
// rarely the question. People misremember wording, type a name without its
// accent, and search for "resturant". This file ranks messages by how well
// they match instead, and every result says which kind of match it was, so a
// fuzzy hit is never presented as if the words were really there.
//
// Pure text in, scores out: no database, no Messages app.

import Foundation

/// How a message matched, strongest first. The caller sees this, because
/// "your exact phrase" and "something close to it" are different answers.
public enum MessageMatchKind: String, Sendable, Equatable, Comparable {
    /// The query appears verbatim (after normalization) in the message.
    case phrase
    /// Every word of the query appears somewhere in the message.
    case allWords
    /// Every word matched, but at least one only approximately.
    case approximate
    /// Some words matched and others did not.
    case partial

    private var rank: Int {
        switch self {
        case .phrase: return 3
        case .allWords: return 2
        case .approximate: return 1
        case .partial: return 0
        }
    }

    public static func < (lhs: MessageMatchKind, rhs: MessageMatchKind) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct MessageMatch: Sendable, Equatable {
    public let kind: MessageMatchKind
    /// 0 to 1. Comparable only within one search: it ranks results, it does
    /// not measure relevance in the abstract.
    public let score: Double
    /// The query words that matched, in the query's order.
    public let matchedWords: [String]

    public init(kind: MessageMatchKind, score: Double, matchedWords: [String]) {
        self.kind = kind
        self.score = score
        self.matchedWords = matchedWords
    }
}

public enum MessagesSearchMatching {
    /// Below this, a result is noise rather than an approximate match.
    ///
    /// The value is chosen so that matching half the words of a two-word
    /// query falls below it: "dentist" alone is not an answer to "dentist
    /// appointment". A caller who wants those can lower `minimumScore`.
    public static let defaultMinimumScore = 0.55

    /// Case- and diacritic-insensitive, punctuation reduced to spaces.
    /// "Café's" and "cafes" normalize alike.
    public static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func words(_ raw: String) -> [String] {
        normalize(raw).split(separator: " ").map(String.init)
    }

    /// How far apart two words may be and still count as the same word.
    ///
    /// Short words get no slack at all: at one edit, "cat" matches "car",
    /// "can" and "bat", which would make a three-letter search useless.
    public static func editAllowance(for word: String) -> Int {
        switch word.count {
        case 0 ... 4: return 0
        case 5 ... 7: return 1
        default: return 2
        }
    }

    /// Scores one message against a query, or returns nil when nothing
    /// worthwhile matched.
    public static func match(
        query: String,
        text: String,
        minimumScore: Double = defaultMinimumScore
    ) -> MessageMatch? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return nil }

        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        let textWords = normalizedText.split(separator: " ").map(String.init)

        // A verbatim phrase always wins, and wins outright: it is the one
        // case where the caller's words really are in the message.
        if normalizedText.contains(normalizedQuery) {
            return MessageMatch(kind: .phrase, score: 1, matchedWords: queryWords)
        }

        var matchedWords: [String] = []
        var approximateCount = 0
        var totalCloseness = 0.0

        for word in queryWords {
            if textWords.contains(word) || normalizedText.contains(word) {
                matchedWords.append(word)
                totalCloseness += 1
                continue
            }
            let allowance = editAllowance(for: word)
            guard allowance > 0 else { continue }
            var best: Int?
            for candidate in textWords {
                // Length alone rules most candidates out before the expensive part.
                guard abs(candidate.count - word.count) <= allowance else { continue }
                let distance = editDistance(word, candidate, limit: allowance)
                guard distance <= allowance else { continue }
                if best == nil || distance < best! { best = distance }
                if distance == 1 { break }
            }
            if let best {
                matchedWords.append(word)
                approximateCount += 1
                totalCloseness += 1 - (Double(best) / Double(word.count))
            }
        }

        guard !matchedWords.isEmpty else { return nil }

        let coverage = Double(matchedWords.count) / Double(queryWords.count)
        let closeness = totalCloseness / Double(matchedWords.count)
        // Coverage dominates: how much of the query was found decides the
        // score, and how closely those words matched only separates results
        // that found the same share. The cap keeps every non-phrase match
        // below a verbatim one.
        let score = min(0.99, coverage * (0.8 + (0.2 * closeness)))
        guard score >= minimumScore else { return nil }

        let kind: MessageMatchKind
        if matchedWords.count == queryWords.count {
            kind = approximateCount == 0 ? .allWords : .approximate
        } else {
            kind = .partial
        }
        return MessageMatch(kind: kind, score: score, matchedWords: matchedWords)
    }

    /// Levenshtein distance, abandoned once every cell of a row exceeds
    /// `limit`, because a distant word's exact distance is not interesting.
    public static func editDistance(_ left: String, _ right: String, limit: Int) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        if leftCharacters.isEmpty { return rightCharacters.count }
        if rightCharacters.isEmpty { return leftCharacters.count }

        var previous = Array(0 ... rightCharacters.count)
        var current = [Int](repeating: 0, count: rightCharacters.count + 1)

        for row in 1 ... leftCharacters.count {
            current[0] = row
            var rowMinimum = current[0]
            for column in 1 ... rightCharacters.count {
                let same = leftCharacters[row - 1] == rightCharacters[column - 1]
                let substitution = previous[column - 1] + (same ? 0 : 1)
                current[column] = min(previous[column] + 1, current[column - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[column])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[rightCharacters.count]
    }
}
