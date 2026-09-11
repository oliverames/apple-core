// SPDX-License-Identifier: GPL-3.0-or-later
//
// The inverse of the RRULE parser in the Calendar service.
//
// `calendar_events_create` and `calendar_events_update` accept an RRULE and
// build an `EKRecurrenceRule` from it. Nothing read it back: a caller could set
// a repeat and then never see it again, because every read path reported only
// `isRecurring: true`. "It repeats, somehow" is not an answer a caller can act
// on, and it is not enough to reconstruct the rule for an update.
//
// The formatting is pure string work over plain numbers, so it lives here with
// tests rather than inside a live EventKit read. The service fills in a
// `RecurrenceDescription` from an `EKRecurrenceRule` field by field, with no
// interpretation on the way in.
//
// Round-tripping matters: a rule serialized here is fed straight back into the
// parser on the next update, so the two must agree on spelling. The tests
// cover the parts EKRecurrenceRule can represent (RFC 5545 §3.3.10 minus
// BYHOUR, BYMINUTE, BYSECOND and UNTIL-with-time, which EventKit drops).

import Foundation

/// One `EKRecurrenceRule`, flattened to plain values.
///
/// Field names and semantics mirror EventKit exactly, including that
/// `weekNumber == 0` in `daysOfTheWeek` means "every such weekday" rather than
/// a specific ordinal.
public struct RecurrenceDescription: Sendable, Equatable {
    /// "daily", "weekly", "monthly" or "yearly".
    public var frequency: String
    public var interval: Int
    /// `(weekday, weekNumber)`, weekday 1 = Sunday as EventKit numbers them.
    public var daysOfTheWeek: [(weekday: Int, weekNumber: Int)]
    public var daysOfTheMonth: [Int]
    public var daysOfTheYear: [Int]
    public var weeksOfTheYear: [Int]
    public var monthsOfTheYear: [Int]
    public var setPositions: [Int]
    /// EventKit's `firstDayOfTheWeek`; 0 means unset.
    public var firstDayOfTheWeek: Int
    public var endDate: Date?
    /// Zero when the rule ends on a date or never ends.
    public var occurrenceCount: Int

    public init(
        frequency: String,
        interval: Int = 1,
        daysOfTheWeek: [(weekday: Int, weekNumber: Int)] = [],
        daysOfTheMonth: [Int] = [],
        daysOfTheYear: [Int] = [],
        weeksOfTheYear: [Int] = [],
        monthsOfTheYear: [Int] = [],
        setPositions: [Int] = [],
        firstDayOfTheWeek: Int = 0,
        endDate: Date? = nil,
        occurrenceCount: Int = 0
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfTheWeek = daysOfTheWeek
        self.daysOfTheMonth = daysOfTheMonth
        self.daysOfTheYear = daysOfTheYear
        self.weeksOfTheYear = weeksOfTheYear
        self.monthsOfTheYear = monthsOfTheYear
        self.setPositions = setPositions
        self.firstDayOfTheWeek = firstDayOfTheWeek
        self.endDate = endDate
        self.occurrenceCount = occurrenceCount
    }

    public static func == (lhs: RecurrenceDescription, rhs: RecurrenceDescription) -> Bool {
        lhs.rrule == rhs.rrule
    }

    /// RFC 5545 weekday abbreviations, indexed by EventKit's 1-based weekday.
    static let weekdayCodes = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    static func code(forWeekday weekday: Int) -> String? {
        guard (1 ... 7).contains(weekday) else { return nil }
        return weekdayCodes[weekday]
    }

    /// UNTIL is written in UTC with a Z suffix, which is the only form
    /// EventKit's own importer and every calendar server agree on.
    static let untilFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// The rule as an RFC 5545 RRULE value, without the "RRULE:" prefix.
    ///
    /// Parts are emitted in the order the specification lists them, so two
    /// equal rules always produce the same string and a caller can compare
    /// them.
    public var rrule: String {
        var parts: [String] = ["FREQ=\(frequency.uppercased())"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }

        if occurrenceCount > 0 {
            parts.append("COUNT=\(occurrenceCount)")
        } else if let endDate {
            // ISO8601DateFormatter writes "2026-09-11T12:00:00Z"; RRULE wants
            // the basic format with no separators.
            let basic = Self.untilFormatter.string(from: endDate)
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
            parts.append("UNTIL=\(basic)")
        }

        if !daysOfTheWeek.isEmpty {
            let days = daysOfTheWeek.compactMap { day -> String? in
                guard let code = Self.code(forWeekday: day.weekday) else { return nil }
                return day.weekNumber == 0 ? code : "\(day.weekNumber)\(code)"
            }
            if !days.isEmpty { parts.append("BYDAY=\(days.joined(separator: ","))") }
        }
        if !daysOfTheMonth.isEmpty {
            parts.append("BYMONTHDAY=\(daysOfTheMonth.map(String.init).joined(separator: ","))")
        }
        if !monthsOfTheYear.isEmpty {
            parts.append("BYMONTH=\(monthsOfTheYear.map(String.init).joined(separator: ","))")
        }
        if !weeksOfTheYear.isEmpty {
            parts.append("BYWEEKNO=\(weeksOfTheYear.map(String.init).joined(separator: ","))")
        }
        if !daysOfTheYear.isEmpty {
            parts.append("BYYEARDAY=\(daysOfTheYear.map(String.init).joined(separator: ","))")
        }
        if !setPositions.isEmpty {
            parts.append("BYSETPOS=\(setPositions.map(String.init).joined(separator: ","))")
        }
        if let start = Self.code(forWeekday: firstDayOfTheWeek) {
            parts.append("WKST=\(start)")
        }
        return parts.joined(separator: ";")
    }

    /// A one-line phrase for a caller showing the rule to a person. Only the
    /// shapes that have an unambiguous short form get one; anything more
    /// intricate is left to `rrule`, rather than described approximately.
    public var summary: String? {
        guard daysOfTheMonth.isEmpty, daysOfTheYear.isEmpty, weeksOfTheYear.isEmpty,
            setPositions.isEmpty, monthsOfTheYear.isEmpty
        else { return nil }

        let unit: String
        switch frequency.lowercased() {
        case "daily": unit = interval == 1 ? "Every day" : "Every \(interval) days"
        case "weekly": unit = interval == 1 ? "Every week" : "Every \(interval) weeks"
        case "monthly": unit = interval == 1 ? "Every month" : "Every \(interval) months"
        case "yearly": unit = interval == 1 ? "Every year" : "Every \(interval) years"
        default: return nil
        }

        var phrase = unit
        if !daysOfTheWeek.isEmpty, daysOfTheWeek.allSatisfy({ $0.weekNumber == 0 }) {
            let names = daysOfTheWeek.compactMap { Self.code(forWeekday: $0.weekday) }
            if names.count == daysOfTheWeek.count {
                phrase += " on \(names.joined(separator: ", "))"
            }
        } else if !daysOfTheWeek.isEmpty {
            return nil
        }

        if occurrenceCount > 0 {
            phrase += ", \(occurrenceCount) times"
        } else if endDate != nil {
            phrase += ", until a set date"
        }
        return phrase
    }
}
