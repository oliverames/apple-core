// SPDX-License-Identifier: GPL-3.0-or-later
//
// EventKit has no free/busy query, so `calendar_availability` computes gaps
// from the events themselves. These are the corners that computation gets
// wrong: overlapping meetings, a meeting that starts before the window, two
// that touch exactly, and a day window that a search range only partly covers.

import Foundation
import Testing

@Suite("Calendar availability")
struct CalendarAvailabilityTests {
    /// 2026-09-14 is a Monday, in UTC so the arithmetic in these tests is
    /// independent of where the machine running them sits.
    static let utc = {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC"),
                year: 2026,
                month: 9,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    @Test("Overlapping busy intervals collapse into one")
    func mergesOverlaps() {
        let merged = CalendarAvailability.merged([
            BusyInterval(start: Self.at(14, 9), end: Self.at(14, 11)),
            BusyInterval(start: Self.at(14, 10), end: Self.at(14, 12)),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].start == Self.at(14, 9))
        #expect(merged[0].end == Self.at(14, 12))
    }

    @Test("Back-to-back meetings leave no gap between them")
    func mergesTouching() {
        // Without merging on touch, 10:00-10:00 would be reported as free.
        let merged = CalendarAvailability.merged([
            BusyInterval(start: Self.at(14, 9), end: Self.at(14, 10)),
            BusyInterval(start: Self.at(14, 10), end: Self.at(14, 11)),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].end == Self.at(14, 11))
    }

    @Test("A zero-length or reversed interval occupies nothing")
    func ignoresEmptyIntervals() {
        let merged = CalendarAvailability.merged([
            BusyInterval(start: Self.at(14, 9), end: Self.at(14, 9)),
            BusyInterval(start: Self.at(14, 12), end: Self.at(14, 11)),
        ])
        #expect(merged.isEmpty)
    }

    @Test("Gaps are found around a meeting inside the window")
    func gapsAroundMeeting() {
        let window = FreeSlot(start: Self.at(14, 9), end: Self.at(14, 17))
        let gaps = CalendarAvailability.gaps(
            in: window,
            busy: [BusyInterval(start: Self.at(14, 12), end: Self.at(14, 13))]
        )
        #expect(gaps.count == 2)
        #expect(gaps[0].start == Self.at(14, 9))
        #expect(gaps[0].end == Self.at(14, 12))
        #expect(gaps[1].start == Self.at(14, 13))
        #expect(gaps[1].end == Self.at(14, 17))
    }

    @Test("A meeting that starts before the window only clips its front")
    func meetingStraddlingWindowStart() {
        let window = FreeSlot(start: Self.at(14, 9), end: Self.at(14, 17))
        let gaps = CalendarAvailability.gaps(
            in: window,
            busy: [BusyInterval(start: Self.at(14, 7), end: Self.at(14, 10))]
        )
        #expect(gaps.count == 1)
        #expect(gaps[0].start == Self.at(14, 10))
        #expect(gaps[0].end == Self.at(14, 17))
    }

    @Test("A meeting running past the window does not extend it")
    func meetingStraddlingWindowEnd() {
        let window = FreeSlot(start: Self.at(14, 9), end: Self.at(14, 17))
        let gaps = CalendarAvailability.gaps(
            in: window,
            busy: [BusyInterval(start: Self.at(14, 16), end: Self.at(14, 20))]
        )
        #expect(gaps.count == 1)
        #expect(gaps[0].end == Self.at(14, 16))
    }

    @Test("A fully booked window yields nothing")
    func fullyBooked() {
        let window = FreeSlot(start: Self.at(14, 9), end: Self.at(14, 17))
        let gaps = CalendarAvailability.gaps(
            in: window,
            busy: [BusyInterval(start: Self.at(14, 8), end: Self.at(14, 18))]
        )
        #expect(gaps.isEmpty)
    }

    @Test("An empty window yields nothing rather than a zero-length slot")
    func emptyWindow() {
        let window = FreeSlot(start: Self.at(14, 9), end: Self.at(14, 9))
        #expect(CalendarAvailability.gaps(in: window, busy: []).isEmpty)
    }

    @Test("Day windows are produced per day, clipped to the search range")
    func dailyWindowsClipped() {
        // Range starts at 11:00 on the first day, so that day's 09:00-17:00
        // window starts at 11:00 instead.
        let windows = CalendarAvailability.dailyWindows(
            from: Self.at(14, 11),
            to: Self.at(16, 12),
            window: .workingHours,
            weekdays: nil,
            calendar: Self.utc
        )
        #expect(windows.count == 3)
        #expect(windows[0].start == Self.at(14, 11))
        #expect(windows[0].end == Self.at(14, 17))
        #expect(windows[1].start == Self.at(15, 9))
        #expect(windows[2].end == Self.at(16, 12))
    }

    @Test("Weekday filtering skips the days not asked for")
    func weekdayFilter() {
        // 2026-09-14 is a Monday; 19 and 20 September are Saturday and Sunday.
        let windows = CalendarAvailability.dailyWindows(
            from: Self.at(14, 0),
            to: Self.at(21, 0),
            window: .workingHours,
            weekdays: [2, 3, 4, 5, 6],
            calendar: Self.utc
        )
        #expect(windows.count == 5)
        for window in windows {
            let weekday = Self.utc.component(.weekday, from: window.start)
            #expect(weekday != 1 && weekday != 7)
        }
    }

    @Test("Slots shorter than the minimum are left out")
    func minimumDuration() {
        let slots = CalendarAvailability.freeSlots(
            from: Self.at(14, 9),
            to: Self.at(14, 17),
            busy: [
                // Leaves a 15-minute gap at 09:00 and three hours after 12:15.
                BusyInterval(start: Self.at(14, 9, 15), end: Self.at(14, 12, 15))
            ],
            window: .workingHours,
            minimumDuration: 30 * 60,
            calendar: Self.utc
        )
        #expect(slots.count == 1)
        #expect(slots[0].start == Self.at(14, 12, 15))
    }

    @Test("The slot limit stops the search rather than truncating afterwards")
    func slotLimit() {
        let slots = CalendarAvailability.freeSlots(
            from: Self.at(14, 0),
            to: Self.at(21, 0),
            busy: [],
            window: .workingHours,
            calendar: Self.utc,
            limit: 3
        )
        #expect(slots.count == 3)
    }

    @Test("Conflicts report what overlaps a proposal, in order")
    func conflictsOverlapping() {
        let proposal = FreeSlot(start: Self.at(14, 10), end: Self.at(14, 11))
        let conflicts = CalendarAvailability.conflicts(
            with: proposal,
            busy: [
                BusyInterval(start: Self.at(14, 14), end: Self.at(14, 15), title: "Later"),
                BusyInterval(start: Self.at(14, 10, 30), end: Self.at(14, 12), title: "Overlap"),
                // Ends exactly when the proposal starts: not a conflict.
                BusyInterval(start: Self.at(14, 9), end: Self.at(14, 10), title: "Before"),
            ]
        )
        #expect(conflicts.count == 1)
        #expect(conflicts[0].title == "Overlap")
    }

    @Test("A clear proposal has no conflicts")
    func conflictsNone() {
        let proposal = FreeSlot(start: Self.at(14, 10), end: Self.at(14, 11))
        let conflicts = CalendarAvailability.conflicts(
            with: proposal,
            busy: [BusyInterval(start: Self.at(14, 11), end: Self.at(14, 12))]
        )
        #expect(conflicts.isEmpty)
    }
}
