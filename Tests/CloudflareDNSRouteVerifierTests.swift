import Foundation
import Testing

@Suite("Cloudflare DNS route verification")
struct CloudflareDNSRouteVerifierTests {
    @Test("The lookup requests one exact CNAME without exposing the token in the URL")
    func buildsFilteredRequest() throws {
        let request = try #require(
            CloudflareDNSRouteVerifier.request(
                zoneID: "zone-123",
                hostname: "mcp.example.com",
                apiToken: "secret-token"
            )
        )
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.host == "api.cloudflare.com")
        #expect(components.path == "/client/v4/zones/zone-123/dns_records")
        #expect(query["name"] == "mcp.example.com")
        #expect(query["type"] == "CNAME")
        #expect(query["per_page"] == "100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.url?.absoluteString.contains("secret-token") == false)
    }

    @Test("Only the expected tunnel target is accepted")
    func evaluatesExactTarget() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.cloudflare.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: responseData(name: "MCP.Example.com.", content: "TUNNEL-123.cfargotunnel.com."),
                response: response,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .matches
        )
        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: responseData(name: "mcp.example.com", content: "other.cfargotunnel.com"),
                response: response,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .pointsElsewhere("other.cfargotunnel.com")
        )
        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: Data(#"{"success":true,"result":[]}"#.utf8),
                response: response,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .missing
        )
    }

    @Test("Unverifiable API responses fail closed")
    func rejectsUnverifiableResponses() throws {
        let url = URL(string: "https://api.cloudflare.com")!
        let forbidden = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: Data(),
                response: forbidden,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .unavailable("Cloudflare DNS verification returned HTTP 403.")
        )
        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: Data(#"{"success":false,"result":[]}"#.utf8),
                response: ok,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .unavailable("Cloudflare returned an unreadable DNS response.")
        )
        #expect(
            CloudflareDNSRouteVerifier.evaluate(
                data: Data("not-json".utf8),
                response: ok,
                hostname: "mcp.example.com",
                tunnelID: "tunnel-123"
            ) == .unavailable("Cloudflare returned an unreadable DNS response.")
        )
    }

    private func responseData(name: String, content: String) -> Data {
        Data(
            """
            {"success":true,"result":[{"type":"CNAME","name":"\(name)","content":"\(content)"}]}
            """.utf8
        )
    }

    @Test("Remote readiness requires exact public OAuth discovery, not an HTML login or localhost issuer")
    func publicReadiness() throws {
        let base = "https://mcp.example.com"
        let url = URL(string: base + "/.well-known/oauth-authorization-server")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        var metadata: [String: Any] = [
            "issuer": base, "authorization_endpoint": base + "/oauth/authorize",
            "token_endpoint": base + "/oauth/token", "code_challenge_methods_supported": ["S256"],
        ]
        func encode() throws -> Data { try JSONSerialization.data(withJSONObject: metadata) }
        #expect(CloudflareReadiness.accepts(data: try encode(), response: response, baseURL: base))
        metadata["issuer"] = "http://localhost:8756"
        #expect(!CloudflareReadiness.accepts(data: try encode(), response: response, baseURL: base))
        #expect(
            !CloudflareReadiness.accepts(data: Data("<html>Sign in</html>".utf8), response: response, baseURL: base)
        )
        metadata["issuer"] = base
        let redirected = HTTPURLResponse(
            url: URL(string: "https://login.example.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        #expect(!CloudflareReadiness.accepts(data: try encode(), response: redirected, baseURL: base))
        let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        #expect(!CloudflareReadiness.accepts(data: try encode(), response: unavailable, baseURL: base))
    }

}
