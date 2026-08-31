// SPDX-License-Identifier: GPL-3.0-or-later
//
// Client ID Metadata Documents. The identifier is a URL the client chooses and
// this server then fetches, so most of what matters here is refusal: which
// identifiers are rejected before any request is made, which documents are
// rejected after, and which addresses must never be contacted at all.

import Foundation
import Testing

@Suite("Client ID Metadata Documents")
struct ClientIDMetadataTests {
    private static let identifier = "https://claude.ai/oauth/claude-code-client-metadata"

    private static func url(_ raw: String = identifier) throws -> ClientIDMetadataURL {
        try ClientIDMetadataURL(validating: raw)
    }

    private static func document(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Identifier syntax

    @Test("A well-formed identifier is accepted and never normalised")
    func wellFormedIdentifier() throws {
        let parsed = try Self.url()
        #expect(parsed.value == Self.identifier)
        #expect(parsed.host == "claude.ai")
    }

    @Test("An explicit port makes a different identifier")
    func portIsNotNormalised() throws {
        // Simple string comparison, so :443 is a different client. Normalising
        // would let two identifiers collide into one.
        let withPort = try Self.url("https://claude.ai:443/oauth/metadata")
        #expect(withPort.value != "https://claude.ai/oauth/metadata")
    }

    @Test("Anything but https is refused")
    func schemeMustBeHTTPS() {
        #expect(throws: ClientIDMetadataError.notHTTPS) {
            _ = try Self.url("http://claude.ai/oauth/metadata")
        }
    }

