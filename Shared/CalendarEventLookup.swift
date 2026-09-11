// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure lookup logic for retrieving one calendar event by identifier.
//
// EventKit's `event(withIdentifier:)` answers with the first occurrence of a
// recurring series, which is the wrong event whenever the caller means "the
// one on Thursday". Resolving a specific occurrence therefore means searching
// a window and choosing among candidates, and choosing is exactly the part
// worth testing away from a live store: a stale identifier, a deleted record
// and an identifier that belongs to a series with no occurrence in the window
// all look the same to a caller unless the outcomes are kept apart.
//
// Nothing here touches EventKit. The service turns live `EKEvent`s into
// `CalendarOccurrenceCandidate` values and hands them over.

import Foundation

/// One occurrence as the lookup sees it: which series it belongs to and when
/// it starts. Everything else about the event is irrelevant to choosing.
public struct CalendarOccurrenceCandidate: Sendable, Equatable {
    public let identifier: String
    public let start: Date

    public init(identifier: String, start: Date) {
        self.identifier = identifier
        self.start = start
    }
}

/// What resolving an identifier produced, kept apart so the tool can say why
/// rather than returning an empty answer for four different reasons.
public enum CalendarOccurrenceSelection: Sendable, Equatable {
    /// An occurrence starting exactly at the requested moment.
    case exact(CalendarOccurrenceCandidate)
    /// The nearest occurrence within the search window, with how far off it
    /// was. The caller is told the distance rather than being allowed to
    /// assume the match was exact.
    case nearest(CalendarOccurrenceCandidate, offset: TimeInterval)
    /// The identifier matched nothing in the window.
    case none
}

public enum CalendarEventLookupError: Error, Equatable, CustomStringConvertible {
    case missingIdentifier
    case blankIdentifier

    public var description: String {
        switch self {
        case .missingIdentifier:
            return "An event identifier is required. Get one from calendar_events_fetch."
        case .blankIdentifier:
            return "The event identifier was empty after trimming whitespace."
        }
    }
}

public enum CalendarEventLookup {
    /// How far either side of a requested occurrence date to search.
    ///
    /// A day back and two days forward covers an all-day event recorded at
    /// local midnight, a time-zone shift, and a caller who passes the date
    /// without a time. Widening it further starts to pull in the neighbouring
    /// occurrence of a daily series, which would make "nearest" meaningless.
    public static let occurrenceWindowBefore: TimeInterval = 86_400
    public static let occurrenceWindowAfter: TimeInterval = 2 * 86_400

    /// Within this distance an occurrence counts as the one that was asked
    /// for. A minute absorbs a caller who rounds seconds off a start time
    /// without absorbing a genuinely different occurrence.
    public static let exactMatchTolerance: TimeInterval = 60

    public static func normalize(identifier raw: String?) throws -> String {
        guard let raw else { throw CalendarEventLookupError.missingIdentifier }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarEventLookupError.blankIdentifier }
        return trimmed
    }

    public static func window(around occurrenceDate: Date) -> (start: Date, end: Date) {
        (
            occurrenceDate.addingTimeInterval(-occurrenceWindowBefore),
            occurrenceDate.addingTimeInterval(occurrenceWindowAfter)
        )
    }

    /// Picks the occurrence of `identifier` closest to `occurrenceDate`.
    ///
    /// Ties go to the earlier occurrence, so the answer does not depend on the
    /// order EventKit happened to return.
    public static func selectOccurrence(
        from candidates: [CalendarOccurrenceCandidate],
        identifier: String,
        occurrenceDate: Date
    ) -> CalendarOccurrenceSelection {
        let matching = candidates.filter { $0.identifier == identifier }
        guard !matching.isEmpty else { return .none }

        let best = matching.min { left, right in
            let leftOffset = abs(left.start.timeIntervalSince(occurrenceDate))
            let rightOffset = abs(right.start.timeIntervalSince(occurrenceDate))
            if leftOffset == rightOffset { return left.start < right.start }
            return leftOffset < rightOffset
        }
        guard let best else { return .none }

        let offset = best.start.timeIntervalSince(occurrenceDate)
        if abs(offset) <= exactMatchTolerance { return .exact(best) }
        return .nearest(best, offset: offset)
    }

    /// The message for an identifier that resolved to nothing.
    ///
    /// A stale identifier and a deleted event are indistinguishable through
    /// EventKit: both simply fail to resolve. Saying so is more useful than
    /// implying the event definitely still exists somewhere.
    public static func notFoundMessage(identifier: String, occurrenceDate: Date?) -> String {
        if let occurrenceDate {
            let formatted = ISO8601DateFormatter().string(from: occurrenceDate)
            return
                "NOT_FOUND: no occurrence of event \(identifier) within a day either side of \(formatted). "
                + "The identifier may be stale, the event may have been deleted, or that occurrence may "
                + "not exist. Omit occurrenceDate to look the series up by identifier alone."
        }
        return
            "NOT_FOUND: no event with identifier \(identifier). The identifier may be stale or the event "
            + "may have been deleted. Use calendar_events_fetch to get a current identifier."
    }
}
