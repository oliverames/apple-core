// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// Occurrence selection is the half of single-event retrieval that can go
/// quietly wrong, so it is tested over fabricated candidates rather than
/// against a live EventKit store. No calendar is read or written here.
@Suite("Calendar event lookup")
struct CalendarEventLookupTests {
    static let base = Date(timeIntervalSince1970: 1_757_500_000)

    static func candidate(_ identifier: String, _ offsetHours: Double) -> CalendarOccurrenceCandidate {
        CalendarOccurrenceCandidate(
            identifier: identifier,
            start: base.addingTimeInterval(offsetHours * 3600)
        )
    }

    // MARK: Identifier normalization

    @Test("A missing identifier is refused before any store read")
    func missingIdentifier() {
        #expect(throws: CalendarEventLookupError.missingIdentifier) {
            _ = try CalendarEventLookup.normalize(identifier: nil)
        }
    }

    @Test("Whitespace-only identifiers are refused rather than searched for")
    func blankIdentifier() {
        #expect(throws: CalendarEventLookupError.blankIdentifier) {
            _ = try CalendarEventLookup.normalize(identifier: "   \n")
        }
    }

    @Test("Surrounding whitespace is trimmed from a pasted identifier")
    func trimsIdentifier() throws {
        #expect(try CalendarEventLookup.normalize(identifier: "  ABC-123 ") == "ABC-123")
    }

    // MARK: Window

    @Test("The search window covers a day back and two days forward")
    func window() {
        let window = CalendarEventLookup.window(around: Self.base)
        #expect(window.start == Self.base.addingTimeInterval(-86_400))
        #expect(window.end == Self.base.addingTimeInterval(172_800))
    }

    // MARK: Selection

    @Test("An occurrence at the requested moment is an exact match")
    func exactMatch() {
        let selection = CalendarEventLookup.selectOccurrence(
            from: [Self.candidate("E1", 0), Self.candidate("E1", 24)],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        #expect(selection == .exact(Self.candidate("E1", 0)))
    }

    @Test("A match within a minute still counts as exact")
    func toleranceMatch() {
        let requested = Self.base.addingTimeInterval(-30)
        let selection = CalendarEventLookup.selectOccurrence(
            from: [Self.candidate("E1", 0)],
            identifier: "E1",
            occurrenceDate: requested
        )
        #expect(selection == .exact(Self.candidate("E1", 0)))
    }

    @Test("A different occurrence is reported as nearest, with its offset")
    func nearestMatchReportsOffset() {
        let selection = CalendarEventLookup.selectOccurrence(
            from: [Self.candidate("E1", 6), Self.candidate("E1", 30)],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        guard case .nearest(let candidate, let offset) = selection else {
            Issue.record("Expected a nearest match, got \(selection)")
            return
        }
        #expect(candidate == Self.candidate("E1", 6))
        #expect(offset == 6 * 3600)
    }

    @Test("Occurrences of other events in the window are never selected")
    func ignoresOtherIdentifiers() {
        let selection = CalendarEventLookup.selectOccurrence(
            from: [Self.candidate("OTHER", 0), Self.candidate("E1", 10)],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        guard case .nearest(let candidate, _) = selection else {
            Issue.record("Expected a nearest match, got \(selection)")
            return
        }
        #expect(candidate.identifier == "E1")
    }

    @Test("A deleted or stale identifier resolves to nothing rather than to a neighbour")
    func noMatch() {
        let selection = CalendarEventLookup.selectOccurrence(
            from: [Self.candidate("OTHER", 0)],
            identifier: "GONE",
            occurrenceDate: Self.base
        )
        #expect(selection == .none)
    }

    @Test("An empty window resolves to nothing")
    func emptyWindow() {
        let selection = CalendarEventLookup.selectOccurrence(
            from: [],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        #expect(selection == .none)
    }

    @Test("Equidistant occurrences resolve to the earlier one, not to store order")
    func tieBreaksToEarlier() {
        let later = Self.candidate("E1", 4)
        let earlier = Self.candidate("E1", -4)
        let fromOneOrder = CalendarEventLookup.selectOccurrence(
            from: [later, earlier],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        let fromOther = CalendarEventLookup.selectOccurrence(
            from: [earlier, later],
            identifier: "E1",
            occurrenceDate: Self.base
        )
        #expect(fromOneOrder == fromOther)
        guard case .nearest(let candidate, _) = fromOneOrder else {
            Issue.record("Expected a nearest match, got \(fromOneOrder)")
            return
        }
        #expect(candidate == earlier)
    }

    // MARK: Not-found messaging

    @Test("The not-found message names both stale identifiers and deletion")
    func notFoundMessageIsHonest() {
        let plain = CalendarEventLookup.notFoundMessage(identifier: "E1", occurrenceDate: nil)
        #expect(plain.hasPrefix("NOT_FOUND:"))
        #expect(plain.contains("stale"))
        #expect(plain.contains("deleted"))

        let occurrence = CalendarEventLookup.notFoundMessage(
            identifier: "E1",
            occurrenceDate: Self.base
        )
        #expect(occurrence.contains("occurrence"))
        #expect(occurrence.contains("E1"))
    }
}