    @Test("Credentials in the identifier are refused")
    func userInfoRefused() {
        #expect(throws: ClientIDMetadataError.containsUserInfo) {
            _ = try Self.url("https://user:pw@claude.ai/oauth/metadata")
        }
    }

    @Test("An identifier with no path is refused")
    func pathRequired() {
        #expect(throws: ClientIDMetadataError.missingPath) {
            _ = try Self.url("https://claude.ai")
        }
        #expect(throws: ClientIDMetadataError.missingPath) {
            _ = try Self.url("https://claude.ai/")
        }
    }

    @Test("Dot segments are refused")
    func dotSegmentsRefused() {
        #expect(throws: ClientIDMetadataError.dotSegmentsInPath) {
            _ = try Self.url("https://claude.ai/oauth/../admin/metadata")
        }
    }

    @Test("A fragment is refused")
    func fragmentRefused() {
        #expect(throws: ClientIDMetadataError.containsFragment) {
            _ = try Self.url("https://claude.ai/oauth/metadata#x")
        }
    }

    // MARK: - Document validation

    @Test("Claude Code's own document validates")
    func realWorldDocumentValidates() throws {
        // Copied from https://claude.ai/oauth/claude-code-client-metadata, so
        // a change that breaks the real client breaks this first.
        let data = Self.document([
            "client_id": Self.identifier,
            "client_name": "Claude Code",
            "client_uri": "https://claude.ai",
            "redirect_uris": ["http://localhost/callback", "http://127.0.0.1/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let metadata = try ClientIDMetadata.validated(
            data: data,
            fetchedFrom: try Self.url(),
            redirectURIIsAcceptable: { _ in true }
        )
        #expect(metadata.clientName == "Claude Code")
        #expect(metadata.redirectURIs.count == 2)
    }

    @Test("A document claiming a different client_id is refused")
    func mismatchedClientIDRefused() throws {
        // Without this check anyone could point an authorization request at
        // somebody else's document and inherit their name on the consent page.
        let data = Self.document([
            "client_id": "https://evil.example/other",
            "redirect_uris": ["https://claude.ai/cb"],
        ])
        #expect(throws: (any Error).self) {
            _ = try ClientIDMetadata.validated(
                data: data,
                fetchedFrom: try Self.url(),
                redirectURIIsAcceptable: { _ in true }
            )
        }
    }

    @Test("A document carrying a secret is refused")
    func secretsRefused() throws {
        let data = Self.document([
            "client_id": Self.identifier,
            "redirect_uris": ["https://claude.ai/cb"],
            "client_secret": "hunter2",
        ])
        #expect(throws: ClientIDMetadataError.carriesClientSecret) {
            _ = try ClientIDMetadata.validated(
                data: data,
                fetchedFrom: try Self.url(),
                redirectURIIsAcceptable: { _ in true }
            )
        }
    }

    @Test("Shared-secret authentication is refused")
    func symmetricAuthRefused() throws {
        let data = Self.document([
            "client_id": Self.identifier,
            "redirect_uris": ["https://claude.ai/cb"],
            "token_endpoint_auth_method": "client_secret_basic",
        ])
        #expect(throws: ClientIDMetadataError.symmetricAuthentication("client_secret_basic")) {
            _ = try ClientIDMetadata.validated(
                data: data,
                fetchedFrom: try Self.url(),
                redirectURIIsAcceptable: { _ in true }
            )
        }
    }

    @Test("A document with no acceptable redirect URI is refused")
    func noUsableRedirectRefused() throws {
        let data = Self.document([
            "client_id": Self.identifier,
            "redirect_uris": ["ftp://claude.ai/cb"],
        ])
        #expect(throws: ClientIDMetadataError.noUsableRedirectURI) {
            _ = try ClientIDMetadata.validated(
                data: data,
                fetchedFrom: try Self.url(),
                redirectURIIsAcceptable: { $0.hasPrefix("https://") }
            )
        }
    }

    @Test("A nameless document falls back to its hostname")
    func namelessFallsBackToHost() throws {
        let data = Self.document([
            "client_id": Self.identifier,
            "redirect_uris": ["https://claude.ai/cb"],
        ])
        let metadata = try ClientIDMetadata.validated(
            data: data,
            fetchedFrom: try Self.url(),
            redirectURIIsAcceptable: { _ in true }
        )
        #expect(metadata.clientName == "claude.ai")
    }

    // MARK: - Redirect matching

    @Test("A loopback redirect matches whatever port it came back on")
    func loopbackPortIgnored() {
        // Claude Code registers http://localhost/callback with no port and
        // then listens on a random one, per RFC 8252 section 7.3. Requiring
        // an exact match here is the difference between working and not.
        #expect(
            ClientIDMetadataRedirect.matches(
                requested: "http://localhost:53682/callback",
                registered: ["http://localhost/callback", "http://127.0.0.1/callback"]
            )
        )
        #expect(
            ClientIDMetadataRedirect.matches(
                requested: "http://127.0.0.1:9999/callback",
                registered: ["http://127.0.0.1/callback"]
            )
        )
    }

    @Test("A loopback path still has to match")
    func loopbackPathStillMatters() {
        #expect(
            !ClientIDMetadataRedirect.matches(
                requested: "http://localhost:53682/stolen",
                registered: ["http://localhost/callback"]
            )
        )
    }

    @Test("A non-loopback redirect must match exactly")
    func remoteRedirectExactOnly() {
        #expect(
            ClientIDMetadataRedirect.matches(
                requested: "https://claude.ai/cb",
                registered: ["https://claude.ai/cb"]
            )
        )
        // The port exemption is only for loopback; a public host must not get
        // it, or a redirect could be pointed at another service on that host.
        #expect(
            !ClientIDMetadataRedirect.matches(
                requested: "https://claude.ai:8443/cb",
                registered: ["https://claude.ai/cb"]
            )
        )
    }

    // MARK: - Addresses that must never be fetched

    @Test("Private, loopback and link-local addresses are blocked")
    func specialUseBlocked() {
        for address in [
            "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.1.1",
            "0.0.0.0", "100.64.0.1", "224.0.0.1", "255.255.255.255",
            "::1", "fe80::1", "fc00::1", "ff02::1",
        ] {
            #expect(SpecialUseAddress.isSpecialUse(address), "\(address) must be blocked")
        }
    }

    @Test("An IPv4-mapped IPv6 address is judged as the IPv4 address it holds")
    func mappedAddressesUnwrapped() {
        // ::ffff:127.0.0.1 is loopback wearing a hat, and checking only the
        // IPv6 prefixes would wave it through.
        #expect(SpecialUseAddress.isSpecialUse("::ffff:127.0.0.1"))
        #expect(SpecialUseAddress.isSpecialUse("::ffff:192.168.0.1"))
    }

    @Test("Ordinary public addresses are allowed")
    func publicAddressesAllowed() {
        for address in ["1.1.1.1", "160.79.104.10", "2606:4700::1111"] {
            #expect(!SpecialUseAddress.isSpecialUse(address), "\(address) should be allowed")
        }
    }

    @Test("An address that cannot be parsed is treated as unsafe")
    func unparseableIsBlocked() {
        // Failing open here would turn every parser quirk into a way through.
        #expect(SpecialUseAddress.isSpecialUse("not-an-address"))
    }
}
