// SPDX-License-Identifier: GPL-3.0-or-later
//
// What time it is where a place is.
//
// Google's Maps platform has a Time Zone API and its MCP servers surface it;
// on a Mac the same answer falls out of a geocode, because `CLPlacemark`
// carries the time zone of the placemark it describes. Apple Core geocoded
// places and threw that field away.
//
// The formatting is here, away from Core Location, because every part of it
// has a case that is easy to get wrong: a negative offset whose minutes are
// still positive, the zones that are not a whole number of hours off UTC
// (India at +05:30, Nepal at +05:45, the Chatham Islands at +12:45), and
// summer time, which is a property of an instant rather than of a zone.

import Foundation

public struct TimeZoneSummary: Equatable, Sendable {
    public let identifier: String
    /// The zone's short name at the given instant, such as "EDT".
    public let abbreviation: String?
    /// Seconds from UTC at that instant, summer time included.
    public let utcOffsetSeconds: Int
    /// The same offset written the way a person reads it: "-04:00".
    public let utcOffsetText: String
    public let isDaylightSavingTime: Bool
    /// How much of the offset is summer time. Zero outside it.
    public let daylightSavingOffsetSeconds: Int
    /// The local wall-clock time there, at the instant asked about.
    public let localTime: String
    /// When the offset next changes, if it ever does.
    public let nextTransition: Date?

    public init(
        identifier: String,
        abbreviation: String?,
        utcOffsetSeconds: Int,
        utcOffsetText: String,
        isDaylightSavingTime: Bool,
        daylightSavingOffsetSeconds: Int,
        localTime: String,
        nextTransition: Date?
    ) {
        self.identifier = identifier
        self.abbreviation = abbreviation
        self.utcOffsetSeconds = utcOffsetSeconds
        self.utcOffsetText = utcOffsetText
        self.isDaylightSavingTime = isDaylightSavingTime
        self.daylightSavingOffsetSeconds = daylightSavingOffsetSeconds
        self.localTime = localTime
        self.nextTransition = nextTransition
    }
}

public enum LocationTimeZone {
    /// Formats a UTC offset as ±HH:MM.
    ///
    /// The sign belongs to the whole offset, not to the hours: -12600 seconds
    /// is -03:30, and formatting the minutes from a negative remainder would
    /// produce "-03:-30".
    public static func offsetText(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    /// Describes a zone at one instant. Everything interesting about a time
    /// zone depends on when you ask.
    public static func describe(_ timeZone: TimeZone, at date: Date) -> TimeZoneSummary {
        let offset = timeZone.secondsFromGMT(for: date)
        let daylight = Int(timeZone.daylightSavingTimeOffset(for: date))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        return TimeZoneSummary(
            identifier: timeZone.identifier,
            abbreviation: timeZone.abbreviation(for: date),
            utcOffsetSeconds: offset,
            utcOffsetText: offsetText(seconds: offset),
            isDaylightSavingTime: timeZone.isDaylightSavingTime(for: date),
            daylightSavingOffsetSeconds: daylight,
            localTime: formatter.string(from: date) + offsetText(seconds: offset),
            nextTransition: timeZone.nextDaylightSavingTimeTransition(after: date)
        )
    }

    /// The difference between a place's clock and this Mac's, in seconds.
    /// Positive means the place is ahead.
    public static func differenceFromLocal(
        _ timeZone: TimeZone,
        localZone: TimeZone,
        at date: Date
    ) -> Int {
        timeZone.secondsFromGMT(for: date) - localZone.secondsFromGMT(for: date)
    }

    /// "3 hours behind this Mac", or "the same time as this Mac".
    public static func describeDifference(seconds: Int) -> String {
        if seconds == 0 { return "the same time as this Mac" }
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        let amount = parts.joined(separator: " ")
        return "\(amount) \(seconds > 0 ? "ahead of" : "behind") this Mac"
    }
}
