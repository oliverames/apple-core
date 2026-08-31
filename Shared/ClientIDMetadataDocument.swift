// SPDX-License-Identifier: GPL-3.0-or-later
//
// Client ID Metadata Documents (draft-ietf-oauth-client-id-metadata-document-02).
//
// The client identifier is an https URL that serves the client's own metadata,
// so a client identifies itself without registering first. That is the fix for
// what dynamic registration does to this app in practice: every reconnection
// of a cloud client created another registration, leaving rows with the same
// name and the same timestamp and no way to tell which was live. A CIMD client
// keeps one identifier for as long as it keeps its URL.
//
// Everything here is pure. The part that touches the network lives in
// ClientIDMetadataFetcher, because the rules worth testing are these: which
// URLs may be fetched at all, what makes a document valid, which redirect URIs
// match, and which addresses must never be contacted.

import Foundation

public enum ClientIDMetadataError: LocalizedError, Equatable {
    case notHTTPS
    case containsUserInfo
    case missingPath
    case dotSegmentsInPath
    case containsFragment
    case malformedURL
    case clientIDMismatch(documentValue: String, requested: String)
    case notJSONObject
    case carriesClientSecret
    case symmetricAuthentication(String)
    case noUsableRedirectURI
    case documentTooLarge(bytes: Int, limit: Int)
    case unexpectedStatus(Int)
    case redirected(to: String)
    case blockedAddress(host: String, address: String)
    case unresolvableHost(String)

    public var errorDescription: String? {
        switch self {
        case .notHTTPS:
            return "A client identifier URL must use https."
        case .containsUserInfo:
            return "A client identifier URL must not carry a username or password."
        case .missingPath:
            return "A client identifier URL must contain a path."
        case .dotSegmentsInPath:
            return "A client identifier URL must not contain . or .. path segments."
        case .containsFragment:
            return "A client identifier URL must not contain a fragment."
        case .malformedURL:
            return "That client identifier is not a URL."
        case let .clientIDMismatch(documentValue, requested):
            return
                "The document at \(requested) claims to be \(documentValue), so it does not describe this client."
        case .notJSONObject:
            return "A client metadata document must be a JSON object."
        case .carriesClientSecret:
            return
                "A client metadata document must not carry a client secret; the document is public."
        case let .symmetricAuthentication(method):
            return
                "\(method) relies on a shared secret, which a public metadata document cannot hold."
        case .noUsableRedirectURI:
            return "The client metadata document lists no redirect URI Apple Core will accept."
        case let .documentTooLarge(bytes, limit):
            return "The client metadata document is larger than \(limit) bytes (\(bytes))."
        case let .unexpectedStatus(code):
            return "Fetching the client metadata document returned \(code) rather than 200."
        case let .redirected(location):
            return
                "The client metadata document redirected to \(location). Redirects are not followed, because the identifier must be the document's own location."
        case let .blockedAddress(host, address):
            return
                "\(host) resolves to \(address), which is a special-use address. Apple Core will not fetch client metadata from inside its own network."
        case let .unresolvableHost(host):
            return "\(host) could not be resolved."
        }
    }
}

/// A client identifier URL that has passed the syntactic rules.
public struct ClientIDMetadataURL: Sendable, Equatable {
    /// The identifier exactly as given. Never normalised: the draft requires
    /// simple string comparison, so `https://a.example/c` and
    /// `https://a.example:443/c` are different clients.
    public let value: String
    public let host: String

    /// Validates the identifier without touching the network.
    ///
    /// Rules from section 3: https only, no userinfo, a path is required, no
    /// dot segments, and no fragment. A query is discouraged rather than
    /// forbidden, so it is allowed here.
    public init(validating raw: String) throws {
        guard let components = URLComponents(string: raw), let host = components.host,
            !host.isEmpty
        else {
            throw ClientIDMetadataError.malformedURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ClientIDMetadataError.notHTTPS
        }
        guard components.user == nil, components.password == nil else {
            throw ClientIDMetadataError.containsUserInfo
        }
        guard components.fragment == nil else {
            throw ClientIDMetadataError.containsFragment
        }
        guard !components.path.isEmpty, components.path != "/" else {
            throw ClientIDMetadataError.missingPath
        }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ClientIDMetadataError.dotSegmentsInPath
        }
        self.value = raw
        self.host = host
    }

    /// Whether a string is even worth treating as a CIMD identifier.
    ///
    /// Used to pick a branch, not to authorise anything: an identifier that
    /// looks like a URL still has to pass `init(validating:)`.
    public static func looksLikeClientIDMetadataURL(_ raw: String) -> Bool {
        raw.lowercased().hasPrefix("https://")
    }
}

/// A client metadata document that has been fetched and checked.
public struct ClientIDMetadata: Sendable, Equatable {
    public let clientID: String
    public let clientName: String
    public let redirectURIs: [String]
    public let clientURI: String?

