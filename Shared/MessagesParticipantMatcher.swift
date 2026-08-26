// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

func isValidMessageParticipant(_ participant: String) -> Bool {
    let trimmed = participant.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if trimmed.contains("@") {
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty
            && !parts[1].isEmpty
            && trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    let phoneFormatting = CharacterSet(charactersIn: "+-().").union(.whitespaces)
    let isPhoneSyntax = trimmed.unicodeScalars.allSatisfy {
        CharacterSet.decimalDigits.contains($0) || phoneFormatting.contains($0)
    }
    return isPhoneSyntax && trimmed.contains(where: \.isNumber)
}

/// Produces the handle forms Messages commonly stores for one recipient.
func messagesRecipientCandidates(for recipient: String) -> [String] {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") {
        return [trimmed.lowercased()]
    }

    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return [trimmed] }

    var candidates: [String] = []
    func add(_ candidate: String) {
        if !candidates.contains(candidate) {
            candidates.append(candidate)
        }
    }

    if trimmed.hasPrefix("+") {
        add("+\(digits)")
        add(digits)
    } else if digits.count == 10 {
        add("+1\(digits)")
        add("1\(digits)")
        add(digits)
    } else if digits.count == 11 && digits.hasPrefix("1") {
        add("+\(digits)")
        add(digits)
        add(String(digits.dropFirst()))
    } else {
        add("+\(digits)")
        add(digits)
    }
    return candidates
}

/// Filters Madrid's suffix-query results so SQL wildcard characters in an
/// alias cannot broaden a participant-scoped request.
func messageHandle(_ handle: String, matchesAny participants: [String]) -> Bool {
    let handleCandidates = Set(messagesRecipientCandidates(for: handle))
    return participants.filter(isValidMessageParticipant).contains { participant in
        !handleCandidates.isDisjoint(with: messagesRecipientCandidates(for: participant))
    }
}
