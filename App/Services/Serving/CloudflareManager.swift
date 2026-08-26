// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from Bridgeport's CloudflareManager.swift with rebranding only:
// com.oliverames.bridgeport.* -> com.oliverames.applecore.*, default tunnel
// name "bridgeport" -> "apple-core", and BridgeportPaths/ConfigManager
// references retargeted at AppleCoreServingPaths/ServingConfigManager.
//
// Diverged from Bridgeport in 1.0.3: hostname normalization and validation,
// origin-certificate (login) detection with `logInToCloudflare`, DNS routing
// failures returned to the caller instead of logged and discarded, and
// LaunchAgent start verified rather than assumed. The underlying cloudflared
// CLI invocations and LaunchAgent lifecycle are otherwise as ported.

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
        self.createdByAppleCore = createdByAppleCore
    }

    // Tolerant decoding: every field falls back to its default when absent,
    // so a hand-written or externally-generated cloudflare block missing a
    // key can never fail the whole AppleCoreServingConfig decode. Before
    // this, a single missing key made `ServingConfigManager.load()` silently
    // return an empty config, and the next save clobbered the real file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CloudflareSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        profileName =
            try container.decodeIfPresent(String.self, forKey: .profileName) ?? defaults.profileName
        accountId =
            try container.decodeIfPresent(String.self, forKey: .accountId) ?? defaults.accountId
        zoneId = try container.decodeIfPresent(String.self, forKey: .zoneId) ?? defaults.zoneId
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? defaults.domain
        hostname =
            try container.decodeIfPresent(String.self, forKey: .hostname) ?? defaults.hostname
        tunnelName =
            try container.decodeIfPresent(String.self, forKey: .tunnelName) ?? defaults.tunnelName
        tunnelId =
            try container.decodeIfPresent(String.self, forKey: .tunnelId) ?? defaults.tunnelId
        credentialsFilePath =
            try container.decodeIfPresent(String.self, forKey: .credentialsFilePath)
            ?? defaults.credentialsFilePath
        configFilePath =
            try container.decodeIfPresent(String.self, forKey: .configFilePath)
            ?? defaults.configFilePath
        cloudflaredPath =
            try container.decodeIfPresent(String.self, forKey: .cloudflaredPath)
            ?? defaults.cloudflaredPath
        launchAgentLabel =
            try container.decodeIfPresent(String.self, forKey: .launchAgentLabel)
            ?? defaults.launchAgentLabel
        routeMode =
            try container.decodeIfPresent(String.self, forKey: .routeMode) ?? defaults.routeMode
        createdByAppleCore =
            try container.decodeIfPresent(Bool.self, forKey: .createdByAppleCore)
            ?? defaults.createdByAppleCore
    }
}

public enum CloudflareTunnelState: String, Codable, Sendable {
    case disabled
    case missingCloudflared
    case needsLogin
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
    /// True once `cloudflared tunnel login` has written an origin certificate.
    /// Without it neither tunnel creation nor DNS routing can work, which is
    /// the first thing a new setup is missing.
    public var loggedIn: Bool
    public var originCertificatePath: String
    /// Why the configured hostname cannot be routed, when it cannot be.
    public var hostnameError: String?

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
        createdByAppleCore: Bool = false,
        loggedIn: Bool = false,
        originCertificatePath: String = "",
        hostnameError: String? = nil
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
        self.loggedIn = loggedIn
        self.originCertificatePath = originCertificatePath
        self.hostnameError = hostnameError
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

    public static func reconcilePersistedConfiguration() async -> CloudflareOperationResult? {
        var config = ServingConfigManager.load()
        guard let settings = config.cloudflare else { return nil }

        let manager = CloudflareManager(
            settings: settings,
            port: config.port ?? 8756,
            bindHost: config.bindHost ?? "127.0.0.1"
        )
        let result = await manager.reconcileTunnel()
        config.cloudflare = result.settings
        let publicBaseURL = CloudflareManager.publicBaseURL(for: result.settings)
        config.publicBaseURL = publicBaseURL
        // The OAuth issuer and the CORS origin list are both derived from the
        // public base URL, so a config saved before the hostname existed keeps
        // serving discovery metadata pointing at localhost. Re-merge on every
        // startup reconciliation rather than only when the pane is used.
        var origins = config.allowedOrigins ?? []
        for origin in ServingConfigManager.defaultAllowedOrigins(
            port: config.port ?? 8756,
            publicBaseURL: publicBaseURL
        ) where !origins.contains(origin) {
            origins.append(origin)
        }
        config.allowedOrigins = origins.sorted()
        ServingConfigManager.save(config)
        return result
    }

