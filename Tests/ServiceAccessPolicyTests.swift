import Testing

@Suite("Service access policy")
struct ServiceAccessPolicyTests {
    @Test("Disabled services stay hidden on both surfaces", arguments: [MCPAccessSurface.local, .remote])
    func disabledServiceIsHidden(surface: MCPAccessSurface) {
        #expect(!ServiceAccessPolicy.isAccessible(isLocallyEnabled: false, surface: surface))
    }

    @Test("An enabled service is reachable on both surfaces", arguments: [MCPAccessSurface.local, .remote])
    func enabledServiceIsAvailable(surface: MCPAccessSurface) {
        #expect(ServiceAccessPolicy.isAccessible(isLocallyEnabled: true, surface: surface))
    }
}

@Suite("Request access classification")
struct RequestAccessClassifierTests {
    @Test(
        "Loopback hosts are local",
        arguments: ["localhost", "localhost:8756", "127.0.0.1", "127.0.0.1:8756", "[::1]", "[::1]:8756"]
    )
    func loopbackHostsAreLocal(host: String) {
        #expect(RequestAccessClassifier.surface(hostHeader: host) == .local)
    }

    @Test(
        "Non-loopback and invalid hosts fail closed as remote",
        arguments: [nil, "", "mcp.example.com", "192.168.1.25:8756", "not a host"] as [String?]
    )
    func otherHostsAreRemote(host: String?) {
        #expect(RequestAccessClassifier.surface(hostHeader: host) == .remote)
    }

    @Test("Proxy headers always identify a remote request")
    func proxyHeadersAreRemote() {
        #expect(
            RequestAccessClassifier.surface(
                hostHeader: "127.0.0.1:8756",
                forwardedForHeader: "203.0.113.10"
            ) == .remote
        )
        #expect(
            RequestAccessClassifier.surface(
                hostHeader: "localhost:8756",
                connectingIPHeader: "203.0.113.10"
            ) == .remote
        )
    }
}
