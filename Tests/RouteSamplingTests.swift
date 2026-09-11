import Foundation
import Testing

@Suite("Sampling a route")
struct RouteSamplingTests {
    private static func point(_ latitude: Double, _ longitude: Double) -> RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    @Test("Distance matches a known separation")
    func measuresDistance() {
        // One degree of latitude is about 111.2 km anywhere on Earth.
        let degree = RouteSampling.distance(from: Self.point(44, -73), to: Self.point(45, -73))
        #expect(abs(degree - 111_195) < 500)

        // Burlington to Montpelier, about 61 km apart in a straight line.
        let vermont = RouteSampling.distance(
            from: Self.point(44.4759, -73.2121),
            to: Self.point(44.2601, -72.5754)
        )
        #expect(abs(vermont - 55_000) < 6_000)

        #expect(RouteSampling.distance(from: Self.point(44, -73), to: Self.point(44, -73)) == 0)
    }

    @Test("Length adds the legs up")
    func measuresLength() {
        let route = [Self.point(44, -73), Self.point(45, -73), Self.point(46, -73)]
        #expect(abs(RouteSampling.length(of: route) - 222_390) < 1_000)
        #expect(RouteSampling.length(of: [Self.point(44, -73)]) == 0)
        #expect(RouteSampling.length(of: []) == 0)
    }

    @Test("Samples are spread by distance travelled, not by how the polyline bends")
    func spreadsByDistance() {
        // Twenty points crowded into the first kilometre, then one point far
        // away. Sampling by index would never look past the crowd.
        var route: [RouteCoordinate] = []
        for step in 0 ..< 20 {
            route.append(Self.point(44.0 + Double(step) * 0.0005, -73.0))
        }
        route.append(Self.point(45.0, -73.0))

        let samples = RouteSampling.samples(along: route, maximum: 3)
        #expect(samples.count == 3)
        #expect(samples[0].distanceAlongRoute == 0)
        // The middle sample is around half the route's length, not halfway
        // through its points.
        let total = RouteSampling.length(of: route)
        #expect(abs(samples[1].distanceAlongRoute - total / 2) < total * 0.1)
        #expect(abs(samples[2].distanceAlongRoute - total) < 1)
    }

    @Test("The ends of the route are always sampled")
    func includesBothEnds() {
        let route = [Self.point(44, -73), Self.point(44.5, -73), Self.point(45, -73)]
        let samples = RouteSampling.samples(along: route, maximum: 2)
        #expect(samples.first?.coordinate == Self.point(44, -73))
        #expect(samples.last?.coordinate == Self.point(45, -73))
    }

    @Test("A route with no length or no points does not produce nonsense")
    func degenerateRoutes() {
        #expect(RouteSampling.samples(along: [], maximum: 5).isEmpty)
        let stationary = RouteSampling.samples(
            along: [Self.point(44, -73), Self.point(44, -73)],
            maximum: 5
        )
        #expect(stationary.count == 1)
        #expect(stationary[0].distanceAlongRoute == 0)
    }

    @Test("A short route does not turn into twenty searches of the same corner")
    func thinsCrowdedSamples() {
        // Eleven metres end to end.
        let route = [Self.point(44, -73), Self.point(44.0001, -73)]
        let samples = RouteSampling.samples(along: route, maximum: 20)
        #expect(samples.count <= 2)
        #expect(Set(samples.map(\.distanceAlongRoute)).count == samples.count)

        // A two-kilometre route at the same request gets a handful, spaced by
        // at least the minimum.
        let longer = [Self.point(44, -73), Self.point(44.018, -73)]
        let spread = RouteSampling.samples(along: longer, maximum: 20)
        #expect(spread.count > 2)
        for (previous, next) in zip(spread, spread.dropFirst()) {
            #expect(
                next.distanceAlongRoute - previous.distanceAlongRoute
                    >= RouteSampling.minimumSampleSpacing - 1
            )
        }
    }

    @Test("A place off the route reports both how far off and how far along")
    func measuresDetour() throws {
        let route = [Self.point(44, -73), Self.point(45, -73), Self.point(46, -73)]
        // Just east of the midpoint of the route.
        let found = try #require(
            RouteSampling.nearestPoint(to: Self.point(45.0, -72.99), on: route)
        )
        #expect(found.distanceFromRoute < 1_000)
        #expect(abs(found.distanceAlongRoute - 111_195) < 1_000)

        #expect(RouteSampling.nearestPoint(to: Self.point(44, -73), on: []) == nil)
    }

    @Test("Sample counts clamp to the documented bounds")
    func clamps() {
        #expect(RouteSampling.clampedSamples(nil) == RouteSampling.defaultMaxSamples)
        #expect(RouteSampling.clampedSamples(3) == 3)
        #expect(RouteSampling.clampedSamples(500) == RouteSampling.maximumMaxSamples)
    }
}