    public func reconcileTunnel() -> CloudflareOperationResult {
        settings.enabled ? bootstrapTunnel() : disableTunnel()
    }

    public func bootstrapTunnel() -> CloudflareOperationResult {
        let before = settings
        var dnsRouteForNewTunnel = false
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
        // Creating a tunnel and routing DNS both need the account origin
        // certificate. Checking here turns an opaque cloudflared failure into
        // the one instruction that actually unblocks setup.
        guard fileManager.fileExists(atPath: Self.originCertificatePath()) else {
            let status = status(
                messageOverride:
                    "Log in to Cloudflare first — Apple Core needs your account certificate to create a tunnel and route a hostname.",
                forcedState: .needsLogin
            )
            return CloudflareOperationResult(settings: settings, status: status, didChangeSettings: before != settings)
        }

        if settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let createdThisRun: Bool
            if let existingTunnelId = existingTunnelID(named: settings.tunnelName) {
                settings.tunnelId = existingTunnelId
                createdThisRun = false
            } else if let createdTunnelId = createTunnel() {
                settings.tunnelId = createdTunnelId
                settings.createdByAppleCore = true
                createdThisRun = true
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
            // A record that already exists is only suspicious when this run
            // just minted a brand-new tunnel: for it, any pre-existing CNAME
            // points somewhere else. For a rerun or a linked tunnel the
            // record is expected to be ours.
            dnsRouteForNewTunnel = createdThisRun
        }

        if settings.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.credentialsFilePath = defaultCredentialsPath(forTunnelID: settings.tunnelId)
        }

        var routingWarning: String?
        if settings.hostname.isEmpty {
            routingWarning =
                "No hostname set, so nothing is routed to this tunnel yet. Enter one such as mcp.\(settings.domain.isEmpty ? "example.com" : settings.domain)."
        } else if let invalid = Self.hostnameValidationError(for: settings.hostname) {
            routingWarning = invalid
        } else {
            routingWarning = ensureDNSRoute(createdThisRun: dnsRouteForNewTunnel)
        }

