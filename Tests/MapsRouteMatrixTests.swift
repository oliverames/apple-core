import Foundation
import Testing

@Suite("Route matrix and multi-stop itinerary")
struct MapsRouteMatrixTests {
    private func outcome(
        _ origin: Int,
        _ destination: Int,
        seconds: Int? = 600,
        meters: Int? = 5000,
        error: String? = nil
    ) -> MapsRouteOutcome {
        MapsRouteOutcome(
            originIndex: origin,
            destinationIndex: destination,
            distanceMeters: meters,
            travelSeconds: seconds,
            error: error
        )
    }

    @Test("Pairs are produced in row-major order")
    func pairOrder() throws {
        let pairs = try MapsRouteMatrix.pairs(originCount: 2, destinationCount: 3)
        #expect(pairs.map { [$0.origin, $0.destination] } == [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [1, 2]])
    }

    @Test("The product of the two lists is what is bounded")
    func pairBound() {
        #expect(throws: MapsRouteMatrixError.noOrigins) {
            try MapsRouteMatrix.pairs(originCount: 0, destinationCount: 3)
        }
        #expect(throws: MapsRouteMatrixError.noDestinations) {
            try MapsRouteMatrix.pairs(originCount: 3, destinationCount: 0)
        }
        // 20 x 1 is fine; 6 x 6 is not, even though both lists are shorter.
        #expect(throws: Never.self) {
            try MapsRouteMatrix.pairs(originCount: 20, destinationCount: 1)
        }
        #expect(
            throws: MapsRouteMatrixError.tooManyPairs(
                requested: 36,
                limit: MapsRouteMatrix.maximumPairs
            )
        ) {
            try MapsRouteMatrix.pairs(originCount: 6, destinationCount: 6)
        }
    }

    @Test("Concurrent results are sorted back into request order")
    func ordering() {
        let shuffled = [outcome(1, 1), outcome(0, 2), outcome(0, 0), outcome(1, 0)]
        let ordered = MapsRouteMatrix.ordered(shuffled)
        #expect(ordered.map { [$0.originIndex, $0.destinationIndex] } == [[0, 0], [0, 2], [1, 0], [1, 1]])
    }

    @Test("One failed route does not lose the others, and carries its own status")
    func perRouteStatus() {
        let failed = outcome(0, 1, seconds: nil, meters: nil, error: "No route")
        #expect(failed.status == "error")
        #expect(!failed.ok)
        #expect(outcome(0, 0).status == "ok")
    }

    @Test("The nearest destination skips failures, and is absent when nothing computed")
    func nearest() {
        let outcomes = [
            outcome(0, 0, seconds: 900),
            outcome(0, 1, seconds: 300),
            outcome(1, 0, seconds: nil, meters: nil, error: "No route"),
            outcome(1, 1, seconds: nil, meters: nil, error: "No route"),
        ]
        #expect(MapsRouteMatrix.nearestByTravelTime(outcomes, originCount: 2) == [1, nil])
    }

    @Test("An itinerary is consecutive legs in the order given")
    func legs() throws {
        let legs = try MapsItinerary.legs(stopCount: 4)
        #expect(legs.map { [$0.from, $0.to] } == [[0, 1], [1, 2], [2, 3]])
    }

    @Test("An itinerary needs two stops and is bounded above")
    func legBounds() {
        #expect(throws: MapsRouteMatrixError.tooFewStops) { try MapsItinerary.legs(stopCount: 1) }
        #expect(
            throws: MapsRouteMatrixError.tooManyStops(
                requested: MapsItinerary.maximumStops + 1,
                limit: MapsItinerary.maximumStops
            )
        ) {
            try MapsItinerary.legs(stopCount: MapsItinerary.maximumStops + 1)
        }
    }

    @Test("Totals add the legs that computed and say when they are a floor")
    func totals() {
        let complete = MapsItinerary.totals([
            outcome(0, 1, seconds: 600, meters: 1000), outcome(1, 2, seconds: 300, meters: 500),
        ])
        #expect(complete.travelSeconds == 900)
        #expect(complete.distanceMeters == 1500)
        #expect(!complete.isPartial)

        let partial = MapsItinerary.totals([
            outcome(0, 1, seconds: 600, meters: 1000),
            outcome(1, 2, seconds: nil, meters: nil, error: "No route"),
        ])
        #expect(partial.travelSeconds == 600)
        #expect(partial.isPartial)
        #expect(partial.failedLegCount == 1)
        #expect(partial.computedLegCount == 1)
    }

    @Test("Arrival times include the dwell at each stop")
    func arrivals() {
        let start = Date(timeIntervalSince1970: 0)
        let times = MapsItinerary.arrivals(
            departingAt: start,
            outcomes: [outcome(0, 1, seconds: 600), outcome(1, 2, seconds: 300)],
            dwellSeconds: 900
        )
        #expect(times[0] == start.addingTimeInterval(600))
        #expect(times[1] == start.addingTimeInterval(600 + 900 + 300))
    }

    @Test("Nothing after a failed leg gets a fabricated arrival time")
    func arrivalsStopAtFailure() {
        let start = Date(timeIntervalSince1970: 0)
        let times = MapsItinerary.arrivals(
            departingAt: start,
            outcomes: [
                outcome(0, 1, seconds: nil, meters: nil, error: "No route"),
                outcome(1, 2, seconds: 300),
            ],
            dwellSeconds: 0
        )
        #expect(times == [nil, nil])
    }
}
