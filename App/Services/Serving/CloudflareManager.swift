// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from Bridgeport's CloudflareManager.swift with rebranding only:
// com.oliverames.bridgeport.* -> com.oliverames.applecore.*, default tunnel
// name "bridgeport" -> "apple-core", and BridgeportPaths/ConfigManager
// references retargeted at AppleCoreServingPaths/ServingConfigManager. The
// tunnel-management logic (cloudflared CLI invocations, DNS routing,
// LaunchAgent lifecycle) is otherwise unchanged.

import Foundation

#if os(macOS)
    import Darwin
#endif

public struct CloudflareSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var profileName: String
    public var accountId: String
    public var zoneId: String
    public var domain: String
    public var hostname: String
    public var tunnelName: String
    public var tunnelId: String
    public var credentialsFilePath: String
    public var configFilePath: String
    public var cloudflaredPath: String
    public var launchAgentLabel: String
    public var routeMode: String
    public var apiTokenEnvVar: String
    public var apiTokenOPReference: String
    public var createdByAppleCore: Bool

    public init(
        enabled: Bool = false,
        profileName: String = "Personal tunnel",
        accountId: String = "",
        zoneId: String = "",
        domain: String = "",
        hostname: String = "",
        tunnelName: String = "apple-core",
        tunnelId: String = "",
        credentialsFilePath: String = "",
        configFilePath: String = "",
        cloudflaredPath: String = "",
        launchAgentLabel: String = "com.oliverames.applecore.cloudflared",
        routeMode: String = "single-hostname-path-routing",
        apiTokenEnvVar: String = "CLOUDFLARE_API_TOKEN",
        apiTokenOPReference: String = "",
        createdByAppleCore: Bool = false
    ) {
        self.enabled = enabled
        self.profileName = profileName
        self.accountId = accountId
        self.zoneId = zoneId
        self.domain = domain
        self.hostname = hostname
        self.tunnelName = tunnelName
        self.tunnelId = tunnelId
        self.credentialsFilePath = credentialsFilePath
        self.configFilePath = configFilePath
        self.cloudflaredPath = cloudflaredPath
        self.launchAgentLabel = launchAgentLabel
        self.routeMode = routeMode
        self.apiTokenEnvVar = apiTokenEnvVar
        self.apiTokenOPReference = apiTokenOPReference
        self.createdByAppleCore = createdByAppleCore
    }
}

public enum CloudflareTunnelState: String, Codable, Sendable {
    case disabled
    case missingCloudflared
    case needsTunnel
    case needsConfig
    case stopped
    case running
    case error
}

public struct CloudflareTunnelStatus: Codable, Sendable, Equatable {
    public var state: CloudflareTunnelState
    public var message: String
    public var cloudflaredPath: String
    public var cloudflaredInstalled: Bool
    public var configFilePath: String
    public var configFileExists: Bool
    public var credentialsFilePath: String
    public var credentialsFileExists: Bool
    public var launchAgentLabel: String
    public var launchAgentInstalled: Bool
    public var launchAgentRunning: Bool
    public var tunnelName: String
    public var tunnelId: String
    public var hostname: String
    public var publicBaseURL: String
    public var createdByAppleCore: Bool

    public init(
        state: CloudflareTunnelState = .disabled,
        message: String = "Cloudflare is disabled.",
        cloudflaredPath: String = "",
        cloudflaredInstalled: Bool = false,
        configFilePath: String = "",
        configFileExists: Bool = false,
        credentialsFilePath: String = "",
        credentialsFileExists: Bool = false,
        launchAgentLabel: String = "",
        launchAgentInstalled: Bool = false,
        launchAgentRunning: Bool = false,
        tunnelName: String = "",
        tunnelId: String = "",
        hostname: String = "",
        publicBaseURL: String = "",
        createdByAppleCore: Bool = false
    ) {
        self.state = state
        self.message = message
        self.cloudflaredPath = cloudflaredPath
        self.cloudflaredInstalled = cloudflaredInstalled
        self.configFilePath = configFilePath
        self.configFileExists = configFileExists
        self.credentialsFilePath = credentialsFilePath
        self.credentialsFileExists = credentialsFileExists
        self.launchAgentLabel = launchAgentLabel
        self.launchAgentInstalled = launchAgentInstalled
        self.launchAgentRunning = launchAgentRunning
        self.tunnelName = tunnelName
        self.tunnelId = tunnelId
        self.hostname = hostname
        self.publicBaseURL = publicBaseURL
        self.createdByAppleCore = createdByAppleCore
    }
}