    /// Parses and validates a document against the identifier it was fetched
    /// from.
    ///
    /// The identity check is the load-bearing one: without it, anyone could
    /// point an authorization request at somebody else's document and inherit
    /// their name and redirect URIs on the consent screen.
    public static func validated(
        data: Data,
        fetchedFrom identifier: ClientIDMetadataURL,
        redirectURIIsAcceptable: (String) -> Bool
    ) throws -> ClientIDMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientIDMetadataError.notJSONObject
        }

        let declared = object["client_id"] as? String ?? ""
        // Simple string comparison, per section 4. No normalisation, because
        // normalising here would let two different identifiers collide.
        guard declared == identifier.value else {
            throw ClientIDMetadataError.clientIDMismatch(
                documentValue: declared,
                requested: identifier.value
            )
        }

        // The document is public, so anything secret in it is either a
        // mistake or bait.
        guard object["client_secret"] == nil, object["client_secret_expires_at"] == nil else {
            throw ClientIDMetadataError.carriesClientSecret
        }
        if let method = object["token_endpoint_auth_method"] as? String,
            ["client_secret_post", "client_secret_basic", "client_secret_jwt"].contains(method)
        {
            throw ClientIDMetadataError.symmetricAuthentication(method)
        }

        let redirectURIs = (object["redirect_uris"] as? [String] ?? [])
            .filter(redirectURIIsAcceptable)
        guard !redirectURIs.isEmpty else {
            throw ClientIDMetadataError.noUsableRedirectURI
        }

        let name = (object["client_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ClientIDMetadata(
            clientID: identifier.value,
            // Falling back to the host rather than a generic label: the
            // consent screen should say where this client comes from, and the
            // hostname is the part a person can actually judge.
            clientName: (name?.isEmpty == false ? name! : identifier.host),
            redirectURIs: redirectURIs,
            clientURI: object["client_uri"] as? String
        )
    }
}

public enum ClientIDMetadataRedirect {
    /// Matches a requested redirect URI against the registered list.
    ///
    /// Exact string comparison, with one exception required by RFC 8252
    /// section 7.3: a native client listening on the loopback interface picks
    /// its port at runtime and cannot know it in advance, so the port is
    /// ignored for loopback URIs. Claude Code's own document registers
    /// `http://localhost/callback` with no port at all, and rejecting the
    /// port it actually listens on is the difference between this working and
    /// not.
    public static func matches(requested: String, registered: [String]) -> Bool {
        if registered.contains(requested) { return true }
        guard let wanted = URLComponents(string: requested), isLoopback(wanted) else {
            return false
        }
        return registered.contains { candidate in
            guard let known = URLComponents(string: candidate), isLoopback(known) else {
                return false
            }
            return known.scheme?.lowercased() == wanted.scheme?.lowercased()
                && known.host?.lowercased() == wanted.host?.lowercased()
                && known.path == wanted.path
        }
    }

    private static func isLoopback(_ components: URLComponents) -> Bool {
        guard components.scheme?.lowercased() == "http" else { return false }
        switch components.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }
}

/// Addresses a client metadata document may never be fetched from.
///
/// Section 8.1: an authorization server must not fetch a document whose host
/// resolves to a special-use address. This one runs on somebody's Mac, on the
/// same network as their router, printers and whatever else answers on a
/// private address, so an unchecked fetch of a client-supplied URL is a
/// request forgery primitive pointed straight at their LAN.
public enum SpecialUseAddress {
    public static func isSpecialUse(_ address: String) -> Bool {
        if let v4 = parseIPv4(address) {
            return isSpecialUseIPv4(v4)
        }
        if let v6 = parseIPv6(address) {
            // An IPv4-mapped address is an IPv4 address wearing a hat, and
            // must be judged as one.
            if v6.prefix(10).allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
                return isSpecialUseIPv4(Array(v6[12...]))
            }
            return isSpecialUseIPv6(v6)
        }
        // Unparseable is not provably safe.
        return true
    }

    static func isSpecialUseIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _): return true  // 0.0.0.0/8 "this network"
        case (10, _): return true  // private
        case (100, 64 ... 127): return true  // 100.64/10 carrier NAT
        case (127, _): return true  // loopback
        case (169, 254): return true  // link-local
        case (172, 16 ... 31): return true  // private
        case (192, 0) where b[2] == 0 || b[2] == 2: return true  // protocol assignment, TEST-NET-1
        case (192, 88) where b[2] == 99: return true  // 6to4 relay
        case (192, 168): return true  // private
        case (198, 18 ... 19): return true  // benchmarking
        case (198, 51) where b[2] == 100: return true  // TEST-NET-2
        case (203, 0) where b[2] == 113: return true  // TEST-NET-3
        case (224 ... 255, _): return true  // multicast, reserved, broadcast
        default: return false
        }
    }

    static func isSpecialUseIPv6(_ b: [UInt8]) -> Bool {
        if b.allSatisfy({ $0 == 0 }) { return true }  // ::
        if b.prefix(15).allSatisfy({ $0 == 0 }), b[15] == 1 { return true }  // ::1
        if b[0] & 0xFE == 0xFC { return true }  // fc00::/7 unique local
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }  // fe80::/10 link-local
        if b[0] == 0xFF { return true }  // ff00::/8 multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return true }  // 2001:db8::/32
        if b[0] == 0x20, b[1] == 0x01, b[2] & 0xFE == 0x00 { return true }  // 2001::/23
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B { return true }  // 64:ff9b::/96
        if b[0] == 0x01, b.dropFirst().prefix(7).allSatisfy({ $0 == 0 }) { return true }  // 100::/64
        return false
    }

    static func parseIPv4(_ text: String) -> [UInt8]? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        let raw = addr.s_addr.bigEndian
        return [
            UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF),
        ]
    }

    static func parseIPv6(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        let stripped =
            text.hasPrefix("[") && text.hasSuffix("]")
            ? String(text.dropFirst().dropLast()) : text
        guard stripped.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}
