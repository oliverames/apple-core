import Foundation
import Testing

@Suite("OAuth registration and metadata regressions")
struct OAuthRegressionTests {
    private func metadata(_ id: String) -> ClientIDMetadata {
        ClientIDMetadata(
            clientID: "https://client.example/\(id).json",
            clientName: id,
            redirectURIs: ["http://localhost/callback"],
            clientURI: nil
        )
    }

    @Test("Metadata clients can authorize dynamic loopback ports and redeem only that exact redirect")
    func dynamicLoopbackAuthorization() async throws {
        let store = OAuthTokenStore()
        let client = try await store.registerClientIDMetadataClient(metadata("native"))
        let redirect = "http://localhost:53682/callback"
        let resource = "https://server.example/mcp"
        let code = try #require(
            await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: redirect,
                codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
                resource: resource
            )
        )
        #expect(
            try await store.redeemAuthorizationCode(
                code: code,
                clientID: client.clientID,
                redirectURI: "http://localhost:53683/callback",
                codeVerifier: "verifier",
                resource: resource
            ) == nil
        )
        let validCode = try #require(
            await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: redirect,
                codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
                resource: resource
            )
        )
        #expect(
            try await store.redeemAuthorizationCode(
                code: validCode,
                clientID: client.clientID,
                redirectURI: redirect,
                codeVerifier: "verifier",
                resource: resource
            ) != nil
        )
    }

    @Test("Only the port can vary in a metadata loopback redirect")
    func exactComponents() {
        let registered = ["http://localhost/callback?mode=one"]
        #expect(
            ClientIDMetadataRedirect.matches(
                requested: "http://localhost:1234/callback?mode=one",
                registered: registered
            )
        )
        for redirect in [
            "http://localhost:1234/callback?mode=two",
            "http://localhost:1234/callback",
            "http://user@localhost:1234/callback?mode=one",
            "http://localhost:1234/callback?mode=one#fragment",
            "http://localhost:1234/%63allback?mode=one",
        ] {
            #expect(!ClientIDMetadataRedirect.matches(requested: redirect, registered: registered))
        }
    }

    @Test("Registration churn cannot evict a client with an active token")
    func preservesActiveClients() async throws {
        let store = OAuthTokenStore()
        let now = Date(timeIntervalSince1970: 100)
        let resource = "https://server.example/mcp"
        let client = try await store.registerClient(
            clientName: "Active",
            redirectURIs: ["http://localhost/callback"],
            now: now
        )
        let code = try #require(
            await store.issueAuthorizationCode(
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
                resource: resource,
                now: now
            )
        )
        let token = try #require(
            try await store.redeemAuthorizationCode(
                code: code,
                clientID: client.clientID,
                redirectURI: client.redirectURIs[0],
                codeVerifier: "verifier",
                resource: resource,
                now: now
            )
        )
        for index in 0 ... 256 {
            _ = try await store.registerClientIDMetadataClient(
                metadata("client-\(index)"),
                now: now.addingTimeInterval(Double(index + 1))
            )
        }
        #expect(await store.registeredClients().count == 256)
        #expect(await store.isValidAccessToken(token.accessToken, resource: resource, now: now.addingTimeInterval(300)))
    }

    @Test("A registry full of pending authorizations refuses a new registration without losing clients")
    func fullRegistry() async throws {
        let store = OAuthTokenStore()
        let now = Date(timeIntervalSince1970: 100)
        for index in 0 ..< 256 {
            let client = try await store.registerClientIDMetadataClient(metadata("client-\(index)"), now: now)
            #expect(
                await store.issueAuthorizationCode(
                    clientID: client.clientID,
                    redirectURI: "http://localhost:1234/callback",
                    codeChallenge: "challenge",
                    resource: "https://server.example/mcp",
                    now: now
                ) != nil
            )
        }
        do {
            _ = try await store.registerClient(
                clientName: "overflow",
                redirectURIs: ["http://localhost/callback"],
                now: now
            )
            Issue.record("Expected capacity error")
        } catch {
            #expect(error as? OAuthTokenStoreError == .clientCapacityReached)
        }
        #expect(await store.registeredClients().count == 256)
    }

    @Test("Metadata streaming stops on the first byte beyond 5 KB")
    func boundedMetadataBody() async throws {
        let exact = AsyncStream<UInt8> { continuation in
            for _ in 0 ..< 5120 { continuation.yield(65) }
            continuation.finish()
        }
        #expect(try await ClientIDMetadata.boundedBody(from: exact).count == 5120)
        let tooLarge = AsyncStream<UInt8> { continuation in
            for _ in 0 ..< 6000 { continuation.yield(65) }
            continuation.finish()
        }
        do {
            _ = try await ClientIDMetadata.boundedBody(from: tooLarge)
            Issue.record("Expected size error")
        } catch let error as ClientIDMetadataError {
            guard case .documentTooLarge(let bytes, let limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(bytes == 5121)
            #expect(limit == 5120)
        }
    }
}