public struct CloudflareOperationResult: Sendable {
    public var settings: CloudflareSettings
    public var status: CloudflareTunnelStatus
    public var didChangeSettings: Bool
}

public actor CloudflareManager {
    private var settings: CloudflareSettings
    private let port: UInt16
    private let bindHost: String
    private let fileManager: FileManager

    #if os(macOS)
        private let uid = getuid()
    #else
        private let uid: UInt32 = 0
    #endif

    public init(settings: CloudflareSettings, port: UInt16, bindHost: String, fileManager: FileManager = .default) {
        self.settings = Self.normalizedSettings(settings)
        self.port = port
        self.bindHost = bindHost
        self.fileManager = fileManager
    }

    public func status() -> CloudflareTunnelStatus {
        status(messageOverride: nil, forcedState: nil)
    }

    public func prepareLocalConfiguration() -> CloudflareOperationResult {
        let before = settings
        writeCloudflaredConfigIfPossible()
        writeLaunchAgentIfPossible()
        let status = status(messageOverride: "Cloudflare local tunnel configuration refreshed.", forcedState: nil)
        return CloudflareOperationResult(settings: settings, status: status, didChangeSettings: before != settings)
    }

    public func bootstrapTunnel() -> CloudflareOperationResult {
        let before = settings
        guard settings.enabled else {
            let status = status(messageOverride: "Enable Cloudflare before creating a tunnel.", forcedState: .disabled)
            return CloudflareOperationResult(settings: settings, status: status, didChangeSettings: before != settings)
        }
        guard fileManager.fileExists(atPath: settings.cloudflaredPath) else {
            let status = status(
                messageOverride: "cloudflared is not installed at \(settings.cloudflaredPath).",
                forcedState: .missingCloudflared
            )
            return CloudflareOperationResult(settings: settings, status: status, didChangeSettings: before != settings)
        }

        if settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existingTunnelId = existingTunnelID(named: settings.tunnelName) {
                settings.tunnelId = existingTunnelId
            } else if let createdTunnelId = createTunnel() {
                settings.tunnelId = createdTunnelId
                settings.createdByAppleCore = true
            } else {
                let status = status(
                    messageOverride:
                        "Apple Core could not create the Cloudflare tunnel. Run cloudflared tunnel login or configure a tunnel token, then try again.",
                    forcedState: .needsTunnel
                )
                return CloudflareOperationResult(
                    settings: settings,
                    status: status,
                    didChangeSettings: before != settings
                )
            }
        }

        if settings.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.credentialsFilePath = defaultCredentialsPath(forTunnelID: settings.tunnelId)
        }

        if !settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = ensureDNSRoute()
        }

        writeCloudflaredConfigIfPossible()
        writeLaunchAgentIfPossible()
        let startStatus = startTunnel()
        return CloudflareOperationResult(settings: settings, status: startStatus, didChangeSettings: before != settings)
    }

    @discardableResult
    public func startTunnel() -> CloudflareTunnelStatus {
        writeCloudflaredConfigIfPossible()
        writeLaunchAgentIfPossible()

        guard fileManager.fileExists(atPath: launchAgentURL.path) else {
            return status(messageOverride: "Cloudflare LaunchAgent is not installed yet.", forcedState: .needsConfig)
        }

        if isLaunchAgentRunning() {
            return status(messageOverride: "Cloudflare tunnel is already running.", forcedState: .running)
        }

        let result = LaunchAgentManager.bootstrap(label: settings.launchAgentLabel, uid: uid, plistURL: launchAgentURL)
        if result.status != 0 {
            let message = "Cloudflare tunnel failed to start: \(sanitized(result.stderr))"
            return status(messageOverride: message, forcedState: .error)
        }
        return status(messageOverride: "Cloudflare tunnel started.", forcedState: nil)
    }

    @discardableResult
    public func stopTunnel() -> CloudflareTunnelStatus {
        if isLaunchAgentRunning() {
            let result = LaunchAgentManager.bootout(
                label: settings.launchAgentLabel,
                uid: uid,
                plistURL: launchAgentURL
            )
            if result.status != 0 {
                return status(
                    messageOverride: "Cloudflare tunnel failed to stop: \(sanitized(result.stderr))",
                    forcedState: .error
                )
            }
        }
        return status(messageOverride: "Cloudflare tunnel stopped.", forcedState: .stopped)
    }

    @discardableResult
    public func restartTunnel() -> CloudflareTunnelStatus {
        writeCloudflaredConfigIfPossible()
        writeLaunchAgentIfPossible()

        guard fileManager.fileExists(atPath: launchAgentURL.path) else {
            return status(messageOverride: "Cloudflare LaunchAgent is not installed yet.", forcedState: .needsConfig)
        }

        let result = LaunchAgentManager.restart(label: settings.launchAgentLabel, uid: uid, plistURL: launchAgentURL)
        if result.status != 0 {
            return status(
                messageOverride: "Cloudflare tunnel failed to restart: \(sanitized(result.stderr))",
                forcedState: .error
            )
        }
        return status(messageOverride: "Cloudflare tunnel restarted.", forcedState: nil)
    }

    public static func defaultCloudflaredPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    public static func publicBaseURL(for settings: CloudflareSettings) -> String {
        let hostname = settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostname.isEmpty ? "" : "https://\(hostname)"
    }

    public static func normalizedSettings(_ settings: CloudflareSettings) -> CloudflareSettings {
        var normalized = settings
        if normalized.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.profileName = "Personal tunnel"
        }
        if normalized.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !normalized.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            normalized.hostname = "mcp.\(normalized.domain)"
        }
        if normalized.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.tunnelName = "apple-core"
        }
        if normalized.configFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.configFilePath =
                AppleCoreServingPaths.configDirectory()
                .appendingPathComponent("cloudflared/config.yml")
                .path
        } else {
            normalized.configFilePath = expandedPath(normalized.configFilePath)
        }
        if normalized.cloudflaredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.cloudflaredPath = CloudflareManager.defaultCloudflaredPath()
        } else {
            normalized.cloudflaredPath = expandedPath(normalized.cloudflaredPath)
        }
        if !normalized.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.credentialsFilePath = expandedPath(normalized.credentialsFilePath)
        }
        if normalized.launchAgentLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.launchAgentLabel = "com.oliverames.applecore.cloudflared"
        }
        if normalized.routeMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.routeMode = "single-hostname-path-routing"
        }
        if normalized.apiTokenEnvVar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.apiTokenEnvVar = "CLOUDFLARE_API_TOKEN"
        }
        return normalized
    }

    public static func cloudflaredConfigYAML(settings: CloudflareSettings, port: UInt16, bindHost: String) -> String {
        let tunnel =
            settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.tunnelName
            : settings.tunnelId
        let hostname = settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceHost = bindHost == "0.0.0.0" ? "127.0.0.1" : bindHost
        let service = "http://\(serviceHost):\(port)"

        var lines = [
            "tunnel: \(yamlScalar(tunnel))",
            "credentials-file: \(yamlScalar(settings.credentialsFilePath))",
            "loglevel: warn",
            "transport-loglevel: warn",
            "metrics: localhost:0",
            "",
            "ingress:",
        ]

        if !hostname.isEmpty {
            lines.append("  - hostname: \(yamlScalar(hostname))")
            lines.append("    service: \(yamlScalar(service))")
        }

        lines.append("  - service: http_status:404")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func launchAgentPlistData(
        label: String,
        cloudflaredPath: String,
        configFilePath: String,
        stdoutPath: String,
        stderrPath: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                cloudflaredPath,
                "tunnel",
                "--config",
                configFilePath,
                "run",
            ],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func status(messageOverride: String?, forcedState: CloudflareTunnelState?) -> CloudflareTunnelStatus {
        let cloudflaredInstalled = fileManager.fileExists(atPath: settings.cloudflaredPath)
        let configFileExists = fileManager.fileExists(atPath: settings.configFilePath)
        let credentialsPath = effectiveCredentialsPath()
        let credentialsFileExists = !credentialsPath.isEmpty && fileManager.fileExists(atPath: credentialsPath)
        let launchAgentInstalled = fileManager.fileExists(atPath: launchAgentURL.path)
        let launchAgentRunning = isLaunchAgentRunning()

        let inferredState: CloudflareTunnelState
        let inferredMessage: String
        if !settings.enabled {
            inferredState = .disabled
            inferredMessage = "Cloudflare is disabled."
        } else if !cloudflaredInstalled {
            inferredState = .missingCloudflared
            inferredMessage = "cloudflared is not installed."
        } else if settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !credentialsFileExists {
            inferredState = .needsTunnel
            inferredMessage = "Cloudflare tunnel has not been created or linked yet."
        } else if !configFileExists || !launchAgentInstalled {
            inferredState = .needsConfig
            inferredMessage = "Cloudflare local config or LaunchAgent needs to be created."
        } else if launchAgentRunning {
            inferredState = .running
            inferredMessage = "Cloudflare tunnel is running."
        } else {
            inferredState = .stopped
            inferredMessage = "Cloudflare tunnel is configured but stopped."
        }

        return CloudflareTunnelStatus(
            state: forcedState ?? inferredState,
            message: messageOverride ?? inferredMessage,
            cloudflaredPath: settings.cloudflaredPath,
            cloudflaredInstalled: cloudflaredInstalled,
            configFilePath: settings.configFilePath,
            configFileExists: configFileExists,
            credentialsFilePath: credentialsPath,
            credentialsFileExists: credentialsFileExists,
            launchAgentLabel: settings.launchAgentLabel,
            launchAgentInstalled: launchAgentInstalled,
            launchAgentRunning: launchAgentRunning,
            tunnelName: settings.tunnelName,
            tunnelId: settings.tunnelId,
            hostname: settings.hostname,
            publicBaseURL: Self.publicBaseURL(for: settings),
            createdByAppleCore: settings.createdByAppleCore
        )
    }

    private func writeCloudflaredConfigIfPossible() {
        let credentialsPath = effectiveCredentialsPath()
        guard settings.enabled,
            fileManager.fileExists(atPath: settings.cloudflaredPath),
            !settings.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !credentialsPath.isEmpty
        else {
            return
        }

        settings.credentialsFilePath = credentialsPath

        do {
            let configURL = URL(fileURLWithPath: NSString(string: settings.configFilePath).expandingTildeInPath)
                .standardizedFileURL
            try ensurePrivateDirectory(configURL.deletingLastPathComponent())
            let yaml = Self.cloudflaredConfigYAML(settings: settings, port: port, bindHost: bindHost)
            try yaml.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            settings.configFilePath = configURL.path
        } catch {
            logMessage("CloudflareManager: Failed to write cloudflared config: \(error)")
        }
    }

    private func writeLaunchAgentIfPossible() {
        guard settings.enabled,
            fileManager.fileExists(atPath: settings.cloudflaredPath),
            fileManager.fileExists(atPath: settings.configFilePath)
        else {
            return
        }

        do {
            try ensurePrivateDirectory(launchAgentURL.deletingLastPathComponent(), permissions: 0o755)
            try ensurePrivateDirectory(AppleCoreServingPaths.configDirectory())
            let data = try Self.launchAgentPlistData(
                label: settings.launchAgentLabel,
                cloudflaredPath: settings.cloudflaredPath,
                configFilePath: settings.configFilePath,
                stdoutPath: AppleCoreServingPaths.configDirectory().appendingPathComponent("cloudflared_stdout.log")
                    .path,
                stderrPath: AppleCoreServingPaths.configDirectory().appendingPathComponent("cloudflared_stderr.log")
                    .path
            )
            try data.write(to: launchAgentURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launchAgentURL.path)
        } catch {
            logMessage("CloudflareManager: Failed to write cloudflared LaunchAgent: \(error)")
        }
    }

    private func existingTunnelID(named name: String) -> String? {
        let result = runShell(settings.cloudflaredPath, ["tunnel", "list", "--name", name, "--output", "json"])
        guard result.status == 0,
            let data = result.stdout.data(using: .utf8),
            let tunnels = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return
            tunnels
            .filter { tunnel in
                // cloudflared emits Go's zero timestamp ("0001-01-01T...")
                // for tunnels that have never been deleted.
                guard let deletedAt = tunnel["deleted_at"] as? String, !deletedAt.isEmpty else { return true }
                return deletedAt.hasPrefix("0001-")
            }
            .compactMap { tunnel -> String? in
                guard let tunnelName = tunnel["name"] as? String, tunnelName == name else { return nil }
                return tunnel["id"] as? String
            }
            .first
    }

    private func createTunnel() -> String? {
        let credentialsPath =
            settings.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultCredentialsPath(forTunnelID: settings.tunnelName)
            : Self.expandedPath(settings.credentialsFilePath)
        settings.credentialsFilePath = credentialsPath

        do {
            try ensurePrivateDirectory(URL(fileURLWithPath: credentialsPath).deletingLastPathComponent())
        } catch {
            logMessage("CloudflareManager: Failed to create credentials directory: \(error)")
            return nil
        }

        let result = runShell(
            settings.cloudflaredPath,
            [
                "tunnel",
                "create",
                "--credentials-file",
                credentialsPath,
                "--output",
                "json",
                settings.tunnelName,
            ]
        )
        guard result.status == 0 else {
            logMessage("CloudflareManager: cloudflared tunnel create failed: \(sanitized(result.stderr))")
            return nil
        }

        if let data = result.stdout.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        {
            settings.credentialsFilePath =
                fileManager.fileExists(atPath: credentialsPath)
                ? credentialsPath
                : defaultCredentialsPath(forTunnelID: id)
            return id
        }

        if let id = firstUUID(in: result.stdout + "\n" + result.stderr) {
            settings.credentialsFilePath =
                fileManager.fileExists(atPath: credentialsPath)
                ? credentialsPath
                : defaultCredentialsPath(forTunnelID: id)
            return id
        }
        return nil
    }

    private func ensureDNSRoute() -> Bool {
        let tunnel =
            settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.tunnelName
            : settings.tunnelId
        let result = runShell(settings.cloudflaredPath, ["tunnel", "route", "dns", tunnel, settings.hostname])
        if result.status == 0 {
            return true
        }

        let combined = "\(result.stdout)\n\(result.stderr)".lowercased()
        if combined.contains("already exists") || combined.contains("record exists") {
            return true
        }

        logMessage("CloudflareManager: DNS route setup failed: \(sanitized(result.stderr))")
        return false
    }

    private func isLaunchAgentRunning() -> Bool {
        let result = runShell("/bin/launchctl", ["print", "gui/\(uid)/\(settings.launchAgentLabel)"])
        return result.status == 0 && result.stdout.contains("state = running")
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(settings.launchAgentLabel).plist")
    }

    private func effectiveCredentialsPath() -> String {
        let configured = settings.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return Self.expandedPath(configured)
        }

        if !settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultCredentialsPath(forTunnelID: settings.tunnelId)
        }

        return ""
    }

    private func defaultCredentialsPath(forTunnelID tunnelID: String) -> String {
        let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        if tunnelID.range(of: uuidPattern, options: .regularExpression) != nil {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cloudflared/\(tunnelID).json")
                .path
        }
        return AppleCoreServingPaths.configDirectory()
            .appendingPathComponent("cloudflared/\(ServingConfigManager.normalizedRoutePath(tunnelID)).json")
            .path
    }

    private static func expandedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func ensurePrivateDirectory(_ url: URL, permissions: Int = 0o700) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func firstUUID(in text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex ..< text.endIndex, in: text)),
            let range = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private func sanitized(_ value: String) -> String {
        var sanitized = value
        for key in [
            settings.apiTokenEnvVar,
            "TUNNEL_TOKEN",
            "TUNNEL_CRED_CONTENTS",
            "CLOUDFLARE_API_TOKEN",
        ] where !key.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: key + "=", with: key + "=[redacted]")
        }
        return sanitized
    }

    private static func yamlScalar(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
