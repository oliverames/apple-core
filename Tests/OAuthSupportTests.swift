import Foundation
import Testing

private final class OAuthPersistenceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

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
        let fail = shouldFail
        lock.unlock()
        if fail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
    }
}

@Suite("OAuth refresh tokens")
struct OAuthSupportTests {
    @Test("Native callbacks require a reverse-domain scheme without an authority")
    func nativeRedirectURIs() {
        for accepted in [
            "https://client.example/callback",
            "http://localhost/callback",
            "http://127.0.0.1:49152/callback",
            "com.oliverames.amesutilities:/mcp-oauth",
        ] {
            #expect(OAuthSupport.isAllowedRedirectURI(accepted), "Expected \(accepted) to be accepted")
        }

        for rejected in [
            "http://client.example/callback",
            "amesutilities:/mcp-oauth",
            "com.oliverames.amesutilities://mcp-oauth",
            "javascript:alert(1)",
            "com.example.app:",
            "com.example.app:/callback#fragment",
        ] {
            #expect(!OAuthSupport.isAllowedRedirectURI(rejected), "Expected \(rejected) to be rejected")
        }
    }

    @Test("Refresh tokens rotate after an access token expires")
    func refreshTokensRotate() async throws {
        let store = OAuthTokenStore()
        let issuedAt = Date(timeIntervalSince1970: 100)
        let resource = "https://applecore.example.com/mcp"
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["https://chatgpt.com/connector/oauth/callback"],
            now: issuedAt
        )
        let code = await store.issueAuthorizationCode(
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
            resource: resource,
            now: issuedAt
        )
        let initial = try await store.redeemAuthorizationCode(
            code: code ?? "",
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeVerifier: "verifier",
            resource: resource,
            now: issuedAt
        )
        let refreshTime = issuedAt.addingTimeInterval(12 * 60 * 60 + 1)
        let rotated = try await store.redeemRefreshToken(
            initial?.refreshToken ?? "",
            clientID: client.clientID,
            resource: resource,
            now: refreshTime
        )

