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

extension LicenseGate {
    /// One actor owns activation and network verification for the app.
    public static let shared = LicenseGate(licenseURL: AppleCoreServingPaths.licenseURL())
}

/// Per-service settings for the HTTP/SSE server, keyed by
/// `String(describing: type(of: service))` -- the same identifier
/// `ServiceConfig` and `ServiceRegistry` already use for local enablement.
public struct ServingServiceSettings: Codable, Sendable {
    /// Whether this service's tools are visible to requests that arrive via
    /// the public hostname (Cloudflare tunnel). Local requests are governed
    /// solely by the existing enabled/disabled binding in ServerController.
    ///
    /// Defaults to on. This only takes effect once remote access has been set
    /// up at all — with no tunnel there is no public hostname to reach, and
    /// remote requests still have to authenticate with the bearer token or
    /// OAuth. Defaulting it off meant someone who deliberately configured a
    /// tunnel then found nothing reachable through it, with the reason spread
    /// across eleven separate switches on another pane.
    public var exposePublicly: Bool

    public init(exposePublicly: Bool = true) {
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
    /// Folders the filesystem surface may touch. Absent or empty means the
    /// surface can reach nothing, which is the default: unlike every other
    /// surface, the filesystem has no macOS privacy grant bounding it, so the
    /// bound is this list and it starts empty.
    public var filesystemRoots: [FilesystemRoot]?

    public init(
        token: String? = nil,
        port: UInt16? = nil,
        bindHost: String? = nil,
        publicBaseURL: String? = nil,
        allowedOrigins: [String]? = nil,
        allowQueryTokenAuth: Bool? = nil,
        serviceSettings: [String: ServingServiceSettings]? = nil,
        cloudflare: CloudflareSettings? = nil,
        filesystemRoots: [FilesystemRoot]? = nil
    ) {
        self.token = token
        self.port = port
        self.bindHost = bindHost
        self.publicBaseURL = publicBaseURL
        self.allowedOrigins = allowedOrigins
        self.allowQueryTokenAuth = allowQueryTokenAuth
        self.serviceSettings = serviceSettings
        self.cloudflare = cloudflare
        self.filesystemRoots = filesystemRoots
    }

    public func settings(forServiceID serviceID: String) -> ServingServiceSettings {
        serviceSettings?[serviceID] ?? ServingServiceSettings()
    }

    /// A disabled managed tunnel must not keep advertising its last hostname.
    /// Configurations without a Cloudflare block may still supply another
    /// externally managed public URL.
    public var effectivePublicBaseURL: String? {
        if cloudflare?.enabled == false {
            return nil
        }
        let trimmed = publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
    public static let defaultCloudflareLaunchAgentLabel = "com.oliverames.applecore.cloudflared"

    public static func usesConfigHomeOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let override = environment[configHomeEnvironmentKey] else { return false }
        return !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

    public static func oauthClientRegistryURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL
    {
        configDirectory(environment: environment).appendingPathComponent("oauth_clients.json")
    }

    public static func oauthAccessTokenStoreURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL
    {
        configDirectory(environment: environment).appendingPathComponent("oauth_tokens.json")
    }

    /// Where the EULA license envelope lives (see Shared/LicenseDocument.swift).
    /// Absent or unverified means the binary answers MCP requests with 402.
    public static func licenseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("license.txt")
    }

    /// Alternate config homes are independent profiles. Give each profile a
    /// stable launchd identity so a development or test run cannot boot out or
    /// replace the production Cloudflare agent.
    public static func cloudflareLaunchAgentLabel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard usesConfigHomeOverride(environment: environment) else {
            return defaultCloudflareLaunchAgentLabel
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in configDirectory(environment: environment).path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(defaultCloudflareLaunchAgentLabel).\(String(hash, radix: 16))"
    }
}

/// Loads, persists, and derives values from `AppleCoreServingConfig`.
/// Adapted from the relevant subset of Bridgeport's `ConfigManager`.
public enum ServingConfigManager {
    public struct UpdateResult {
        public let before: AppleCoreServingConfig
        public let after: AppleCoreServingConfig
    }

    private static let configLock = NSRecursiveLock()

    public static func load(from url: URL = AppleCoreServingPaths.configURL()) -> AppleCoreServingConfig {
        configLock.withLock {
            loadUnlocked(from: url)
        }
    }

    private static func loadUnlocked(from url: URL) -> AppleCoreServingConfig {
        guard let data = try? Data(contentsOf: url) else {
            return AppleCoreServingConfig()
        }
        do {
            return try JSONDecoder().decode(AppleCoreServingConfig.self, from: data)
        } catch {
            // Never silently discard an existing config: a decode failure
            // followed by a save would clobber the on-disk file. Log loudly
            // and fall back to defaults only for this in-memory session.
            logMessage(
                "ERROR: failed to decode \(url.path): \(error). "
                    + "Using in-memory defaults; the on-disk file is left untouched until a save."
            )
            return AppleCoreServingConfig()
        }
    }

    @discardableResult
    public static func save(
        _ config: AppleCoreServingConfig,
        to url: URL = AppleCoreServingPaths.configURL()
    ) -> Bool {
        configLock.withLock {
            saveUnlocked(config, to: url)
        }
    }

    /// Applies a field-level mutation to the newest in-process snapshot while
    /// holding the same lock as every save. `onlyIf` provides a compare step
    /// for async workflows that must not persist a stale result.
    public static func update(
        to url: URL = AppleCoreServingPaths.configURL(),
        onlyIf: (AppleCoreServingConfig) -> Bool = { _ in true },
        _ mutate: (inout AppleCoreServingConfig) -> Void
    ) -> UpdateResult? {
        configLock.withLock {
            let before = loadUnlocked(from: url)
            guard onlyIf(before) else { return nil }
            var after = before
            mutate(&after)
            guard saveUnlocked(after, to: url) else { return nil }
            return UpdateResult(before: before, after: after)
        }
    }

    private static func saveUnlocked(_ config: AppleCoreServingConfig, to url: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard let existingData = try? Data(contentsOf: url) else {
                logMessage("ServingConfigManager: Refusing to overwrite unreadable config at \(url.path)")
                return false
            }
            guard (try? JSONDecoder().decode(AppleCoreServingConfig.self, from: existingData)) != nil else {
                logMessage("ServingConfigManager: Refusing to overwrite undecodable config at \(url.path)")
                return false
            }
        }

        do {
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            logMessage("ServingConfigManager: Failed to persist config: \(error)")
            return false
        }
    }

    /// True when config.json exists but does not decode. Bootstrap paths
    /// that generate defaults for missing fields must check this before
    /// saving: treating a corrupt-but-recoverable file as "fresh install"
    /// and persisting those defaults would overwrite it.
    public static func persistedConfigIsUndecodable(
        from url: URL = AppleCoreServingPaths.configURL()
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return false
        }
        do {
            _ = try JSONDecoder().decode(AppleCoreServingConfig.self, from: data)
            return false
        } catch {
            return true
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

    public static func origin(for baseURL: String?) -> String? {
        guard let baseURL,
            let url = URL(string: baseURL),
            let scheme = url.scheme,
            let host = url.host
        else {
            return nil
        }
        var origin = "\(scheme)://\(host)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
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