        writeCloudflaredConfigIfPossible()
        writeLaunchAgentIfPossible()
        var startStatus = startTunnel()
        // A tunnel that starts but routes nothing is not a success; say so
        // rather than letting "started" stand as the whole story.
        if let routingWarning {
            startStatus.message = routingWarning
            if startStatus.state == .running {
                startStatus.state = .error
            }
        }
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
        // launchctl bootstrap succeeding only means the job was loaded. If
        // cloudflared then exits — bad config, unroutable hostname — reporting
        // "started" next to a Stopped badge is worse than saying nothing.
        guard isLaunchAgentRunning() else {
            return status(
                messageOverride:
                    "Cloudflare tunnel was loaded but is not running. Check \(settings.configFilePath) and the cloudflared log.",
                forcedState: .error
            )
        }
        return status(messageOverride: "Cloudflare tunnel started.", forcedState: nil)
    }

    @discardableResult
    public func disableTunnel() -> CloudflareOperationResult {
        let before = settings
        settings.enabled = false

        if isLaunchAgentRunning() {
            let result = LaunchAgentManager.bootout(
                label: settings.launchAgentLabel,
                uid: uid,
                plistURL: launchAgentURL
            )
            if result.status != 0 {
                let tunnelStatus = status(
                    messageOverride: "Cloudflare tunnel failed to disable: \(sanitized(result.stderr))",
                    forcedState: .error
                )
                return CloudflareOperationResult(
                    settings: settings,
                    status: tunnelStatus,
                    didChangeSettings: before != settings
                )
            }
        }

        do {
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                try fileManager.removeItem(at: launchAgentURL)
            }
        } catch {
            let tunnelStatus = status(
                messageOverride:
                    "Cloudflare tunnel stopped, but its LaunchAgent could not be removed: \(error.localizedDescription)",
                forcedState: .error
            )
            return CloudflareOperationResult(
                settings: settings,
                status: tunnelStatus,
                didChangeSettings: before != settings
            )
        }

        let tunnelStatus = status(messageOverride: "Cloudflare tunnel disabled.", forcedState: .disabled)
        return CloudflareOperationResult(
            settings: settings,
            status: tunnelStatus,
            didChangeSettings: before != settings
        )
    }

    @discardableResult
    /// Where `cloudflared tunnel login` writes the account origin certificate.
    /// `TUNNEL_ORIGIN_CERT` overrides it, so honour that before assuming the
    /// default, or a machine configured that way reads as logged out forever.
    public static func originCertificatePath() -> String {
        if let override = ProcessInfo.processInfo.environment["TUNNEL_ORIGIN_CERT"],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return expandedPath(override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared/cert.pem")
            .path
    }

    /// Kicks off the browser-based Cloudflare login. The child process is not
    /// awaited — it stays alive until the person finishes authorizing in the
    /// browser — so the caller polls `status()` to notice the certificate.
    public func logInToCloudflare() -> CloudflareTunnelStatus {
        guard fileManager.fileExists(atPath: settings.cloudflaredPath) else {
            return status(
                messageOverride: "cloudflared is not installed at \(settings.cloudflaredPath).",
                forcedState: .missingCloudflared
            )
        }
        if let failure = runShellDetached(settings.cloudflaredPath, ["tunnel", "login"]) {
            return status(messageOverride: "Could not start Cloudflare login: \(failure)", forcedState: .error)
        }
        return status(
            messageOverride:
                "Finish the Cloudflare login in your browser, then choose Check Login. Apple Core is waiting for \(Self.originCertificatePath()).",
            forcedState: .needsLogin
        )
    }

    /// The cloudflared to use. Prefers whatever is actually installed —
    /// Homebrew, the system, or the copy Apple Core downloaded itself — and
    /// otherwise names the managed path, which is where the installer will put
    /// one. Returning the managed path rather than a Homebrew path that does
    /// not exist keeps the pane's "not installed" state pointing at the
    /// location the Install button will fill.
    public static func defaultCloudflaredPath() -> String {
        CloudflaredInstaller.locateInstalled() ?? CloudflaredInstaller.managedBinaryPath()
    }

    public static func publicBaseURL(for settings: CloudflareSettings) -> String {
        let hostname = settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostname.isEmpty ? "" : "https://\(hostname)"
    }

    /// Reduces whatever was typed into the Hostname field to the bare host
    /// that `cloudflared tunnel route dns` accepts. People reasonably paste
    /// the full connector URL they see elsewhere in Settings
    /// (`https://mcp.example.com/mcp`), and before this the whole string was
    /// handed to cloudflared, which rejected it as "not a valid hostname" —
    /// visible only in the log, so the tunnel silently never routed.
    public static func normalizedHostname(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        // Drop path, query and fragment, then any userinfo or :port.
        value = value.components(separatedBy: CharacterSet(charactersIn: "/?#"))[0]
        if let atIndex = value.lastIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        value = value.components(separatedBy: ":")[0]
        // A trailing dot is a legal FQDN root marker but cloudflared wants it gone.
        while value.hasSuffix(".") {
            value = String(value.dropLast())
        }
        return value
    }

    /// Returns a human-readable reason the hostname cannot be routed, or nil
    /// when it is usable. Empty is treated as valid-but-absent so the pane can
    /// distinguish "not configured yet" from "typed something wrong".
    public static func hostnameValidationError(for raw: String) -> String? {
        let host = normalizedHostname(raw)
        if host.isEmpty {
            return nil
        }
        let labels = host.components(separatedBy: ".")
        if labels.count < 2 {
            return "Enter a full hostname such as mcp.example.com, not just \(host)."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            if label.isEmpty {
                return "Hostname has an empty part — check for a doubled dot."
            }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                return "Hostname part \"\(label)\" cannot start or end with a hyphen."
            }
            if label.rangeOfCharacter(from: allowed.inverted) != nil {
                return "Hostname part \"\(label)\" has characters that are not letters, digits or hyphens."
            }
        }
        return nil
    }

    public static func normalizedSettings(_ settings: CloudflareSettings) -> CloudflareSettings {
        var normalized = settings
        if normalized.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.profileName = "Personal tunnel"
        }
        normalized.domain = normalizedHostname(normalized.domain)
        normalized.hostname = normalizedHostname(normalized.hostname)
        if normalized.hostname.isEmpty, !normalized.domain.isEmpty {
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
        return normalized
    }

    public static func cloudflaredConfigYAML(settings: CloudflareSettings, port: UInt16, bindHost: String) -> String {
        let tunnel =
            settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.tunnelName
            : settings.tunnelId
        let hostname = settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        var serviceHost = bindHost == "0.0.0.0" ? "127.0.0.1" : bindHost
        // A bare IPv6 literal is not a valid URL authority; cloudflared
        // would refuse to dial `http://::1:8756`. Bracket it.
        if serviceHost.contains(":") && !serviceHost.hasPrefix("[") {
            serviceHost = "[\(serviceHost)]"
        }
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
        let originCertificatePath = Self.originCertificatePath()
        let loggedIn = fileManager.fileExists(atPath: originCertificatePath)
        let hostnameError = Self.hostnameValidationError(for: settings.hostname)

        let inferredState: CloudflareTunnelState
        let inferredMessage: String
        if !settings.enabled {
            inferredState = .disabled
            inferredMessage = "Cloudflare is disabled."
        } else if !cloudflaredInstalled {
            inferredState = .missingCloudflared
            inferredMessage = "cloudflared is not installed."
        } else if !loggedIn {
            inferredState = .needsLogin
            inferredMessage = "Log in to Cloudflare to let Apple Core create a tunnel and route a hostname."
        } else if settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !credentialsFileExists {
            inferredState = .needsTunnel
            inferredMessage = "Cloudflare tunnel has not been created or linked yet."
        } else if let hostnameError {
            inferredState = .error
            inferredMessage = hostnameError
        } else if settings.hostname.isEmpty {
            inferredState = .needsConfig
            inferredMessage = "Set a hostname so Cloudflare knows what address to route here."
        } else if !configFileExists || !launchAgentInstalled {
            inferredState = .needsConfig
            inferredMessage = "Cloudflare local config or LaunchAgent needs to be created."
        } else if launchAgentRunning {
            inferredState = .running
            inferredMessage = "Cloudflare tunnel is running at \(Self.publicBaseURL(for: settings))."
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
            createdByAppleCore: settings.createdByAppleCore,
            loggedIn: loggedIn,
            originCertificatePath: originCertificatePath,
            hostnameError: hostnameError
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

    /// Returns nil on success, or a message describing why the DNS route could
    /// not be created. The caller surfaces that in the pane: routing failures
    /// used to be logged and discarded, so a tunnel that could never resolve
    /// still reported itself as started.
    private func ensureDNSRoute(createdThisRun: Bool) -> String? {
        let tunnel =
            settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.tunnelName
            : settings.tunnelId
        let result = runShell(settings.cloudflaredPath, ["tunnel", "route", "dns", tunnel, settings.hostname])
        if result.status == 0 {
            return nil
        }

        let combined = "\(result.stdout)\n\(result.stderr)".lowercased()
        if combined.contains("already exists") || combined.contains("record exists") {
            // For a brand-new tunnel, an existing record cannot be ours: it
            // points at another tunnel or origin, and reporting success sent
            // users chasing ghosts on a setup that looked healthy and could
            // never work. Reruns and linked tunnels expect the record.
            if createdThisRun {
                return
                    "\(settings.hostname) already has a DNS record pointing elsewhere. Verify it points at tunnel \(tunnel), or delete the record and retry."
            }
            return nil
        }

        let detail = sanitized(result.stderr).isEmpty ? sanitized(result.stdout) : sanitized(result.stderr)
        logMessage("CloudflareManager: DNS route setup failed: \(detail)")
        if combined.contains("cert.pem") || combined.contains("login") || combined.contains("origincert") {
            return "Cloudflare login required before \(settings.hostname) can be routed. Use Log In to Cloudflare."
        }
        return "Could not route \(settings.hostname) to this tunnel: \(detail)"
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