        #expect(initial != nil)
        #expect(rotated != nil)
        #expect(rotated?.accessToken != initial?.accessToken)
        #expect(rotated?.refreshToken != initial?.refreshToken)
        #expect(await store.isValidAccessToken(rotated?.accessToken ?? "", resource: resource, now: refreshTime))
        #expect(
            try await store.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: client.clientID,
                resource: resource,
                now: refreshTime
            ) == nil
        )
    }

    @Test("Refresh tokens persist and stay bound to the client and resource")
    func refreshTokensPersistAndStayBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tokenStoreURL = root.appendingPathComponent("oauth_tokens.json")
        let resource = "https://applecore.example.com/mcp"
        let firstStore = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)
        let client = try await firstStore.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let code = await firstStore.issueAuthorizationCode(
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
            resource: resource
        )
        let initial = try await firstStore.redeemAuthorizationCode(
            code: code ?? "",
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeVerifier: "verifier",
            resource: resource
        )
        let reloadedStore = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)

        #expect(
            try await reloadedStore.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: "wrong-client",
                resource: resource
            ) == nil
        )
        #expect(
            try await reloadedStore.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: client.clientID,
                resource: "https://applecore.example.com/other"
            ) == nil
        )
        #expect(
            try await reloadedStore.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: client.clientID,
                resource: resource
            ) != nil
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: tokenStoreURL.path)
        let permissions = try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o600)
    }

    @Test("Adopted clients respect the persisted registry limit")
    func adoptedClientsRespectPersistenceLimit() async throws {
        struct Registry: Decodable {
            let clients: [OAuthRegisteredClient]
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("oauth_clients.json")
        let store = OAuthTokenStore(clientRegistryURL: registryURL)
        var firstClientID = ""
        for index in 0 ... 256 {
            let clientID = "ames_" + String(format: "%043d", index)
            if index == 0 { firstClientID = clientID }
            _ = try await store.adoptClientIfNeeded(
                clientID: clientID,
                clientName: "Client \(index)",
                redirectURI: "http://localhost/callback",
                now: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let data = try Data(contentsOf: registryURL)
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        #expect(registry.clients.count == 256)
        #expect(!registry.clients.contains { $0.clientID == firstClientID })
    }

    @Test("Duplicate persisted client IDs do not crash startup")
    func duplicatePersistedClientIDsUseLastRecord() async throws {
        struct Registry: Encodable {
            let clients: [OAuthRegisteredClient]
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("oauth_clients.json")
        let clientID = "ames_duplicate-client"
        let registry = Registry(
            clients: [
                OAuthRegisteredClient(
                    clientID: clientID,
                    clientName: "Old name",
                    redirectURIs: ["http://localhost/old"],
                    issuedAt: 1
                ),
                OAuthRegisteredClient(
                    clientID: clientID,
                    clientName: "Current name",
                    redirectURIs: ["http://localhost/current"],
                    issuedAt: 2
                ),
            ]
        )
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)

        let store = OAuthTokenStore(clientRegistryURL: registryURL)
        let loaded = try #require(await store.client(id: clientID))
        #expect(loaded.clientName == "Current name")
        #expect(loaded.redirectURIs == ["http://localhost/current"])
    }

    @Test("OAuth resources must match the advertised audience exactly")
    func canonicalResourceMatching() {
        let canonical = "https://applecore.example.com/mcp"
        #expect(OAuthSupport.isCanonicalResource(canonical, canonicalResource: canonical))

        for alias in [
            "https://applecore.example.com/mcp/",
            "https://applecore.example.com/mcp?source=test",
            "https://applecore.example.com/mcp#fragment",
            "https://applecore.example.com//mcp",
            "HTTPS://applecore.example.com/mcp",
            "https://applecore.example.com:443/mcp",
        ] {
            #expect(!OAuthSupport.isCanonicalResource(alias, canonicalResource: canonical))
        }
    }

    @Test("Revocation follows grant boundaries")
    func revocationFollowsGrantBoundaries() async throws {
        let store = OAuthTokenStore()
        let resource = "https://applecore.example.com/mcp"
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let otherClient = try await store.registerClient(
            clientName: "Other client",
            redirectURIs: ["http://localhost/other"]
        )
        let first = try #require(await issueGrant(store: store, client: client, resource: resource, suffix: "one"))
        let second = try #require(await issueGrant(store: store, client: client, resource: resource, suffix: "two"))
        let other = try #require(
            await issueGrant(store: store, client: otherClient, resource: resource, suffix: "other")
        )

        #expect(!(try await store.revokeToken(first.refreshToken, clientID: otherClient.clientID)))
        #expect(await store.isValidAccessToken(first.accessToken, resource: resource))

        #expect(
            try await store.revokeToken(
                first.refreshToken,
                clientID: client.clientID,
                tokenTypeHint: "refresh_token"
            )
        )
        #expect(!(await store.isValidAccessToken(first.accessToken, resource: resource)))
        #expect(
            try await store.redeemRefreshToken(
                first.refreshToken,
                clientID: client.clientID,
                resource: resource
            ) == nil
        )
        #expect(await store.isValidAccessToken(second.accessToken, resource: resource))
        #expect(await store.isValidAccessToken(other.accessToken, resource: resource))

        #expect(
            try await store.revokeToken(
                second.accessToken,
                clientID: client.clientID,
                tokenTypeHint: "access_token"
            )
        )
        #expect(!(await store.isValidAccessToken(second.accessToken, resource: resource)))
        #expect(
            try await store.redeemRefreshToken(
                second.refreshToken,
                clientID: client.clientID,
                resource: resource
            ) != nil
        )
    }

    @Test("Removing a client persists and revokes its credentials")
    func removingClientRevokesCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("oauth_clients.json")
        let tokenStoreURL = root.appendingPathComponent("oauth_tokens.json")
        let resource = "https://applecore.example.com/mcp"
        let store = OAuthTokenStore(clientRegistryURL: registryURL, accessTokenStoreURL: tokenStoreURL)
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let pair = try #require(await issueGrant(store: store, client: client, resource: resource, suffix: "remove"))

        #expect(try await store.removeClient(id: client.clientID))

        let reloaded = OAuthTokenStore(clientRegistryURL: registryURL, accessTokenStoreURL: tokenStoreURL)
        #expect(await reloaded.client(id: client.clientID) == nil)
        #expect(!(await reloaded.isValidAccessToken(pair.accessToken, resource: resource)))
        #expect(
            try await reloaded.redeemRefreshToken(
                pair.refreshToken,
                clientID: client.clientID,
                resource: resource
            ) == nil
        )
    }

    @Test("Legacy access tokens without client identity are ignored")
    func legacyUnownedAccessTokensAreIgnored() async throws {
        struct LegacyToken: Encodable {
            let token: String
            let resource: String
            let expiresAt: Date
        }
        struct LegacyStore: Encodable {
            let tokens: [LegacyToken]
            let refreshTokens: [LegacyToken]
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tokenStoreURL = root.appendingPathComponent("oauth_tokens.json")
        let resource = "https://applecore.example.com/mcp"
        let persisted = LegacyStore(
            tokens: [
                LegacyToken(
                    token: "legacy-access-token",
                    resource: resource,
                    expiresAt: Date().addingTimeInterval(3600)
                )
            ],
            refreshTokens: []
        )
        try JSONEncoder().encode(persisted).write(to: tokenStoreURL, options: .atomic)

        let store = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)
        #expect(!(await store.isValidAccessToken("legacy-access-token", resource: resource)))
    }

    @Test("A failed revocation write keeps the live and persisted token valid")
    func failedRevocationWriteRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent("oauth_clients.json")
        let tokenStoreURL = root.appendingPathComponent("oauth_tokens.json")
        let resource = "https://applecore.example.com/mcp"
        let writer = OAuthPersistenceWriter()
        let store = OAuthTokenStore(
            clientRegistryURL: registryURL,
            accessTokenStoreURL: tokenStoreURL,
            persistenceWriter: { try writer.write($0, to: $1) }
        )
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let pair = try #require(await issueGrant(store: store, client: client, resource: resource, suffix: "failure"))
        writer.failWrites()

        var persistenceFailed = false
        do {
            _ = try await store.revokeToken(
                pair.refreshToken,
                clientID: client.clientID,
                tokenTypeHint: "refresh_token"
            )
        } catch is OAuthTokenStoreError {
            persistenceFailed = true
        }

        #expect(persistenceFailed)
        #expect(await store.isValidAccessToken(pair.accessToken, resource: resource))

        let reloaded = OAuthTokenStore(clientRegistryURL: registryURL, accessTokenStoreURL: tokenStoreURL)
        #expect(await reloaded.isValidAccessToken(pair.accessToken, resource: resource))
    }

    @Test("Persistence errors before the candidate write use the store error")
    func prewritePersistenceErrorsAreNormalized() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let store = OAuthTokenStore(
            clientRegistryURL: blocker.appendingPathComponent("oauth_clients.json")
        )

        var normalizedError = false
        do {
            _ = try await store.registerClient(
                clientName: "ChatGPT",
                redirectURIs: ["http://localhost/callback"]
            )
        } catch is OAuthTokenStoreError {
            normalizedError = true
        }

        #expect(normalizedError)
        #expect(await store.registeredClients().isEmpty)
    }

    @Test("An expired token is unknown even when cleanup cannot persist")
    func expiredTokenDoesNotRequireRevocationWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = OAuthPersistenceWriter()
        let store = OAuthTokenStore(
            accessTokenStoreURL: root.appendingPathComponent("oauth_tokens.json"),
            persistenceWriter: { try writer.write($0, to: $1) }
        )
        let issuedAt = Date(timeIntervalSince1970: 100)
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"],
            now: issuedAt
        )
        let resource = "https://applecore.example.com/mcp"
        let pair = try #require(
            await issueGrant(
                store: store,
                client: client,
                resource: resource,
                suffix: "expired",
                now: issuedAt
            )
        )
        writer.failWrites()

        let revoked = try await store.revokeToken(
            pair.refreshToken,
            clientID: client.clientID,
            now: issuedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        #expect(!revoked)
    }

    @Test("Failed client registration does not remain live")
    func failedRegistrationRollsBack() async throws {
        let writer = OAuthPersistenceWriter()
        writer.failWrites()
        let store = OAuthTokenStore(
            clientRegistryURL: URL(fileURLWithPath: "/unused/oauth_clients.json"),
            persistenceWriter: { try writer.write($0, to: $1) }
        )

        await #expect(throws: OAuthTokenStoreError.self) {
            _ = try await store.registerClient(
                clientName: "Unpersisted client",
                redirectURIs: ["http://localhost/callback"]
            )
        }
        #expect(await store.registeredClients().isEmpty)
    }

    @Test("Failed token rotation can be retried with the original refresh token")
    func failedRefreshRotationRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = OAuthPersistenceWriter()
        let store = OAuthTokenStore(
            accessTokenStoreURL: root.appendingPathComponent("oauth_tokens.json"),
            persistenceWriter: { try writer.write($0, to: $1) }
        )
        let client = try await store.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let resource = "https://applecore.example.com/mcp"
        let pair = try #require(
            try await issueGrant(store: store, client: client, resource: resource, suffix: "rotation")
        )
        writer.failWrites()

        await #expect(throws: OAuthTokenStoreError.self) {
            _ = try await store.redeemRefreshToken(
                pair.refreshToken,
                clientID: client.clientID,
                resource: resource
            )
        }

        writer.allowWrites()
        #expect(
            try await store.redeemRefreshToken(
                pair.refreshToken,
                clientID: client.clientID,
                resource: resource
            ) != nil
        )
    }

    @Test("Disconnect generations reject overlapping token and session work")
    func disconnectGateRejectsStaleWork() throws {
        let clientID = "ames_client"
        var gate = OAuthClientOperationGate()
        let originalSessionGeneration = try #require(gate.sessionGeneration(for: clientID))
        let beforeDisconnect = gate.tokenIssuanceSnapshot(for: clientID)

        gate.beginDisconnect(for: clientID)
        let duringDisconnect = gate.tokenIssuanceSnapshot(for: clientID)
        gate.beginDisconnect(for: clientID)
        gate.finishDisconnect(for: clientID)

        #expect(gate.isBlocked(clientID))
        #expect(!gate.permitsSession(for: clientID, generation: originalSessionGeneration))
        let acceptedPreDisconnectToken = gate.acceptTokenIssuance(
            for: clientID,
            snapshot: beforeDisconnect
        )
        #expect(!acceptedPreDisconnectToken)

        gate.finishDisconnect(for: clientID)
        let acceptedDuringDisconnectToken = gate.acceptTokenIssuance(
            for: clientID,
            snapshot: duringDisconnect
        )
        #expect(!acceptedDuringDisconnectToken)

        let afterDisconnect = gate.tokenIssuanceSnapshot(for: clientID)
        let acceptedFreshToken = gate.acceptTokenIssuance(for: clientID, snapshot: afterDisconnect)
        #expect(acceptedFreshToken)
        #expect(!gate.isBlocked(clientID))
        #expect(!gate.permitsSession(for: clientID, generation: originalSessionGeneration))
    }

    private func issueGrant(
        store: OAuthTokenStore,
        client: OAuthRegisteredClient,
        resource: String,
        suffix: String,
        now: Date = Date()
    ) async throws -> OAuthTokenPair? {
        let verifier = "verifier-\(suffix)"
        guard
            let code = await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeChallenge: OAuthSupport.pkceS256Challenge(for: verifier),
                resource: resource,
                now: now
            )
        else {
            return nil
        }
        return try await store.redeemAuthorizationCode(
            code: code,
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeVerifier: verifier,
            resource: resource,
            now: now
        )
    }
}
