// SPDX-License-Identifier: GPL-3.0-or-later
//
// Free-slot search over busy intervals.
//
// EventKit has no free/busy API. There is no `predicateForFreeBusy`, no
// availability query, and nothing on `EKEventStore` that answers "when am I
// free" — the only availability vocabulary is `EKEvent.availability` and
// `EKCalendar.supportedEventAvailabilities` (verified against the macOS 27.0
// SDK headers on 2026-09-11). Anything that finds a gap has to compute it from
// the events themselves.
//
// That computation is interval arithmetic over plain dates, which is exactly
// the kind of thing that is wrong in the corners: an event that starts before
// the window, two events that overlap, an all-day event, an event marked free
// that should not block anything. So it lives here, over plain structs, with
// tests — and the Calendar service only has to hand over the busy intervals.

import Foundation

/// One block of time something occupies.
public struct BusyInterval: Sendable, Equatable {
    public let start: Date
    public let end: Date
    /// The event's title, carried through so a caller can be told what a
    /// conflict is rather than only that there is one.
    public let title: String?

    public init(start: Date, end: Date, title: String? = nil) {
        self.start = start
        self.end = end
        self.title = title
    }

    /// Zero-length and reversed intervals occupy nothing.
    public var isEmpty: Bool { end <= start }
}

/// A stretch of time with nothing in it.
public struct FreeSlot: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Which part of each day a search may use.
public struct DayWindow: Sendable, Equatable {
    /// Minutes after local midnight, inclusive.
    public let startMinute: Int
    /// Minutes after local midnight, exclusive.
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Nine to five, the default when a caller asks for working hours without
    /// saying which.
    public static let workingHours = DayWindow(startMinute: 9 * 60, endMinute: 17 * 60)
    /// The whole day, for a search that should not be confined to office hours.
    public static let allDay = DayWindow(startMinute: 0, endMinute: 24 * 60)
}

public enum CalendarAvailability {
    /// Collapses overlapping and touching intervals into the fewest that cover
    /// the same time.
    ///
    /// Without this, two overlapping meetings would each carve their own hole
    /// and the gap between them would be reported as free even though it is
    /// inside both.
    public static func merged(_ intervals: [BusyInterval]) -> [BusyInterval] {
        let sorted = intervals.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [BusyInterval] = []
        for interval in sorted {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                // Overlapping or back to back. Keep the later end; two
                // meetings that touch leave no usable gap between them.
                if interval.end > last.end {
                    merged[merged.count - 1] = BusyInterval(
                        start: last.start,
                        end: interval.end,
                        title: last.title
                    )
                }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// The gaps inside one window that no interval covers.
    public static func gaps(in window: FreeSlot, busy: [BusyInterval]) -> [FreeSlot] {
        guard window.end > window.start else { return [] }
        var slots: [FreeSlot] = []
        var cursor = window.start
        for interval in merged(busy) {
            if interval.end <= cursor { continue }
            if interval.start >= window.end { break }
            if interval.start > cursor {
                slots.append(FreeSlot(start: cursor, end: min(interval.start, window.end)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= window.end { break }
        }
        if cursor < window.end {
            slots.append(FreeSlot(start: cursor, end: window.end))
        }
        return slots
    }

    /// The per-day search windows between two dates.
    ///
    /// Days are walked in the given calendar so that a daylight-saving change
    /// moves the window with the clock rather than shifting it by an hour.
    public static func dailyWindows(
        from start: Date,
        to end: Date,
        window: DayWindow,
        weekdays: Set<Int>?,
        calendar: Foundation.Calendar
    ) -> [FreeSlot] {
        guard end > start else { return [] }
        var windows: [FreeSlot] = []
        var day = calendar.startOfDay(for: start)
        // A window can be empty for a day (a weekend, or a window that sits
        // entirely outside the range), so the loop bound is the day, not the
        // count of results.
        while day < end {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            if let weekdays {
                let weekday = calendar.component(.weekday, from: day)
                guard weekdays.contains(weekday) else { continue }
            }
            guard
                let open = calendar.date(byAdding: .minute, value: window.startMinute, to: day),
                let close = calendar.date(byAdding: .minute, value: window.endMinute, to: day)
            else { continue }
            let clampedStart = max(open, start)
            let clampedEnd = min(close, end)
            if clampedEnd > clampedStart {
                windows.append(FreeSlot(start: clampedStart, end: clampedEnd))
            }
        }
        return windows
    }

    /// Every free slot at least `minimumDuration` long, in order.
    public static func freeSlots(
        from start: Date,
        to end: Date,
        busy: [BusyInterval],
        window: DayWindow = .allDay,
        weekdays: Set<Int>? = nil,
        minimumDuration: TimeInterval = 0,
        calendar: Foundation.Calendar = .current,
        limit: Int = 50
    ) -> [FreeSlot] {
        let collapsed = merged(busy)
        var slots: [FreeSlot] = []
        for day in dailyWindows(
            from: start,
            to: end,
            window: window,
            weekdays: weekdays,
            calendar: calendar
        ) {
            for slot in gaps(in: day, busy: collapsed) where slot.duration >= minimumDuration {
                slots.append(slot)
                if slots.count >= limit { return slots }
            }
        }
        return slots
    }

    /// The busy intervals that overlap a proposed time. Used to answer "is
    /// this slot clear" with what is in the way rather than a bare no.
    public static func conflicts(
        with proposal: FreeSlot,
        busy: [BusyInterval]
    ) -> [BusyInterval] {
        busy.filter { !$0.isEmpty && $0.start < proposal.end && $0.end > proposal.start }
            .sorted { $0.start < $1.start }
    }
}
