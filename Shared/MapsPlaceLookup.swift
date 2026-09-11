// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure logic for looking a place up again by its Apple Maps Place ID.
//
// Nothing here touches MapKit. The service layer validates the client's
// identifier through `MapsPlaceIdentifier`, asks MapKit for the place, and
// hands the result back here to be reconciled and described. That keeps the
// two parts a client can actually be hurt by, a stale identifier and a field
// MapKit did not supply, testable without a network round trip.
//
// Two rules shape the file. A field Apple Maps did not supply is named in
// `unavailableFields` rather than emitted as an empty string, because an empty
// telephone reads as "this place has no phone" when it means "Apple Maps did
// not say". And a lookup that resolves to a different identifier than the one
// asked for says so, because Apple Maps may answer with a canonical ID for the
// same place and a client storing the old one needs to know it has moved.

import Foundation

// MARK: - Errors

/// Why a place lookup could not be answered. Each case carries the text the
/// client sees, because a lookup failure is usually the client's stored
/// identifier going stale rather than a bug it can retry through.
public enum MapsPlaceLookupError: Error, Equatable, CustomStringConvertible {
    /// No identifier argument, or only whitespace.
    case missingIdentifier
    /// The string is not a well formed Apple Maps Place ID.
    case malformedIdentifier(String)
    /// Apple Maps has no place for this identifier any more.
    case unresolvedIdentifier(String)

    public var description: String {
        switch self {
        case .missingIdentifier:
            return
                "identifier is required. Use the \"@id\" value from a maps_search or maps_explore result."
        case .malformedIdentifier(let raw):
            return
                "\"\(raw)\" is not a valid Apple Maps place identifier. Use the \"@id\" value from a maps_search or maps_explore result."
        case .unresolvedIdentifier(let raw):
            return
                "Apple Maps could not resolve place identifier \"\(raw)\". The identifier may be stale: Apple Maps drops identifiers for places that have closed or no longer exist. Search for the place again to get a current identifier."
        }
    }

    public var localizedDescription: String { description }
}

// MARK: - Identifier argument

/// Validation of the identifier a client sends. Deliberately permissive about
/// the identifier's shape, which is opaque and Apple's to change, and strict
/// about the two things that are always wrong: nothing, and whitespace.
public enum MapsPlaceIdentifier {
    /// Longest identifier accepted. Apple Maps Place IDs are far shorter than
    /// this; the cap exists so a runaway argument fails here rather than inside
    /// MapKit.
    public static let maximumLength = 512

    /// Trims the argument and rejects the empty and oversized cases.
    /// - Throws: ``MapsPlaceLookupError/missingIdentifier`` when there is no
    ///   usable text, ``MapsPlaceLookupError/malformedIdentifier(_:)`` when the
    ///   text cannot be an identifier.
    public static func normalized(_ raw: String?) throws -> String {
        guard let raw else { throw MapsPlaceLookupError.missingIdentifier }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MapsPlaceLookupError.missingIdentifier }
        guard trimmed.count <= maximumLength else {
            throw MapsPlaceLookupError.malformedIdentifier(String(trimmed.prefix(64)))
        }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw MapsPlaceLookupError.malformedIdentifier(trimmed)
        }
        return trimmed
    }
}

// MARK: - Lookup result

/// The part of a place lookup that the schema.org `Place` has nowhere to put:
/// which identifier answered, the alternates that name the same place, and the
/// two MapKit attributes with no `Place` equivalent.
///
/// Every property is optional and omitted when absent, and the names of the
/// absent ones are collected into ``unavailableFields`` so a client can tell
/// "Apple Maps did not supply this" from "this place has none".
public struct MapsPlaceLookupSummary: Codable, Equatable, Sendable {
    /// The identifier the client asked about, after trimming.
    public var requestedIdentifier: String
    /// The identifier Apple Maps answered with, when it supplied one.
    public var resolvedIdentifier: String?
    /// Present and true only when Apple Maps answered with a different
    /// identifier than the one asked for. The requested identifier still
    /// refers to this place, but the resolved one is the current name for it.
    public var identifierChanged: Bool?
    /// Other identifiers Apple Maps reports for the same place, sorted for a
    /// stable response. The resolved and requested identifiers are removed, so
    /// this never repeats what the client already has.
    public var alternateIdentifiers: [String]?
    /// MapKit's point of interest category, such as `MKPOICategoryCafe`.
    public var pointOfInterestCategory: String?
    /// IANA time zone identifier for the place, such as `America/New_York`.
    public var timeZoneIdentifier: String?
    /// Supported fields Apple Maps did not supply for this place.
    public var unavailableFields: [String]?

    /// Field names in the order they are reported, matching the JSON keys the
    /// client sees on the `place` object and on this summary.
    public static let reportableFields = [
        "name", "address", "geo", "telephone", "url", "pointOfInterestCategory", "timeZone",
    ]

    /// Builds a summary from what MapKit returned. Empty strings are treated as
    /// absent throughout: MapKit returns them in place of nil often enough that
    /// passing one through would be a lie about the place.
    public init(
        requestedIdentifier: String,
        resolvedIdentifier: String? = nil,
        alternateIdentifiers: [String] = [],
        pointOfInterestCategory: String? = nil,
        timeZoneIdentifier: String? = nil,
        hasName: Bool = false,
        hasAddress: Bool = false,
        hasCoordinates: Bool = false,
        hasTelephone: Bool = false,
        hasURL: Bool = false
    ) {
        self.requestedIdentifier = requestedIdentifier

        let resolved = Self.presentText(resolvedIdentifier)
        self.resolvedIdentifier = resolved
        if let resolved, resolved != requestedIdentifier {
            self.identifierChanged = true
        } else {
            self.identifierChanged = nil
        }

        let known = Set([requestedIdentifier, resolved].compactMap { $0 })
        let alternates = Set(alternateIdentifiers.compactMap(Self.presentText)).subtracting(known)
        self.alternateIdentifiers = alternates.isEmpty ? nil : alternates.sorted()

        let category = Self.presentText(pointOfInterestCategory)
        self.pointOfInterestCategory = category
        let timeZone = Self.presentText(timeZoneIdentifier)
        self.timeZoneIdentifier = timeZone

        let present: [String: Bool] = [
            "name": hasName,
            "address": hasAddress,
            "geo": hasCoordinates,
            "telephone": hasTelephone,
            "url": hasURL,
            "pointOfInterestCategory": category != nil,
            "timeZone": timeZone != nil,
        ]
        let missing = Self.reportableFields.filter { present[$0] == false }
        self.unavailableFields = missing.isEmpty ? nil : missing
    }

    /// Nil for nil, nil for whitespace, the trimmed text otherwise.
    private static func presentText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case requestedIdentifier, resolvedIdentifier, identifierChanged, alternateIdentifiers
        case pointOfInterestCategory, timeZoneIdentifier, unavailableFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestedIdentifier, forKey: .requestedIdentifier)
        try container.encodeIfPresent(resolvedIdentifier, forKey: .resolvedIdentifier)
        try container.encodeIfPresent(identifierChanged, forKey: .identifierChanged)
        try container.encodeIfPresent(alternateIdentifiers, forKey: .alternateIdentifiers)
        try container.encodeIfPresent(pointOfInterestCategory, forKey: .pointOfInterestCategory)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encodeIfPresent(unavailableFields, forKey: .unavailableFields)
    }
}
