import Foundation
import Testing

@Suite("Location freshness, precision and batch geocoding")
struct LocationContractTests {
    @Test("A fix reports its age from its own timestamp")
    func age() {
        let observed = Date(timeIntervalSince1970: 1_000_000)
        let freshness = LocationFreshness.make(
            timestamp: observed,
            horizontalAccuracy: 10,
            verticalAccuracy: 5,
            cached: true,
            now: observed.addingTimeInterval(42)
        )
        #expect(freshness.ageSeconds == 42)
        #expect(freshness.cached)
        #expect(freshness.observedAt == observed)
    }

    @Test("A negative accuracy is absent rather than reported as a very precise fix")
    func invalidAccuracy() {
        let freshness = LocationFreshness.make(
            timestamp: Date(),
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            cached: false
        )
        #expect(freshness.horizontalAccuracyMeters == nil)
        #expect(freshness.verticalAccuracyMeters == nil)
        #expect(freshness.precision == "unknown")
        #expect(freshness.note.contains("no accuracy reported"))
    }

    @Test("Accuracy in metres becomes a word a reader can act on")
    func precisionBands() {
        func precision(_ meters: Double) -> String {
            LocationFreshness.make(
                timestamp: Date(),
                horizontalAccuracy: meters,
                verticalAccuracy: meters,
                cached: false
            ).precision
        }
        #expect(precision(5) == "precise")
        #expect(precision(100) == "approximate")
        #expect(precision(1_500) == "coarse")
        #expect(precision(65_000) == "region")
    }

    @Test("The note says whether the answer came from the cache")
    func cachedNote() {
        let cached = LocationFreshness.make(
            timestamp: Date(),
            horizontalAccuracy: 20,
            verticalAccuracy: 20,
            cached: true
        )
        #expect(cached.note.contains("cached"))
        let fresh = LocationFreshness.make(
            timestamp: Date(),
            horizontalAccuracy: 20,
            verticalAccuracy: 20,
            cached: false
        )
        #expect(!fresh.note.contains("cached"))
    }

    @Test("A batch is bounded and must not be empty")
    func batchBounds() {
        #expect(throws: GeocodeBatchError.noAddresses) {
            try GeocodeBatch.prepare([])
        }
        let tooMany = Array(repeating: "x", count: GeocodeBatch.maximumAddresses + 1)
        #expect(
            throws: GeocodeBatchError.tooManyAddresses(
                requested: tooMany.count,
                limit: GeocodeBatch.maximumAddresses
            )
        ) {
            try GeocodeBatch.prepare(tooMany)
        }
    }

    @Test("A blank entry keeps its place rather than shifting every later index")
    func blankKeepsPosition() throws {
        let prepared = try GeocodeBatch.prepare(["  ", "Montpelier, VT"])
        #expect(prepared.count == 2)
        #expect(prepared[0].isEmpty)
        #expect(prepared[1] == "Montpelier, VT")
        #expect(GeocodeBatch.rejection(for: prepared[0]) != nil)
        #expect(GeocodeBatch.rejection(for: prepared[1]) == nil)
    }

    @Test("The blank-entry error says the device location is never substituted")
    func noSubstitution() {
        #expect(GeocodeBatch.rejection(for: "")?.contains("never substituted") == true)
    }

    @Test("Ambiguity is reported rather than resolved by picking the first")
    func ambiguity() {
        #expect(GeocodeBatch.ambiguityNote(candidateCount: 1) == nil)
        #expect(GeocodeBatch.ambiguityNote(candidateCount: 4)?.contains("4 places") == true)
    }

    @Test("An entry carries its own outcome and index")
    func entryShape() {
        let ok = GeocodeBatchEntry(index: 2, address: "a", error: nil, candidateCount: 3)
        #expect(ok.ok)
        #expect(ok.isAmbiguous)
        let failed = GeocodeBatchEntry(index: 0, address: "b", error: "nope", candidateCount: 0)
        #expect(!failed.ok)
        #expect(!failed.isAmbiguous)
    }
}
