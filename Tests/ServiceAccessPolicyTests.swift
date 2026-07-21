import Testing

@Suite("Service access policy")
struct ServiceAccessPolicyTests {
    @Test("Disabled services stay hidden locally and remotely")
    func disabledServiceIsHidden() {
        #expect(
            !ServiceAccessPolicy.isAccessible(
                isLocallyEnabled: false,
                surface: .local,
                isExposedRemotely: true
            )
        )
        #expect(
            !ServiceAccessPolicy.isAccessible(
                isLocallyEnabled: false,
                surface: .remote,
                isExposedRemotely: true
            )
        )
    }

    @Test("Enabled services remain available locally")
    func enabledServiceIsAvailableLocally() {
        #expect(
            ServiceAccessPolicy.isAccessible(
                isLocallyEnabled: true,
                surface: .local,
                isExposedRemotely: false
            )
        )
    }

    @Test("Remote access requires explicit exposure")
    func remoteAccessRequiresExposure() {
        #expect(
            !ServiceAccessPolicy.isAccessible(
                isLocallyEnabled: true,
                surface: .remote,
                isExposedRemotely: false
            )
        )
        #expect(
            ServiceAccessPolicy.isAccessible(
                isLocallyEnabled: true,
                surface: .remote,
                isExposedRemotely: true
            )
        )
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
        arguments: [nil, "", "applecore.amesvt.com", "192.168.1.25:8756", "not a host"] as [String?]
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
