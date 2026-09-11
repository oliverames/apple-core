// SPDX-License-Identifier: GPL-3.0-or-later
//
// Working out which piece of the world a map image should show.
//
// `maps_generate` made the caller supply a centre and both spans in degrees,
// which is a request nobody can answer from what they actually have: a set of
// places. Google's static map API frames a set of markers on its own, and the
// callers who use it never compute a span. This does the same arithmetic
// locally.
//
// Two cases make this more than a min and a max:
//
//   * One point has no extent, so a span has to be invented for it. Zero would
//     be rejected by MapKit, and the map would be meaningless anyway.
//   * Longitude wraps. Anchorage and Tokyo are 30 degrees apart across the
//     antimeridian and 330 degrees apart the other way; taking max minus min
//     frames the entire Pacific and puts both markers off the edges. The
//     smallest arc that contains every point is the complement of the largest
//     gap between adjacent longitudes, which is what this computes.

import Foundation

public struct MapRegionBox: Equatable, Sendable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

public struct MapFramePoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let label: String?

    public init(latitude: Double, longitude: Double, label: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }
}

public enum MapSnapshotFraming {
    /// Degrees of latitude a single point is framed with, roughly a
    /// four-hundred-metre view: close enough to see the building, wide enough
    /// to see which street it is on.
    public static let singlePointSpanDegrees = 0.004
    /// The smallest span a group of points is framed with, so two doors on the
    /// same street do not produce a map zoomed past anything recognisable.
    public static let minimumSpanDegrees = 0.002
    public static let defaultPaddingFraction = 0.25
    public static let maximumPoints = 50

    /// Normalises a longitude into [-180, 180).
    public static func normalizedLongitude(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// The region containing every point, with a margin around it.
    ///
    /// Returns nil when there is nothing to frame; invalid points are the
    /// caller's to reject before getting here.
    public static func region(
        containing points: [MapFramePoint],
        paddingFraction: Double = defaultPaddingFraction
    ) -> MapRegionBox? {
        let usable = points.filter(\.isValid)
        guard !usable.isEmpty else { return nil }

        let latitudes = usable.map(\.latitude)
        let minimumLatitude = latitudes.min() ?? 0
        let maximumLatitude = latitudes.max() ?? 0
        var centerLatitude = (minimumLatitude + maximumLatitude) / 2
        var latitudeDelta = maximumLatitude - minimumLatitude

        let longitudeArc = smallestArc(containing: usable.map { normalizedLongitude($0.longitude) })
        var centerLongitude = longitudeArc.center
        var longitudeDelta = longitudeArc.width

        if usable.count == 1 {
            latitudeDelta = singlePointSpanDegrees
            longitudeDelta = singlePointSpanDegrees
        } else {
            let padding = max(0, paddingFraction)
            latitudeDelta = max(latitudeDelta * (1 + padding), minimumSpanDegrees)
            longitudeDelta = max(longitudeDelta * (1 + padding), minimumSpanDegrees)
        }

        // Padding can push a span past the world. Clamp rather than wrap: a
        // request that wide is asking for the whole map anyway.
        latitudeDelta = min(latitudeDelta, 180)
        longitudeDelta = min(longitudeDelta, 360)
        centerLatitude = min(90, max(-90, centerLatitude))
        centerLongitude = normalizedLongitude(centerLongitude)

        return MapRegionBox(
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    /// The shortest span of longitude containing every value, and its centre.
    ///
    /// Found by sorting the longitudes, taking the largest gap between
    /// neighbours — including the gap that wraps past the antimeridian — and
    /// keeping everything else. That arc is the smallest one that contains all
    /// of them.
    static func smallestArc(containing longitudes: [Double]) -> (center: Double, width: Double) {
        guard let first = longitudes.first else { return (0, 0) }
        guard longitudes.count > 1 else { return (first, 0) }

        let sorted = longitudes.sorted()
        var widestGap = 0.0
        var gapStartIndex = 0
        for index in sorted.indices {
            let next = index == sorted.count - 1 ? sorted[0] + 360 : sorted[index + 1]
            let gap = next - sorted[index]
            if gap > widestGap {
                widestGap = gap
                gapStartIndex = index
            }
        }

        // The arc runs from the value after the widest gap round to the value
        // the gap starts at.
        let arcStart = sorted[(gapStartIndex + 1) % sorted.count]
        let width = 360 - widestGap
        let center = normalizedLongitude(arcStart + width / 2)
        return (center, width)
    }
}

/// Where a marker goes on a rendered map image.
///
/// `MKMapSnapshotter.Snapshot.point(for:)` returns a point in the snapshot
/// image's own coordinate space, and on macOS an `NSImage` is drawn into a
/// bottom-left space. Rather than assume which way round that is — the kind of
/// assumption that produces a map with every marker mirrored about the
/// horizon, and the kind that a screenshot bug in this same codebase already
/// cost once — the orientation is measured from the snapshot itself: the north
/// edge of the region it was asked for lands at the top of the image, whatever
/// the space calls the top.
public enum MapMarkerGeometry {
    /// Decides the snapshot's orientation from where its region's north edge
    /// landed. In a top-left space that is near zero; in a bottom-left space
    /// it is near the image height.
    public static func isTopLeftOrigin(northEdgeY: Double, height: Double) -> Bool {
        guard height > 0, northEdgeY.isFinite else { return true }
        return northEdgeY < height / 2
    }

    /// Converts a snapshot point into the bottom-left space AppKit draws in.
    public static func drawingY(
        snapshotY: Double,
        height: Double,
        isTopLeftOrigin: Bool
    ) -> Double {
        isTopLeftOrigin ? height - snapshotY : snapshotY
    }

    /// True when a marker centred here would actually appear on the image. A
    /// point just off the edge is dropped rather than drawn half off it, so a
    /// caller never sees a marker clipped into an unrecognisable shape.
    public static func isVisible(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double
    ) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        return x >= -radius && y >= -radius && x <= width + radius && y <= height + radius
    }
}
