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
    static func isAccessible(
        isLocallyEnabled: Bool,
        surface: MCPAccessSurface,
        isExposedRemotely: Bool
    ) -> Bool {
        guard isLocallyEnabled else { return false }
        return surface == .local || isExposedRemotely
    }
}
