// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// These tests never call MapKit. They cover the two things a client can be
/// hurt by, a stale or malformed identifier and a field Apple Maps did not
/// supply, plus the ambiguity a live lookup can return: an answer carrying a
/// different identifier than the one asked for.
@Suite("Maps place lookup")
struct MapsPlaceLookupTests {
    // MARK: Identifier argument

    @Test("A missing or whitespace identifier is rejected, not passed to MapKit")
    func rejectsEmptyIdentifier() {
        #expect(throws: MapsPlaceLookupError.missingIdentifier) {
            _ = try MapsPlaceIdentifier.normalized(nil)
        }
        #expect(throws: MapsPlaceLookupError.missingIdentifier) {
            _ = try MapsPlaceIdentifier.normalized("")
        }
        #expect(throws: MapsPlaceLookupError.missingIdentifier) {
            _ = try MapsPlaceIdentifier.normalized("   \n ")
        }
    }

    @Test("Surrounding whitespace is trimmed rather than rejected")
    func trimsIdentifier() throws {
        #expect(try MapsPlaceIdentifier.normalized("  I1234ABCD  ") == "I1234ABCD")
    }

    @Test("Interior whitespace and oversized text are malformed")
    func rejectsMalformedIdentifier() {
        #expect(throws: MapsPlaceLookupError.malformedIdentifier("I123 ABCD")) {
            _ = try MapsPlaceIdentifier.normalized("I123 ABCD")
        }
        let oversized = String(repeating: "A", count: MapsPlaceIdentifier.maximumLength + 1)
        #expect(throws: (any Error).self) {
            _ = try MapsPlaceIdentifier.normalized(oversized)
        }
    }

    @Test("A malformed identifier error quotes the value back and does not echo the whole argument")
    func malformedErrorIsBounded() {
        let oversized = String(repeating: "A", count: MapsPlaceIdentifier.maximumLength + 1)
        do {
            _ = try MapsPlaceIdentifier.normalized(oversized)
            Issue.record("Expected an oversized identifier to be rejected")
        } catch let error as MapsPlaceLookupError {
            #expect(error.description.count < oversized.count)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: Stale identifiers

    @Test("A stale identifier reads as stale, and says how to recover")
    func staleIdentifierMessage() {
        let message = MapsPlaceLookupError.unresolvedIdentifier("I0000000").description
        #expect(message.contains("I0000000"))
        #expect(message.lowercased().contains("stale"))
        #expect(message.lowercased().contains("search"))
    }

    @Test("Every lookup error names the identifier argument or its source")
    func errorsPointAtTheArgument() {
        #expect(MapsPlaceLookupError.missingIdentifier.description.contains("@id"))
        #expect(MapsPlaceLookupError.malformedIdentifier("x").description.contains("@id"))
    }

    // MARK: Missing fields

    @Test("Fields Apple Maps did not supply are named, never emitted as empty values")
    func namesUnavailableFields() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I1",
            resolvedIdentifier: "I1",
            hasName: true,
            hasCoordinates: true
        )
        #expect(
            summary.unavailableFields == [
                "address", "telephone", "url", "pointOfInterestCategory", "timeZone",
            ]
        )

        let json = try Self.encoded(summary)
        #expect(json["pointOfInterestCategory"] == nil)
        #expect(json["timeZoneIdentifier"] == nil)
        #expect(json["alternateIdentifiers"] == nil)
        #expect(json["identifierChanged"] == nil)
    }

    @Test("An empty string from MapKit counts as missing, not as a value")
    func treatsEmptyStringsAsMissing() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I1",
            resolvedIdentifier: "I1",
            alternateIdentifiers: ["", "   "],
            pointOfInterestCategory: "",
            timeZoneIdentifier: "  ",
            hasName: true,
            hasAddress: true,
            hasCoordinates: true,
            hasTelephone: true,
            hasURL: true
        )
        #expect(summary.pointOfInterestCategory == nil)
        #expect(summary.timeZoneIdentifier == nil)
        #expect(summary.alternateIdentifiers == nil)
        #expect(summary.unavailableFields == ["pointOfInterestCategory", "timeZone"])
    }

    @Test("A fully populated place reports no unavailable fields at all")
    func omitsUnavailableFieldsWhenComplete() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I1",
            resolvedIdentifier: "I1",
            pointOfInterestCategory: "MKPOICategoryCafe",
            timeZoneIdentifier: "America/New_York",
            hasName: true,
            hasAddress: true,
            hasCoordinates: true,
            hasTelephone: true,
            hasURL: true
        )
        #expect(summary.unavailableFields == nil)
        #expect(try Self.encoded(summary)["unavailableFields"] == nil)
    }

    @Test("A lookup that resolved nothing reports every field as unavailable")
    func reportsEverythingMissing() {
        let summary = MapsPlaceLookupSummary(requestedIdentifier: "I1")
        #expect(summary.unavailableFields == MapsPlaceLookupSummary.reportableFields)
        #expect(summary.resolvedIdentifier == nil)
        #expect(summary.identifierChanged == nil)
    }

    // MARK: Identifier ambiguity

    @Test("An answer carrying a different identifier is flagged, and both are kept")
    func flagsChangedIdentifier() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I_OLD",
            resolvedIdentifier: "I_NEW",
            hasName: true
        )
        #expect(summary.identifierChanged == true)
        #expect(summary.requestedIdentifier == "I_OLD")
        #expect(summary.resolvedIdentifier == "I_NEW")
        #expect(try Self.encoded(summary)["identifierChanged"] != nil)
    }

    @Test("An unchanged identifier omits the flag rather than reporting false")
    func omitsFlagWhenIdentifierIsStable() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I1",
            resolvedIdentifier: "I1",
            hasName: true
        )
        #expect(summary.identifierChanged == nil)
        #expect(try Self.encoded(summary)["identifierChanged"] == nil)
    }

    @Test("Alternates never repeat the requested or resolved identifier, and are sorted")
    func deduplicatesAlternates() {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I_OLD",
            resolvedIdentifier: "I_NEW",
            alternateIdentifiers: ["I_NEW", "I_OLD", "I_C", "I_A", "I_A"],
            hasName: true
        )
        #expect(summary.alternateIdentifiers == ["I_A", "I_C"])
    }

    @Test("A summary survives a JSON round trip unchanged")
    func roundTripsThroughJSON() throws {
        let summary = MapsPlaceLookupSummary(
            requestedIdentifier: "I_OLD",
            resolvedIdentifier: "I_NEW",
            alternateIdentifiers: ["I_A"],
            pointOfInterestCategory: "MKPOICategoryCafe",
            timeZoneIdentifier: "America/New_York",
            hasName: true,
            hasCoordinates: true
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MapsPlaceLookupSummary.self, from: data)
        #expect(decoded == summary)
    }

    // MARK: Helpers

    private static func encoded(_ summary: MapsPlaceLookupSummary) throws -> [String: Any] {
        let data = try JSONEncoder().encode(summary)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
