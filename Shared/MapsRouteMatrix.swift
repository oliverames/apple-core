// SPDX-License-Identifier: GPL-3.0-or-later
//
// Many routes in one call: a matrix of origins against destinations, and a
// fixed-order itinerary through a list of stops.
//
// Both are orchestration over the single-route call MapKit already serves, and
// both are worth having for the same reason: "which of these four suppliers is
// closest to the site" is sixteen round trips through `maps_eta`, and a model
// asking that question sixteen times will get bored, guess, and be wrong.
//
// What this file exists to prevent is the shape those features take when
// nobody bounds them. A matrix is quadratic, so a caller passing two lists of
// twenty asks for four hundred routing requests, which is both slow and a good
// way to be rate limited out of routing altogether. And a partial failure in
// the middle of a matrix must not fail the whole call, because the eleven
// routes that did compute are the answer to the question.
//
// The itinerary is deliberately the simple one: legs in the order given,
// totals first. Reordering the stops to minimise travel is a different feature
// with a different name. It needs an optimisation algorithm and an explicit
// statement of what traffic it assumed, and presenting a reordered list as
// "your itinerary" without either would be a guess wearing a route's clothes.

import Foundation

public enum MapsRouteMatrixError: LocalizedError, Equatable {
    case noOrigins
    case noDestinations
    case tooManyPairs(requested: Int, limit: Int)
    case tooFewStops
    case tooManyStops(requested: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .noOrigins:
            return "Pass at least one origin."
        case .noDestinations:
            return "Pass at least one destination."
        case let .tooManyPairs(requested, limit):
            return
                "\(requested) origin-destination pairs is over the \(limit) one call computes. "
                + "A matrix is the product of the two lists, so \(limit) pairs is, for example, five origins against five destinations. Split the lists."
        case .tooFewStops:
            return "An itinerary needs at least two stops."
        case let .tooManyStops(requested, limit):
            return "\(requested) stops is over the \(limit) one itinerary accepts."
        }
    }
}

/// One computed route, or one route's failure. Always carries the indexes it
/// belongs to: a matrix returned as a flat list with no coordinates on it
/// would be unreadable after the first partial failure.
public struct MapsRouteOutcome: Equatable, Sendable {
    public let originIndex: Int
    public let destinationIndex: Int
    public let distanceMeters: Int?
    public let travelSeconds: Int?
    public let error: String?

    public var ok: Bool { error == nil }
    public var status: String { ok ? "ok" : "error" }

    public init(
        originIndex: Int,
        destinationIndex: Int,
        distanceMeters: Int?,
        travelSeconds: Int?,
        error: String?
    ) {
        self.originIndex = originIndex
        self.destinationIndex = destinationIndex
        self.distanceMeters = distanceMeters
        self.travelSeconds = travelSeconds
        self.error = error
    }
}

public enum MapsRouteMatrix {
    /// Pairs, not points: the cost of a matrix is the product, and bounding
    /// the lists separately lets 20 × 1 through while stopping 5 × 5, which is
    /// backwards.
    public static let maximumPairs = 25
    /// MapKit's routing is a network service with its own rate limiting.
    /// Four at a time is enough to make a matrix feel immediate without
    /// making the throttle the thing that answers.
    public static let maximumConcurrency = 4

    /// Every pair, in row-major order: all destinations for the first origin,
    /// then the second. That is the order a reader expects a matrix in, and it
    /// is the order the results are sorted back into after concurrent work.
    public static func pairs(originCount: Int, destinationCount: Int) throws -> [(origin: Int, destination: Int)] {
        guard originCount > 0 else { throw MapsRouteMatrixError.noOrigins }
        guard destinationCount > 0 else { throw MapsRouteMatrixError.noDestinations }
        let total = originCount * destinationCount
        guard total <= maximumPairs else {
            throw MapsRouteMatrixError.tooManyPairs(requested: total, limit: maximumPairs)
        }
        return (0 ..< originCount).flatMap { origin in
            (0 ..< destinationCount).map { (origin: origin, destination: $0) }
        }
    }

    /// Results sorted back into request order after concurrent computation.
    public static func ordered(_ outcomes: [MapsRouteOutcome]) -> [MapsRouteOutcome] {
        outcomes.sorted {
            ($0.originIndex, $0.destinationIndex) < ($1.originIndex, $1.destinationIndex)
        }
    }

    /// The nearest destination for each origin, by travel time, skipping
    /// failures. Nil entries are origins where nothing computed.
    public static func nearestByTravelTime(_ outcomes: [MapsRouteOutcome], originCount: Int)
        -> [Int?]
    {
        (0 ..< max(0, originCount)).map { origin in
            outcomes
                .filter { $0.originIndex == origin && $0.ok }
                .min { ($0.travelSeconds ?? .max) < ($1.travelSeconds ?? .max) }?
                .destinationIndex
        }
    }
}

public struct MapsItineraryTotals: Equatable, Sendable {
    public let distanceMeters: Int
    public let travelSeconds: Int
    public let legCount: Int
    public let computedLegCount: Int
    public let failedLegCount: Int

    /// True when at least one leg failed, so the totals are a floor rather
    /// than the trip. Stated, because a total that silently omits a leg is
    /// the exact number someone would plan a day around.
    public var isPartial: Bool { failedLegCount > 0 }

    public init(
        distanceMeters: Int,
        travelSeconds: Int,
        legCount: Int,
        computedLegCount: Int,
        failedLegCount: Int
    ) {
        self.distanceMeters = distanceMeters
        self.travelSeconds = travelSeconds
        self.legCount = legCount
        self.computedLegCount = computedLegCount
        self.failedLegCount = failedLegCount
    }
}

public enum MapsItinerary {
    public static let maximumStops = 12

    /// Consecutive pairs through the stops, in the order given. No
    /// reordering: see the note at the top of this file.
    public static func legs(stopCount: Int) throws -> [(from: Int, to: Int)] {
        guard stopCount >= 2 else { throw MapsRouteMatrixError.tooFewStops }
        guard stopCount <= maximumStops else {
            throw MapsRouteMatrixError.tooManyStops(requested: stopCount, limit: maximumStops)
        }
        return (0 ..< stopCount - 1).map { (from: $0, to: $0 + 1) }
    }

    public static func totals(_ outcomes: [MapsRouteOutcome]) -> MapsItineraryTotals {
        let computed = outcomes.filter(\.ok)
        return MapsItineraryTotals(
            distanceMeters: computed.reduce(0) { $0 + ($1.distanceMeters ?? 0) },
            travelSeconds: computed.reduce(0) { $0 + ($1.travelSeconds ?? 0) },
            legCount: outcomes.count,
            computedLegCount: computed.count,
            failedLegCount: outcomes.count - computed.count
        )
    }

    /// Arrival clock times for each stop, given a departure time and an
    /// optional dwell at each intermediate stop. Stops after a failed leg get
    /// no time rather than a fabricated one.
    public static func arrivals(
        departingAt departure: Date,
        outcomes: [MapsRouteOutcome],
        dwellSeconds: Int
    ) -> [Date?] {
        var clock = departure
        var arrivals: [Date?] = []
        var broken = false
        for outcome in outcomes {
            guard !broken, outcome.ok, let seconds = outcome.travelSeconds else {
                broken = true
                arrivals.append(nil)
                continue
            }
            clock = clock.addingTimeInterval(TimeInterval(seconds))
            arrivals.append(clock)
            clock = clock.addingTimeInterval(TimeInterval(max(0, dwellSeconds)))
        }
        return arrivals
    }
}
