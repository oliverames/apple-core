// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded batch geocoding.
//
// Geocoding one address at a time is a round trip per address, and a client
// resolving a list of twelve venues pays twelve of them. The batch form is
// worth having, but only with four properties held firmly, because each one is
// a way the batch could quietly lie:
//
//   1. Ordering. Results come back in the order the addresses were given, with
//      the index attached. A reordered batch is worse than no batch: nothing
//      in the payload would reveal the mismatch.
//   2. Ambiguity. "Springfield" matches a dozen places. The batch reports how
//      many candidates there were and returns the alternatives rather than
//      picking one and presenting it as the answer.
//   3. Per-input errors. One address that fails does not fail the call, and
//      the failure is attached to the input that caused it.
//   4. No substitution. An address that cannot be resolved returns an error.
//      It never falls back to the device's own location, which would read as a
//      successful geocode of somewhere the user never asked about — and would
//      leak where the Mac is to a client that only asked about an address.

import Foundation

public enum GeocodeBatchError: LocalizedError, Equatable {
    case noAddresses
    case tooManyAddresses(requested: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .noAddresses:
            return "Pass at least one address to geocode."
        case let .tooManyAddresses(requested, limit):
            return
                "\(requested) addresses is over the \(limit) one call accepts. Split them into batches of \(limit)."
        }
    }
}

/// One address's outcome, always carrying the index it came in at.
public struct GeocodeBatchEntry: Equatable, Sendable {
    public let index: Int
    public let address: String
    public let error: String?
    /// How many placemarks the geocoder returned. Greater than one means the
    /// address was ambiguous and the first result is a choice, not a fact.
    public let candidateCount: Int

    public var ok: Bool { error == nil }
    public var isAmbiguous: Bool { candidateCount > 1 }

    public init(index: Int, address: String, error: String?, candidateCount: Int) {
        self.index = index
        self.address = address
        self.error = error
        self.candidateCount = candidateCount
    }
}

public enum GeocodeBatch {
    public static let maximumAddresses = 25
    /// How many candidates one ambiguous address may return. Ambiguity has to
    /// be visible, but a batch of twenty-five ambiguous addresses returning
    /// everything would be a response nobody can read.
    public static let maximumCandidates = 3
    /// Seconds between requests. `CLGeocoder` is rate limited by Apple and
    /// starts refusing when leaned on; spacing the calls is what keeps a batch
    /// of twenty from failing at the fifth.
    public static let requestInterval: TimeInterval = 0.3

    /// Validates the batch as a whole and trims each address.
    ///
    /// Blank entries are kept, not dropped: dropping one would shift every
    /// later index by one, and the whole contract of this call is that index
    /// `n` of the answer belongs to index `n` of the request. A blank becomes
    /// a per-input error instead.
    public static func prepare(_ addresses: [String]) throws -> [String] {
        guard !addresses.isEmpty else { throw GeocodeBatchError.noAddresses }
        guard addresses.count <= maximumAddresses else {
            throw GeocodeBatchError.tooManyAddresses(
                requested: addresses.count,
                limit: maximumAddresses
            )
        }
        return addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The per-input error for something that was never geocodable, or nil.
    public static func rejection(for address: String) -> String? {
        address.isEmpty
            ? "Empty address. Nothing was geocoded for this entry, and the device's own location is never substituted."
            : nil
    }

    /// A one-line note for an ambiguous result, or nil when there was one
    /// candidate.
    public static func ambiguityNote(candidateCount: Int) -> String? {
        guard candidateCount > 1 else { return nil }
        return
            "\(candidateCount) places match this address. The first is returned as the primary result and the rest are listed as candidates; ask the user which one they meant rather than assuming."
    }
}
