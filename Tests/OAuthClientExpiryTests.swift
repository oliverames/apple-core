// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

private final class ToggleableWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    private var written: [URL: Data] = [:]

    func failWrites() {
        lock.lock()
        shouldFail = true
        lock.unlock()
    }

    func allowWrites() {
        lock.lock()
        shouldFail = false
        lock.unlock()
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        written[url] = data
    }
}

/// Age-based retention for OAuth client registrations.
///
/// The rule under test is that age alone never removes anything. A row is a
/// candidate only when it is older than the retention window *and* holds no
/// live access token, no live refresh token, and no unredeemed authorization
/// code. Every test here that keeps a client keeps it for one of those
/// reasons.
@Suite("OAuth client expiry")
struct OAuthClientExpiryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let resource = "https://applecore.example.com/mcp"

    private func metadata(_ id: String) -> ClientIDMetadata {
        ClientIDMetadata(
            clientID: "https://client.example/\(id).json",
            clientName: id,
            redirectURIs: ["http://localhost/callback"],
            clientURI: nil
        )
    }

    private func signIn(
        store: OAuthTokenStore,
        client: OAuthRegisteredClient,
        now: Date
    ) async throws -> OAuthTokenPair {
        let verifier = "verifier-\(client.clientID)"
        let code = try #require(
            await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeChallenge: OAuthSupport.pkceS256Challenge(for: verifier),
                resource: resource,
                now: now
            )
        )
        return try #require(
            try await store.redeemAuthorizationCode(
                code: code,
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeVerifier: verifier,
                resource: resource,
                now: now
            )
        )
    }

    @Test("A registration that never signed in is dropped once it passes the retention window")
    func oldNeverSignedInClientExpires() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Abandoned",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )

        let expired = try await store.expireInactiveClients(
            now: registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        )
        #expect(expired.map(\.clientID) == [client.clientID])
        #expect(await store.registeredClients().isEmpty)
    }

    @Test("A registration inside the retention window is kept")
    func recentNeverSignedInClientSurvives() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        _ = try await store.registerClient(
            clientName: "Yesterday",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )

        let expired = try await store.expireInactiveClients(
            now: registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention - 1)
        )
        #expect(expired.isEmpty)
        #expect(await store.registeredClients().count == 1)
    }

    @Test("A signed-in client keeps its registration and its token however old the row is")
    func signedInClientIsNeverExpired() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Working connector",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )
        // Signed in a year after registering, so the row is far older than the
        // retention window while the grant is minutes old.
        let signInAt = registeredAt.addingTimeInterval(365 * day)
        let pair = try await signIn(store: store, client: client, now: signInAt)

        let expired = try await store.expireInactiveClients(now: signInAt.addingTimeInterval(60))
        #expect(expired.isEmpty)
        #expect(await store.registeredClients().count == 1)
        #expect(
            await store.isValidAccessToken(
                pair.accessToken,
                resource: resource,
                now: signInAt.addingTimeInterval(60)
            )
        )
    }

    @Test("A client whose access token lapsed is kept while its refresh token lives")
    func refreshTokenAloneProtectsTheClient() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Idle connector",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )
        let pair = try await signIn(store: store, client: client, now: registeredAt)

        // Twenty days on: the twelve-hour access token is long gone, the
        // thirty-day refresh token is not, and the row is older than nothing
        // yet. Push `now` past the retention window to prove the credential
        // check, not the clock, is what saves it.
        let later = registeredAt.addingTimeInterval(20 * day)
        #expect(!(await store.isValidAccessToken(pair.accessToken, resource: resource, now: later)))
        let expired = try await store.expireInactiveClients(now: later)
        #expect(expired.isEmpty)

        let refreshed = try #require(
            try await store.redeemRefreshToken(pair.refreshToken, clientID: client.clientID, now: later)
        )
        #expect(await store.isValidAccessToken(refreshed.accessToken, resource: resource, now: later))
    }

    @Test("An authorization in flight is not expired out from under the approval page")
    func pendingAuthorizationCodeProtectsTheClient() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Returning connector",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )
        // The user approves long after registering, which is what happens when
        // a client that stopped halfway comes back weeks later.
        let approvedAt = registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + day)
        let verifier = "verifier"
        let code = try #require(
            await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeChallenge: OAuthSupport.pkceS256Challenge(for: verifier),
                resource: resource,
                now: approvedAt
            )
        )

        let expired = try await store.expireInactiveClients(now: approvedAt.addingTimeInterval(30))
        #expect(expired.isEmpty)
        #expect(
            try await store.redeemAuthorizationCode(
                code: code,
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeVerifier: verifier,
                resource: resource,
                now: approvedAt.addingTimeInterval(30)
            ) != nil
        )
    }

    @Test("A client is expired once its authorization code has gone stale unredeemed")
    func lapsedAuthorizationCodeStopsProtecting() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Half-finished",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )
        _ = await store.issueAuthorizationCode(
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
            resource: resource,
            now: registeredAt
        )

        // Authorization codes last five minutes.
        let expired = try await store.expireInactiveClients(
            now: registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        )
        #expect(expired.map(\.clientID) == [client.clientID])
    }

    @Test("Expiry removes only the aged-out rows from a mixed registry")
    func mixedRegistryLosesOnlyStaleRows() async throws {
        let store = OAuthTokenStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let retention = OAuthTokenStore.inactiveClientRetention
        let stale = try await store.registerClient(
            clientName: "Stale",
            redirectURIs: ["http://localhost/callback"],
            now: base
        )
        let alsoStale = try await store.registerClient(
            clientName: "Also stale",
            redirectURIs: ["http://localhost/callback"],
            now: base.addingTimeInterval(day)
        )
        let signedIn = try await store.registerClient(
            clientName: "Signed in",
            redirectURIs: ["http://localhost/callback"],
            now: base.addingTimeInterval(2 * day)
        )
        let recent = try await store.registerClient(
            clientName: "Recent",
            redirectURIs: ["http://localhost/callback"],
            now: base.addingTimeInterval(retention - day)
        )
        // Signing in does not sweep, so the registry still holds all four.
        _ = try await signIn(store: store, client: signedIn, now: base.addingTimeInterval(retention))
        #expect(await store.registeredClients().count == 4)

        let expired = try await store.expireInactiveClients(now: base.addingTimeInterval(retention + 2 * day))
        #expect(Set(expired.map(\.clientID)) == Set([stale.clientID, alsoStale.clientID]))
        #expect(
            Set(await store.registeredClients().map(\.clientID))
                == Set([signedIn.clientID, recent.clientID])
        )
    }

    @Test("Metadata-document clients expire on the same rule as native registrations")
    func metadataClientsExpire() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClientIDMetadataClient(metadata("cloud"), now: registeredAt)

        let expired = try await store.expireInactiveClients(
            now: registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        )
        #expect(expired.map(\.clientID) == [client.clientID])

        // Re-fetching the document restores the row, which is why removing it
        // costs a metadata client nothing.
        _ = try await store.registerClientIDMetadataClient(
            metadata("cloud"),
            now: registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 2)
        )
        #expect(await store.registeredClients().map(\.clientID) == [client.clientID])
    }

    @Test("An expired native client is restored by the next authorization it starts")
    func expiredNativeClientIsAdoptedBack() async throws {
        let store = OAuthTokenStore()
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let client = try await store.registerClient(
            clientName: "Returning",
            redirectURIs: ["http://localhost/callback"],
            now: registeredAt
        )
        let now = registeredAt.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        #expect(try await store.expireInactiveClients(now: now).count == 1)

        let adopted = try #require(
            try await store.adoptClientIfNeeded(
                clientID: client.clientID,
                clientName: "Returning",
                redirectURI: "http://localhost/callback",
                now: now
            )
        )
        #expect(adopted.clientID == client.clientID)
        let pair = try await signIn(store: store, client: adopted, now: now)
        #expect(await store.isValidAccessToken(pair.accessToken, resource: resource, now: now))
    }

    @Test("Expiry survives a restart and a repeated sweep writes nothing more")
    func expiryPersistsAndRepeats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("oauth_clients.json")

        let base = Date(timeIntervalSince1970: 1_000_000)
        let retention = OAuthTokenStore.inactiveClientRetention
        let store = OAuthTokenStore(clientRegistryURL: registryURL)
        _ = try await store.registerClient(
            clientName: "Stale",
            redirectURIs: ["http://localhost/callback"],
            now: base
        )
        let keeper = try await store.registerClient(
            clientName: "Recent",
            redirectURIs: ["http://localhost/callback"],
            now: base.addingTimeInterval(retention - 1)
        )
        let now = base.addingTimeInterval(retention + 1)
        #expect(try await store.expireInactiveClients(now: now).count == 1)
        #expect(try await store.expireInactiveClients(now: now).isEmpty)

        let reopened = OAuthTokenStore(clientRegistryURL: registryURL)
        #expect(await reopened.registeredClients().map(\.clientID) == [keeper.clientID])
    }

    @Test("A sweep that cannot be written leaves every client in place")
    func failedExpiryWriteRollsBack() async throws {
        let writer = ToggleableWriter()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let store = OAuthTokenStore(
            clientRegistryURL: URL(fileURLWithPath: "/unused/oauth_clients.json"),
            persistenceWriter: { try writer.write($0, to: $1) }
        )
        let client = try await store.registerClient(
            clientName: "Stale",
            redirectURIs: ["http://localhost/callback"],
            now: base
        )

        writer.failWrites()
        await #expect(throws: OAuthTokenStoreError.self) {
            _ = try await store.expireInactiveClients(
                now: base.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
            )
        }
        #expect(await store.registeredClients().map(\.clientID) == [client.clientID])

        // The retry after the disk recovers still finds the client to remove.
        writer.allowWrites()
        let expired = try await store.expireInactiveClients(
            now: base.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        )
        #expect(expired.map(\.clientID) == [client.clientID])
    }

    @Test("Registration reclaims aged-out rows instead of reporting a full registry")
    func registrationReclaimsExpiredCapacity() async throws {
        let store = OAuthTokenStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0 ..< 256 {
            _ = try await store.registerClientIDMetadataClient(metadata("client-\(index)"), now: base)
        }
        #expect(await store.registeredClients().count == 256)

        let now = base.addingTimeInterval(OAuthTokenStore.inactiveClientRetention + 1)
        let fresh = try await store.registerClient(
            clientName: "New connector",
            redirectURIs: ["http://localhost/callback"],
            now: now
        )
        #expect(await store.registeredClients().map(\.clientID) == [fresh.clientID])
    }
}
