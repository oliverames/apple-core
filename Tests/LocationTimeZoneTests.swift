import Foundation
import Testing

@Suite("Location time zones")
struct LocationTimeZoneTests {
    @Test("Offsets format with the sign on the whole offset")
    func formatsOffsets() {
        #expect(LocationTimeZone.offsetText(seconds: 0) == "+00:00")
        #expect(LocationTimeZone.offsetText(seconds: 3600) == "+01:00")
        #expect(LocationTimeZone.offsetText(seconds: -14400) == "-04:00")
        // Half and quarter-hour zones, where minutes are not zero.
        #expect(LocationTimeZone.offsetText(seconds: 19800) == "+05:30")
        #expect(LocationTimeZone.offsetText(seconds: 20700) == "+05:45")
        #expect(LocationTimeZone.offsetText(seconds: 45900) == "+12:45")
        // A negative offset whose minutes are still positive. Formatting the
        // remainder with its own sign would produce "-03:-30".
        #expect(LocationTimeZone.offsetText(seconds: -12600) == "-03:30")
    }

    @Test("Summer time changes the answer for the same zone")
    func summerTime() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let july = Date(timeIntervalSince1970: 1_752_000_000)  // 2025-07-08T20:00:00Z
        let january = Date(timeIntervalSince1970: 1_736_000_000)  // 2025-01-04T14:13:20Z

        let summer = LocationTimeZone.describe(zone, at: july)
        #expect(summer.isDaylightSavingTime)
        #expect(summer.utcOffsetSeconds == -14400)
        #expect(summer.utcOffsetText == "-04:00")
        #expect(summer.daylightSavingOffsetSeconds == 3600)
        #expect(summer.localTime.hasSuffix("-04:00"))

        let winter = LocationTimeZone.describe(zone, at: january)
        #expect(!winter.isDaylightSavingTime)
        #expect(winter.utcOffsetText == "-05:00")
        #expect(winter.daylightSavingOffsetSeconds == 0)
    }

    @Test("Local time is the wall clock there, not UTC restated")
    func localWallClock() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        // 2025-01-04T14:13:20Z is 19:43:20 in Kolkata.
        let summary = LocationTimeZone.describe(zone, at: Date(timeIntervalSince1970: 1_736_000_000))
        #expect(summary.localTime == "2025-01-04T19:43:20+05:30")
        #expect(summary.identifier == "Asia/Kolkata")
    }

    @Test("A zone with no summer time has no next transition")
    func noTransition() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let summary = LocationTimeZone.describe(zone, at: Date(timeIntervalSince1970: 1_736_000_000))
        #expect(summary.nextTransition == nil)
        #expect(summary.utcOffsetSeconds == 0)
    }

    @Test("The difference from this Mac is signed and described in words")
    func differences() throws {
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let january = Date(timeIntervalSince1970: 1_736_000_000)

        let ahead = LocationTimeZone.differenceFromLocal(
            kolkata,
            localZone: newYork,
            at: january
        )
        #expect(ahead == 37800)
        #expect(LocationTimeZone.describeDifference(seconds: ahead) == "10 hours 30 minutes ahead of this Mac")

        let behind = LocationTimeZone.differenceFromLocal(
            newYork,
            localZone: kolkata,
            at: january
        )
        #expect(LocationTimeZone.describeDifference(seconds: behind) == "10 hours 30 minutes behind this Mac")
        #expect(LocationTimeZone.describeDifference(seconds: 0) == "the same time as this Mac")
        #expect(LocationTimeZone.describeDifference(seconds: -3600) == "1 hour behind this Mac")
    }
}
