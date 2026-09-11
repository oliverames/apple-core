import Foundation
import Testing

@Suite("Map snapshot framing")
struct MapSnapshotFramingTests {
    private static func point(_ latitude: Double, _ longitude: Double) -> MapFramePoint {
        MapFramePoint(latitude: latitude, longitude: longitude)
    }

    @Test("Two points are centred between them, with a margin around the edge")
    func framesTwoPoints() throws {
        let region = try #require(
            MapSnapshotFraming.region(
                containing: [Self.point(44.0, -73.0), Self.point(44.2, -72.6)],
                paddingFraction: 0.25
            )
        )
        #expect(abs(region.centerLatitude - 44.1) < 1e-9)
        #expect(abs(region.centerLongitude - (-72.8)) < 1e-9)
        #expect(abs(region.latitudeDelta - 0.25) < 1e-9)
        #expect(abs(region.longitudeDelta - 0.5) < 1e-9)
    }

    @Test("One point gets an invented span rather than a zero one")
    func framesOnePoint() throws {
        let region = try #require(MapSnapshotFraming.region(containing: [Self.point(44.0, -73.0)]))
        #expect(region.centerLatitude == 44.0)
        #expect(region.centerLongitude == -73.0)
        #expect(region.latitudeDelta == MapSnapshotFraming.singlePointSpanDegrees)
        #expect(region.longitudeDelta == MapSnapshotFraming.singlePointSpanDegrees)
    }

    @Test("Two points either side of the antimeridian frame the short way round")
    func crossesTheAntimeridian() throws {
        // Anchorage at -150 and Tokyo at 140 are 70 degrees apart across the
        // Pacific. Taking max minus min would frame 290 degrees of the globe.
        let region = try #require(
            MapSnapshotFraming.region(
                containing: [Self.point(61.2, -150.0), Self.point(35.7, 140.0)],
                paddingFraction: 0
            )
        )
        #expect(abs(region.longitudeDelta - 70) < 1e-9)
        #expect(abs(region.centerLongitude - 175) < 1e-9)
    }

    @Test("The arc is the complement of the widest gap")
    func smallestArc() {
        let arc = MapSnapshotFraming.smallestArc(containing: [179, -179, 170])
        #expect(abs(arc.width - 11) < 1e-9)
        #expect(abs(arc.center - 175.5) < 1e-9)

        let ordinary = MapSnapshotFraming.smallestArc(containing: [-73.0, -72.0, -74.0])
        #expect(abs(ordinary.width - 2) < 1e-9)
        #expect(abs(ordinary.center - (-73)) < 1e-9)
    }

    @Test("Longitudes normalise into a single turn of the globe")
    func normalises() {
        #expect(MapSnapshotFraming.normalizedLongitude(190) == -170)
        #expect(MapSnapshotFraming.normalizedLongitude(-190) == 170)
        #expect(MapSnapshotFraming.normalizedLongitude(180) == -180)
        #expect(MapSnapshotFraming.normalizedLongitude(-180) == -180)
        #expect(MapSnapshotFraming.normalizedLongitude(0) == 0)
    }

    @Test("Points on one spot still produce a usable span")
    func identicalPoints() throws {
        let region = try #require(
            MapSnapshotFraming.region(
                containing: [Self.point(44.0, -73.0), Self.point(44.0, -73.0)]
            )
        )
        #expect(region.latitudeDelta == MapSnapshotFraming.minimumSpanDegrees)
        #expect(region.longitudeDelta == MapSnapshotFraming.minimumSpanDegrees)
    }

    @Test("Padding never pushes a span past the world")
    func clampsToTheGlobe() throws {
        let region = try #require(
            MapSnapshotFraming.region(
                containing: [Self.point(-89.0, -179.0), Self.point(89.0, 179.0)],
                paddingFraction: 1.0
            )
        )
        #expect(region.latitudeDelta <= 180)
        #expect(region.longitudeDelta <= 360)
        #expect((-90 ... 90).contains(region.centerLatitude))
        #expect((-180 ... 180).contains(region.centerLongitude))
    }

    @Test("Nonsense coordinates are dropped, and nothing left means no region")
    func rejectsInvalidPoints() {
        #expect(MapSnapshotFraming.region(containing: []) == nil)
        #expect(
            MapSnapshotFraming.region(containing: [Self.point(.nan, 0), Self.point(91, 200)]) == nil
        )
        // One good point among bad ones still frames.
        #expect(
            MapSnapshotFraming.region(containing: [Self.point(91, 0), Self.point(44, -73)]) != nil
        )
    }
}

@Suite("Map marker geometry")
struct MapMarkerGeometryTests {
    @Test("The orientation is read off where the region's north edge landed")
    func detectsOrientation() {
        // Top-left space: north is near y = 0.
        #expect(MapMarkerGeometry.isTopLeftOrigin(northEdgeY: 2, height: 1024))
        // Bottom-left space: north is near y = height.
        #expect(!MapMarkerGeometry.isTopLeftOrigin(northEdgeY: 1022, height: 1024))
        // Nonsense is treated as the documented default rather than crashing.
        #expect(MapMarkerGeometry.isTopLeftOrigin(northEdgeY: .nan, height: 1024))
        #expect(MapMarkerGeometry.isTopLeftOrigin(northEdgeY: 5, height: 0))
    }

    @Test("Only a top-left point is flipped into AppKit's space")
    func flipsOnlyWhenNeeded() {
        #expect(MapMarkerGeometry.drawingY(snapshotY: 100, height: 1000, isTopLeftOrigin: true) == 900)
        #expect(MapMarkerGeometry.drawingY(snapshotY: 100, height: 1000, isTopLeftOrigin: false) == 100)
    }

    @Test("A marker off the image is dropped rather than drawn clipped")
    func visibility() {
        #expect(MapMarkerGeometry.isVisible(x: 10, y: 10, width: 100, height: 100, radius: 8))
        #expect(MapMarkerGeometry.isVisible(x: -4, y: 50, width: 100, height: 100, radius: 8))
        #expect(!MapMarkerGeometry.isVisible(x: -40, y: 50, width: 100, height: 100, radius: 8))
        #expect(!MapMarkerGeometry.isVisible(x: 50, y: 140, width: 100, height: 100, radius: 8))
        #expect(!MapMarkerGeometry.isVisible(x: .nan, y: 50, width: 100, height: 100, radius: 8))
    }
}
