// SPDX-License-Identifier: GPL-3.0-or-later
//
// Picking the points along a route to search around.
//
// "Somewhere to eat on the way" is a question every maintained maps server
// answers and Apple Core could not: `maps_directions` returns a route,
// `maps_search` searches a circle, and nothing joined them up. Joining them is
// mostly arithmetic — how long is this route, where along it are the points
// that cover it, and how far off it is this café — which is why the
// arithmetic lives here, where it can be checked against distances somebody
// can verify on a map.
//
// Sampling matters more than it looks. A route polyline has its points
// wherever the road bends: a motorway leg of forty kilometres may be three
// points, and a roundabout may be twenty. Searching at every point would spend
// the whole search budget in the roundabout and never look at the motorway, so
// the samples are spaced by distance travelled rather than by point index.

import Foundation

public struct RouteCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct RouteSample: Equatable, Sendable {
    public let coordinate: RouteCoordinate
    /// Metres from the start of the route.
    public let distanceAlongRoute: Double

    public init(coordinate: RouteCoordinate, distanceAlongRoute: Double) {
        self.coordinate = coordinate
        self.distanceAlongRoute = distanceAlongRoute
    }
}

public enum RouteSampling {
    public static let defaultMaxSamples = 8
    public static let maximumMaxSamples = 20
    /// Samples closer together than this are the same search twice. A short
    /// route asked for twenty samples gets as many as fit, not twenty circles
    /// stacked on one street corner.
    public static let minimumSampleSpacing = 250.0
    public static let earthRadiusMetres = 6_371_000.0

    public static func clampedSamples(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxSamples }
        return min(requested, maximumMaxSamples)
    }

    /// Great-circle distance in metres.
    ///
    /// Haversine rather than the equirectangular approximation: the
    /// approximation is fine over a city and wrong by kilometres over a long
    /// drive, which is exactly the case this is for.
    public static func distance(from first: RouteCoordinate, to second: RouteCoordinate) -> Double {
        let radiansPerDegree = Double.pi / 180
        let firstLatitude = first.latitude * radiansPerDegree
        let secondLatitude = second.latitude * radiansPerDegree
        let deltaLatitude = (second.latitude - first.latitude) * radiansPerDegree
        let deltaLongitude = (second.longitude - first.longitude) * radiansPerDegree

        let a =
            sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(firstLatitude) * cos(secondLatitude) * sin(deltaLongitude / 2)
            * sin(deltaLongitude / 2)
        return 2 * earthRadiusMetres * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Total length of a polyline, in metres.
    public static func length(of route: [RouteCoordinate]) -> Double {
        guard route.count > 1 else { return 0 }
        return zip(route, route.dropFirst()).reduce(0) { total, pair in
            total + distance(from: pair.0, to: pair.1)
        }
    }

    /// Points spread evenly along the route by distance travelled.
    ///
    /// The first and last samples are the ends of the route: a search that
    /// skipped them would miss the café next to the destination, which is the
    /// one the caller is most likely to want.
    ///
    /// A sample that falls between two polyline points is interpolated rather
    /// than snapped to the nearer of them. Snapping sounds harmless and is
    /// not: a motorway leg is often two points forty kilometres apart, and
    /// every sample inside it would collapse onto one end, leaving the middle
    /// of the route unsearched.
    public static func samples(along route: [RouteCoordinate], maximum: Int) -> [RouteSample] {
        guard let first = route.first else { return [] }
        let wanted = max(1, min(maximum, maximumMaxSamples))
        guard route.count > 1, wanted > 1 else {
            return [RouteSample(coordinate: first, distanceAlongRoute: 0)]
        }

        var cumulative: [Double] = [0]
        for (previous, next) in zip(route, route.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + distance(from: previous, to: next))
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else {
            return [RouteSample(coordinate: first, distanceAlongRoute: 0)]
        }

        let step = total / Double(wanted - 1)
        var samples: [RouteSample] = []
        var index = 0
        for position in 0 ..< wanted {
            let target = min(total, Double(position) * step)
            // Walk forward rather than search: the targets increase, so one
            // pass over the polyline serves however many samples are asked for.
            while index < cumulative.count - 2, cumulative[index + 1] < target {
                index += 1
            }
            let segmentStart = cumulative[index]
            let segmentEnd = cumulative[index + 1]
            let segmentLength = segmentEnd - segmentStart
            let fraction =
                segmentLength > 0
                ? min(1, max(0, (target - segmentStart) / segmentLength)) : 0
            let from = route[index]
            let to = route[index + 1]
            samples.append(
                RouteSample(
                    coordinate: RouteCoordinate(
                        latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                        longitude: from.longitude + (to.longitude - from.longitude) * fraction
                    ),
                    distanceAlongRoute: target
                )
            )
        }

        // Thin out samples that would search the same ground twice, keeping
        // the end of the route: the last stretch is the one a caller most
        // often means.
        var kept: [RouteSample] = []
        for sample in samples {
            if let previous = kept.last,
                sample.distanceAlongRoute - previous.distanceAlongRoute < minimumSampleSpacing,
                sample.distanceAlongRoute < total
            {
                continue
            }
            kept.append(sample)
        }
        if kept.count > 1, let last = kept.last, let secondLast = kept.dropLast().last,
            last.distanceAlongRoute - secondLast.distanceAlongRoute < minimumSampleSpacing
        {
            kept.remove(at: kept.count - 2)
        }
        return kept
    }

    /// How far a place is from the route, and how far along the route that is.
    ///
    /// Measured to the nearest polyline point rather than to the nearest point
    /// on the nearest segment. The difference is bounded by how far apart the
    /// route's own points are, and calling it a detour at all is already an
    /// approximation: the real detour is a second routing call, which this
    /// deliberately does not make for every candidate.
    public static func nearestPoint(
        to place: RouteCoordinate,
        on route: [RouteCoordinate]
    ) -> (distanceFromRoute: Double, distanceAlongRoute: Double)? {
        guard !route.isEmpty else { return nil }
        var cumulative = 0.0
        var best = (distanceFromRoute: Double.greatestFiniteMagnitude, distanceAlongRoute: 0.0)
        for (index, point) in route.enumerated() {
            if index > 0 { cumulative += distance(from: route[index - 1], to: point) }
            let offset = distance(from: place, to: point)
            if offset < best.distanceFromRoute {
                best = (offset, cumulative)
            }
        }
        return best
    }
}
