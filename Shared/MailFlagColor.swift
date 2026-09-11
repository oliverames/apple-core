// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mail's coloured flags, in both vocabularies.
//
// `mail_set_flagged` used to speak only in booleans, which is how Mail's
// `flagged status` property reads. But Mail also carries `flag index`, an
// integer 0...6 that selects which of the seven flag colours the message
// wears, and the two properties are not independent: setting `flag index`
// flags the message, and clearing `flagged status` resets the index to -1.
//
// A person says "flag that red". Mail says `flagIndex = 0`. This file is the
// translation, kept out of the service so the mapping can be tested without
// Mail running.
//
// The order below is Mail's own, read off the Flags menu in Mail 16 on macOS
// Tahoe, and it has been stable since OS X Mavericks introduced coloured
// flags. `flag index` -1 means "flagged, colour unset", which Mail shows as
// the default orange; it is reported as `nil` rather than guessed at.

import Foundation

/// One of Mail's seven flag colours.
enum MailFlagColor: String, CaseIterable, Sendable, Codable, Equatable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    /// The value Mail's `flag index` property carries for this colour.
    var index: Int {
        switch self {
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .gray: return 6
        }
    }

    /// The colour Mail means by a `flag index`, or nil for any other value.
    ///
    /// -1 is Mail's "flagged but no colour chosen", and every index outside
    /// 0...6 is something a future Mail release invented; neither is guessed
    /// at, because a wrong colour name in a result is worse than an absent one.
    static func named(index: Int) -> MailFlagColor? {
        allCases.first { $0.index == index }
    }

    /// Parses a caller-supplied colour name, case- and whitespace-insensitively.
    ///
    /// `grey` is accepted alongside `gray` because both spellings reach this
    /// from people, and refusing one of them buys nothing.
    static func named(_ raw: String) -> MailFlagColor? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "grey" { return .gray }
        return MailFlagColor(rawValue: normalized)
    }

    /// Every name this type accepts, for listing in an error or a schema.
    static var acceptedNames: [String] {
        allCases.map(\.rawValue) + ["grey"]
    }
}

/// What a flag write should do, resolved from the tool's two arguments.
///
/// The two arguments (`flagged`, `color`) can disagree, and the disagreement
/// has to be settled here rather than in JXA, where a mistake costs an Apple
/// Event round-trip against real mail to discover.
enum MailFlagInstruction: Sendable, Equatable {
    /// Clear the flag. Mail resets `flag index` to -1 as a side effect.
    case unflag
    /// Flag without choosing a colour: set `flagged status` only.
    case flag
    /// Flag in a specific colour: set `flag index`, which flags it too.
    case color(MailFlagColor)

    /// Resolves the pair, or explains why it cannot be resolved.
    ///
    /// `color` with `flagged: false` is refused rather than silently favouring
    /// one of them: a caller that asks to unflag a message *and* paint it blue
    /// has a bug, and picking either reading for them hides it.
    static func resolve(flagged: Bool, color: String?) throws -> MailFlagInstruction {
        guard let color, !color.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return flagged ? .flag : .unflag
        }
        guard flagged else {
            throw MailFlagColorError.contradictoryRequest
        }
        guard let resolved = MailFlagColor.named(color) else {
            throw MailFlagColorError.unknownColor(
                color,
                accepted: MailFlagColor.acceptedNames
            )
        }
        return .color(resolved)
    }

    /// The argument the JXA write script reads: an index, or a bare flag/unflag.
    ///
    /// Kept as a string because every script in this service takes its input
    /// through argv, so nothing user-supplied is ever interpolated into source.
    var scriptArgument: String {
        switch self {
        case .unflag: return "unflag"
        case .flag: return "flag"
        case .color(let color): return String(color.index)
        }
    }
}

enum MailFlagColorError: Error, CustomStringConvertible, Equatable {
    case contradictoryRequest
    case unknownColor(String, accepted: [String])

    var description: String {
        switch self {
        case .contradictoryRequest:
            return "color cannot be set while flagged is false; omit color to unflag"
        case .unknownColor(let given, let accepted):
            return "unknown flag color \(given); expected one of "
                + accepted.joined(separator: ", ")
        }
    }
}
