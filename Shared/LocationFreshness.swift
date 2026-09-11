// SPDX-License-Identifier: GPL-3.0-or-later
//
// How old a location is, and how precise.
//
// An audit of what `location_current` actually serialized started this file.
// The tool returns `Ontology.GeoCoordinates`, whose encoder writes exactly
// three things: latitude, longitude and elevation. Nothing about when the fix
// was taken, nothing about how accurate it is, and no way to tell a fix taken
// this second from one the service cached up to a minute ago. A client reading
// that JSON has no way to know whether "you are here" means within ten metres
// or within five kilometres, and no way to know whether "here" was where the
// Mac was a minute ago.
//
// `GeoCoordinates` is a type from an upstream package, and adding fields to it
// is not this app's to do. So the fields are added beside it, on the same
// object, which is also what keeps the change additive: every key the tool
// returned before it still returns, spelled the same way.

import Foundation

public struct LocationFreshness: Equatable, Sendable {
    /// When Core Location says the fix was taken. Not when this call ran.
    public let observedAt: Date
    /// Seconds between the fix and the answer.
    public let ageSeconds: Int
    /// True when the answer came from the fix the service already had rather
    /// than from a reading taken for this call.
    public let cached: Bool
    /// Radius of 68% confidence, in metres. Nil when Core Location reported a
    /// negative accuracy, which is its way of saying the value is invalid —
    /// passing that through as "-1 metres" reads as a very precise fix.
    public let horizontalAccuracyMeters: Double?
    public let verticalAccuracyMeters: Double?

    public init(
        observedAt: Date,
        ageSeconds: Int,
        cached: Bool,
        horizontalAccuracyMeters: Double?,
        verticalAccuracyMeters: Double?
    ) {
        self.observedAt = observedAt
        self.ageSeconds = ageSeconds
        self.cached = cached
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
    }

    /// Plain words for the precision, so a client does not have to decide what
    /// 65,000 metres means. The bands are Core Location's own accuracy
    /// constants: a Wi-Fi fix lands around a hundred metres, and an
    /// IP-derived one comes back in kilometres.
    public var precision: String {
        guard let accuracy = horizontalAccuracyMeters else { return "unknown" }
        switch accuracy {
        case ..<20: return "precise"
        case ..<200: return "approximate"
        case ..<5000: return "coarse"
        default: return "region"
        }
    }

    /// Stated rather than implied. A fix can be minutes old on a Mac that has
    /// not moved, and a client deciding whether to ask again needs the number
    /// and the word.
    public var note: String {
        let accuracyPart =
            horizontalAccuracyMeters.map { "accurate to about \(Int($0.rounded()))m" }
            ?? "with no accuracy reported"
        let agePart = ageSeconds <= 1 ? "taken just now" : "taken \(ageSeconds)s ago"
        return "Location fix \(agePart), \(accuracyPart)\(cached ? ", from the cached fix" : "")."
    }

    public static func make(
        timestamp: Date,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        cached: Bool,
        now: Date = Date()
    ) -> LocationFreshness {
        LocationFreshness(
            observedAt: timestamp,
            ageSeconds: max(0, Int(now.timeIntervalSince(timestamp).rounded())),
            cached: cached,
            // Core Location signals "invalid" with a negative number rather
            // than with nil, and every one of those means "do not trust this".
            horizontalAccuracyMeters: horizontalAccuracy >= 0 ? horizontalAccuracy : nil,
            verticalAccuracyMeters: verticalAccuracy >= 0 ? verticalAccuracy : nil
        )
    }
}
