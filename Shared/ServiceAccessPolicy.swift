import Foundation

public enum MCPAccessSurface: Sendable, Equatable {
    case local
    case remote
}

enum RequestAccessClassifier {
    static func surface(
        hostHeader: String?,
        forwardedForHeader: String? = nil,
        connectingIPHeader: String? = nil
    ) -> MCPAccessSurface {
        if hasValue(forwardedForHeader) || hasValue(connectingIPHeader) {
            return .remote
        }

        guard let host = hostHeader?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !host.isEmpty
        else {
            return .remote
        }

        if host == "localhost" || host.hasPrefix("localhost:")
            || host == "127.0.0.1" || host.hasPrefix("127.0.0.1:")
            || host == "::1" || host == "[::1]" || host.hasPrefix("[::1]:")
        {
            return .local
        }
        return .remote
    }

    private static func hasValue(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

enum ServiceAccessPolicy {
    /// A service you have enabled is reachable on whichever surface is
    /// serving it. Remote reachability is decided once, by whether remote
    /// access is set up at all, rather than per service.
    ///
    /// There used to be a second axis: every service carried its own
    /// `exposePublicly` flag, off by default, surfaced as a "Remote" switch
    /// next to each of the eleven services. The common outcome was someone
    /// configuring a tunnel correctly and reaching nothing through it, with
    /// the reason spread across eleven switches on a different pane. Remote
    /// requests are authenticated either way, so the axis bought precision
    /// almost nobody wanted at the cost of the failure being invisible.
    static func isAccessible(isLocallyEnabled: Bool, surface: MCPAccessSurface) -> Bool {
        _ = surface
        return isLocallyEnabled
    }
}
