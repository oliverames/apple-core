// SPDX-License-Identifier: GPL-3.0-or-later
//
// A rule serialized here is handed straight back to the RRULE parser on the
// next update, so these tests pin the spelling the parser expects: uppercase
// part names, semicolon separators, INTERVAL omitted when it is 1, and UNTIL
// in UTC basic format.

import Foundation
import Testing

@Suite("Recurrence description")
struct RecurrenceDescriptionTests {
    @Test("A simple daily rule is just its frequency")
    func simpleDaily() {
        let rule = RecurrenceDescription(frequency: "daily")
        #expect(rule.rrule == "FREQ=DAILY")
    }

    @Test("An interval of one is left out, and anything else is written")
    func interval() {
        #expect(RecurrenceDescription(frequency: "weekly", interval: 1).rrule == "FREQ=WEEKLY")
        #expect(
            RecurrenceDescription(frequency: "weekly", interval: 2).rrule
                == "FREQ=WEEKLY;INTERVAL=2"
        )
    }

    @Test("Weekdays use RFC 5545 codes, with EventKit's Sunday-is-1 numbering")
    func weekdays() {
        let rule = RecurrenceDescription(
            frequency: "weekly",
            daysOfTheWeek: [(weekday: 2, weekNumber: 0), (weekday: 4, weekNumber: 0)]
        )
        #expect(rule.rrule == "FREQ=WEEKLY;BYDAY=MO,WE")
    }

    @Test("An ordinal weekday carries its week number")
    func ordinalWeekday() {
        // "the last Friday of the month"
        let rule = RecurrenceDescription(
            frequency: "monthly",
            daysOfTheWeek: [(weekday: 6, weekNumber: -1)]
        )
        #expect(rule.rrule == "FREQ=MONTHLY;BYDAY=-1FR")
    }

    @Test("A count end is written as COUNT")
    func countEnd() {
        let rule = RecurrenceDescription(frequency: "daily", occurrenceCount: 10)
        #expect(rule.rrule == "FREQ=DAILY;COUNT=10")
    }

    @Test("A date end is written as UNTIL in UTC basic format")
    func untilEnd() {
        let end = Date(timeIntervalSince1970: 1_789_000_000)  // 2026-09-10T00:26:40Z
        let rule = RecurrenceDescription(frequency: "weekly", endDate: end)
        #expect(rule.rrule == "FREQ=WEEKLY;UNTIL=20260910T002640Z")
    }

    @Test("A count wins over an end date, because EventKit stores only one")
    func countBeatsUntil() {
        let rule = RecurrenceDescription(
            frequency: "daily",
            endDate: Date(timeIntervalSince1970: 1_789_000_000),
            occurrenceCount: 3
        )
        #expect(rule.rrule.contains("COUNT=3"))
        #expect(!rule.rrule.contains("UNTIL"))
    }

    @Test("Every BY- part is emitted in specification order")
    func allParts() {
        let rule = RecurrenceDescription(
            frequency: "yearly",
            interval: 2,
            daysOfTheWeek: [(weekday: 2, weekNumber: 0)],
            daysOfTheMonth: [1, 15],
            daysOfTheYear: [100],
            weeksOfTheYear: [20],
            monthsOfTheYear: [3, 6],
            setPositions: [-1],
            firstDayOfTheWeek: 2
        )
        #expect(
            rule.rrule == "FREQ=YEARLY;INTERVAL=2;BYDAY=MO;BYMONTHDAY=1,15;BYMONTH=3,6"
                + ";BYWEEKNO=20;BYYEARDAY=100;BYSETPOS=-1;WKST=MO"
        )
    }

    @Test("An out-of-range weekday is dropped rather than written as garbage")
    func invalidWeekday() {
        let rule = RecurrenceDescription(
            frequency: "weekly",
            daysOfTheWeek: [(weekday: 9, weekNumber: 0)]
        )
        #expect(rule.rrule == "FREQ=WEEKLY")
        #expect(RecurrenceDescription(frequency: "daily", firstDayOfTheWeek: 0).rrule == "FREQ=DAILY")
    }

    @Test("Simple rules get a readable summary")
    func summaries() {
        #expect(RecurrenceDescription(frequency: "daily").summary == "Every day")
        #expect(RecurrenceDescription(frequency: "weekly", interval: 3).summary == "Every 3 weeks")
        #expect(
            RecurrenceDescription(
                frequency: "weekly",
                daysOfTheWeek: [(weekday: 2, weekNumber: 0), (weekday: 6, weekNumber: 0)]
            ).summary == "Every week on MO, FR"
        )
        #expect(
            RecurrenceDescription(frequency: "daily", occurrenceCount: 5).summary
                == "Every day, 5 times"
        )
    }

    @Test("A rule too intricate to phrase gets no summary rather than a wrong one")
    func noSummaryForComplexRules() {
        #expect(RecurrenceDescription(frequency: "monthly", setPositions: [-1]).summary == nil)
        #expect(
            RecurrenceDescription(
                frequency: "monthly",
                daysOfTheWeek: [(weekday: 6, weekNumber: -1)]
            ).summary == nil
        )
        #expect(RecurrenceDescription(frequency: "hourly").summary == nil)
    }

    @Test("Two rules are equal when they say the same thing")
    func equality() {
        let left = RecurrenceDescription(frequency: "daily", interval: 1)
        let right = RecurrenceDescription(frequency: "DAILY", interval: 1)
        #expect(left == right)
    }
}
