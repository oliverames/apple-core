// SPDX-License-Identifier: GPL-3.0-or-later
//
// Configuration and on-disk paths for the HTTP/SSE MCP transport. Adapted
// from Bridgeport's ConfigManager.swift, trimmed to the subset apple-core
// needs: there are no external connector processes here, so the
// Connector/MCPServiceConfig schema is intentionally not ported. Instead
// this models one global bind/publish configuration plus a per-service
// "expose publicly" toggle keyed the same way ServiceRegistry keys its
// bindings (`String(describing: type(of: service))`).

import Foundation
import Security

/// Per-service settings for the HTTP/SSE server, keyed by
/// `String(describing: type(of: service))` -- the same identifier
/// `ServiceConfig` and `ServiceRegistry` already use for local enablement.
public struct ServingServiceSettings: Codable, Sendable {
    /// Whether this service's tools are visible to requests that arrive via
    /// the public hostname (Cloudflare tunnel). Local requests are governed
    /// solely by the existing enabled/disabled binding in ServerController.
    public var exposePublicly: Bool

    public init(exposePublicly: Bool = false) {
        self.exposePublicly = exposePublicly
    }
}

public struct AppleCoreServingConfig: Codable, Sendable, Equatable {
    public var token: String?
    public var port: UInt16?
    public var bindHost: String?
    public var publicBaseURL: String?
    public var allowedOrigins: [String]?
    public var allowQueryTokenAuth: Bool?
    public var serviceSettings: [String: ServingServiceSettings]?
    public var cloudflare: CloudflareSettings?

    public init(
        token: String? = nil,
        port: UInt16? = nil,
        bindHost: String? = nil,
        publicBaseURL: String? = nil,
        allowedOrigins: [String]? = nil,
        allowQueryTokenAuth: Bool? = nil,
        serviceSettings: [String: ServingServiceSettings]? = nil,
        cloudflare: CloudflareSettings? = nil
    ) {
        self.token = token
        self.port = port
        self.bindHost = bindHost
        self.publicBaseURL = publicBaseURL
        self.allowedOrigins = allowedOrigins
        self.allowQueryTokenAuth = allowQueryTokenAuth
        self.serviceSettings = serviceSettings
        self.cloudflare = cloudflare
    }

    public func settings(forServiceID serviceID: String) -> ServingServiceSettings {
        serviceSettings?[serviceID] ?? ServingServiceSettings()
    }
}

// Codable conformance for Equatable's compiler-synthesized needs; only
// `serviceSettings` and `cloudflare` need explicit Equatable since the rest
// are already Equatable value types. Swift synthesizes struct Equatable
// automatically here as long as every stored property is Equatable, so no
// custom `==` is required (ServingServiceSettings and CloudflareSettings are
// declared Equatable/Codable below and in CloudflareManager.swift).
extension ServingServiceSettings: Equatable {}

/// On-disk locations for serving configuration and OAuth state. Mirrors
/// Bridgeport's `BridgeportPaths`, rebranded for Apple Core.
public enum AppleCoreServingPaths {
    public static let configHomeEnvironmentKey = "APPLECORE_CONFIG_HOME"

    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[configHomeEnvironmentKey],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/apple-core")
    }

    public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("config.json")
    }

    public static func oauthClientRegistryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("oauth_clients.json")
    }

    public static func oauthAccessTokenStoreURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("oauth_tokens.json")
    }
}

/// Loads, persists, and derives values from `AppleCoreServingConfig`.
/// Adapted from the relevant subset of Bridgeport's `ConfigManager`.
public enum ServingConfigManager {
    public static func load(from url: URL = AppleCoreServingPaths.configURL()) -> AppleCoreServingConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(AppleCoreServingConfig.self, from: data)
        else {
            return AppleCoreServingConfig()
        }
        return config
    }

    public static func save(_ config: AppleCoreServingConfig, to url: URL = AppleCoreServingPaths.configURL()) {
        do {
            let directory = url.deletingLastPathComponent()
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logMessage("ServingConfigManager: Failed to persist config: \(error)")
        }
    }

    public static func clientEndpointBaseURL(port: UInt16, publicBaseURL: String?) -> String {
        var trimmed = (publicBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "http://localhost:\(port)"
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public static func defaultAllowedOrigins(port: UInt16, publicBaseURL: String?) -> [String] {
        var origins = [
            "http://localhost:\(port)",
            "http://127.0.0.1:\(port)",
            "http://[::1]:\(port)",
        ]

        if let publicBaseURL,
            let url = URL(string: publicBaseURL),
            let scheme = url.scheme,
            let host = url.host
        {
            var origin = "\(scheme)://\(host)"
            if let port = url.port {
                origin += ":\(port)"
            }
            origins.append(origin)
        }

        return Array(Set(origins)).sorted()
    }

    public static func normalizedRoutePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var sanitized = ""
        var previousWasSeparator = false

        for scalar in path.unicodeScalars {
            if allowedScalars.contains(scalar) {
                sanitized.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                sanitized.append("-")
                previousWasSeparator = true
            }
        }

        while sanitized.hasPrefix("-") || sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        while sanitized.hasSuffix("-") || sanitized.hasSuffix(".") {
            sanitized.removeLast()
        }

        return sanitized.isEmpty ? "mcp" : sanitized
    }

    public static func generateSecureToken() -> String {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status == errSecSuccess {
            return "ames_"
                + Data(randomBytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        // Extremely unlikely fallback; SecRandomCopyBytes failing means the
        // system CSPRNG is unavailable.
        return "ames_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
