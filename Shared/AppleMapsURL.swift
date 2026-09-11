// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading a shared Apple Maps link.
//
// People share places as links. "Meet me here" arrives in Messages as a
// maps.apple.com URL, and until now the only thing this app could do with one
// was open it on the Mac. Turning it into coordinates and a name is a small
// thing that closes a real gap between the Messages surface and the Maps one.
//
// The dangerous version of this feature is a tool that fetches a URL. That is
// a general-purpose web client bolted onto a connector, reachable by anything
// that can get a link in front of a model, and usable to probe the user's
// network from inside their house. So:
//
//   * Only Apple Maps hosts, checked against an exact list of host names and
//     never by suffix matching. "maps.apple.com.evil.test" ends in a string
//     that looks right and is not Apple.
//   * Only https.
//   * The parse is offline. Every ordinary Apple Maps link carries its place
//     in its query string, so nothing has to be fetched to read it.
//   * A short link is the one case that needs the network, and even then only
//     to read `Location` headers: at most three hops, every hop re-checked
//     against the same host list, and no response body is ever read.

import Foundation

public enum AppleMapsURLError: LocalizedError, Equatable {
    case notAURL(String)
    case unsupportedScheme(String)
    case unsupportedHost(String)
    case noUsableParameters(String)
    case tooManyRedirects(limit: Int)
    case redirectLeftAppleMaps(String)

    public var errorDescription: String? {
        switch self {
        case let .notAURL(raw):
            return "\(raw) is not a URL."
        case let .unsupportedScheme(scheme):
            return "Apple Core only reads https Apple Maps links, not \(scheme) ones."
        case let .unsupportedHost(host):
            return
                "\(host) is not an Apple Maps address. This tool reads shared Apple Maps links only: \(AppleMapsURL.allowedHosts.sorted().joined(separator: ", ")). It is not a general web fetcher."
        case let .noUsableParameters(url):
            return
                "\(url) is an Apple Maps link with nothing in it to resolve: no coordinates, no search term and no address."
        case let .tooManyRedirects(limit):
            return "That link redirected more than \(limit) times, so it was abandoned."
        case let .redirectLeftAppleMaps(host):
            return "That link redirected to \(host), which is not an Apple Maps address, so it was not followed."
        }
    }
}

public struct AppleMapsLink: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case place
        case search
        case directions
    }

    public let kind: Kind
    public let latitude: Double?
    public let longitude: Double?
    public let query: String?
    public let address: String?
    public let placeIdentifier: String?
    public let origin: String?
    public let destination: String?
    public let transportType: String?
    /// True for a short link whose destination is only known after following
    /// a redirect.
    public let needsRedirect: Bool

    public init(
        kind: Kind,
        latitude: Double? = nil,
        longitude: Double? = nil,
        query: String? = nil,
        address: String? = nil,
        placeIdentifier: String? = nil,
        origin: String? = nil,
        destination: String? = nil,
        transportType: String? = nil,
        needsRedirect: Bool = false
    ) {
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.query = query
        self.address = address
        self.placeIdentifier = placeIdentifier
        self.origin = origin
        self.destination = destination
        self.transportType = transportType
        self.needsRedirect = needsRedirect
    }
}

public enum AppleMapsURL {
    /// Exact host names. Never a suffix test: `maps.apple.com.example.net`
    /// passes a suffix test for ".apple.com" read the wrong way round, and a
    /// prefix test for "maps.apple.com" read the right way round.
    public static let allowedHosts: Set<String> = [
        "maps.apple.com",
        "beta.maps.apple.com",
        "maps.apple",
    ]

    public static let maximumRedirects = 3

    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return allowedHosts.contains(host.lowercased())
    }

    /// Checks scheme and host, and returns the components. Nothing is fetched.
    public static func validate(_ raw: String) throws -> URLComponents {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.host != nil
        else {
            throw AppleMapsURLError.notAURL(raw)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else {
            throw AppleMapsURLError.unsupportedScheme(components.scheme ?? "none")
        }
        guard isAllowedHost(components.host) else {
            throw AppleMapsURLError.unsupportedHost(components.host ?? "none")
        }
        return components
    }

    /// Whether a redirect may be followed, and the hop count it would make.
    public static func checkRedirect(to destination: URL, hop: Int) throws {
        guard hop <= maximumRedirects else {
            throw AppleMapsURLError.tooManyRedirects(limit: maximumRedirects)
        }
        guard destination.scheme?.lowercased() == "https" else {
            throw AppleMapsURLError.unsupportedScheme(destination.scheme ?? "none")
        }
        guard isAllowedHost(destination.host) else {
            throw AppleMapsURLError.redirectLeftAppleMaps(destination.host ?? "none")
        }
    }

    /// Parses a validated Apple Maps link into what it points at.
    public static func parse(_ raw: String) throws -> AppleMapsLink {
        let components = try validate(raw)
        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                // Apple Maps writes an address with plus signs for spaces, and
                // `URLComponents` leaves those alone: without this, an origin
                // comes back as "Burlington,+VT" and geocodes badly or not at
                // all.
                return (item.name.lowercased(), value.replacingOccurrences(of: "+", with: " "))
            },
            uniquingKeysWith: { first, _ in first }
        )

        let coordinates = coordinatePair(items["ll"] ?? items["sll"] ?? items["coordinate"])
        let destination = items["daddr"]
        let origin = items["saddr"]
        let query = items["q"]
        let address = items["address"]
        let placeIdentifier = items["place-id"] ?? items["auid"]

        if destination != nil {
            return AppleMapsLink(
                kind: .directions,
                latitude: coordinates?.latitude,
                longitude: coordinates?.longitude,
                query: query,
                address: address,
                placeIdentifier: placeIdentifier,
                origin: origin,
                destination: destination,
                transportType: transportType(items["dirflg"])
            )
        }

        if coordinates != nil || placeIdentifier != nil || address != nil {
            return AppleMapsLink(
                kind: .place,
                latitude: coordinates?.latitude,
                longitude: coordinates?.longitude,
                query: query,
                address: address,
                placeIdentifier: placeIdentifier
            )
        }

        if let query {
            return AppleMapsLink(kind: .search, query: query)
        }

        // A short link carries its destination nowhere but in the redirect.
        if isShortLinkPath(components.path) {
            return AppleMapsLink(kind: .place, needsRedirect: true)
        }

        throw AppleMapsURLError.noUsableParameters(raw)
    }

    /// `/p/<id>` is the shape Apple's own share sheet produces for a short
    /// link, and a bare host with no query is the other thing that only means
    /// something after a redirect.
    public static func isShortLinkPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return false }
        let parts = trimmed.split(separator: "/")
        return parts.first.map { $0 == "p" || $0 == "s" } ?? false
    }

    /// "44.47,-73.21" as Apple Maps writes it, validated as real coordinates
    /// rather than merely as two numbers.
    public static func coordinatePair(_ raw: String?) -> (latitude: Double, longitude: Double)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
            let latitude = Double(parts[0]),
            let longitude = Double(parts[1]),
            latitude.isFinite, longitude.isFinite,
            (-90 ... 90).contains(latitude),
            (-180 ... 180).contains(longitude)
        else { return nil }
        return (latitude, longitude)
    }

    /// Apple Maps spells the travel mode as a one-letter `dirflg`. Translated
    /// into the words `maps_directions` already uses, so a resolved link can
    /// be handed straight to it.
    public static func transportType(_ dirflg: String?) -> String? {
        switch dirflg?.lowercased() {
        case "d": return "automobile"
        case "w": return "walking"
        case "r": return "transit"
        default: return nil
        }
    }
}
