import Foundation
import Testing

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
    func refreshTokensRotate() async {
        let store = OAuthTokenStore()
        let issuedAt = Date(timeIntervalSince1970: 100)
        let resource = "https://applecore.example.com/mcp"
        let client = await store.registerClient(
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
        let initial = await store.redeemAuthorizationCode(
            code: code ?? "",
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeVerifier: "verifier",
            now: issuedAt
        )
        let refreshTime = issuedAt.addingTimeInterval(12 * 60 * 60 + 1)
        let rotated = await store.redeemRefreshToken(
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
            await store.redeemRefreshToken(
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
        let client = await firstStore.registerClient(
            clientName: "ChatGPT",
            redirectURIs: ["http://localhost/callback"]
        )
        let code = await firstStore.issueAuthorizationCode(
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
            resource: resource
        )
        let initial = await firstStore.redeemAuthorizationCode(
            code: code ?? "",
            clientID: client.clientID,
            redirectURI: client.redirectURIs[0],
            codeVerifier: "verifier"
        )
        let reloadedStore = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)

        #expect(
            await reloadedStore.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: "wrong-client",
                resource: resource
            ) == nil
        )
        #expect(
            await reloadedStore.redeemRefreshToken(
                initial?.refreshToken ?? "",
                clientID: client.clientID,
                resource: "https://applecore.example.com/other"
            ) == nil
        )
        #expect(
            await reloadedStore.redeemRefreshToken(
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
            _ = await store.adoptClientIfNeeded(
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
}
