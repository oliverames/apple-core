// SPDX-License-Identifier: GPL-3.0-or-later
//
// Observable state backing the Settings window. Adapted from the settings
// surface of Bridgeport's AppState (bridgeport/Sources/bridgeport/AppState.swift
// as consumed by its SettingsView), reworked for Apple Core: instead of
// external connector processes there is one fixed set of in-process service
// surfaces, so this model wraps `AppleCoreServingConfig` plus the ported
// Cloudflare/LaunchAgent/OAuth managers in App/Services/Serving/.

import AppKit
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class ServingSettingsModel: ObservableObject {
    @Published var config: AppleCoreServingConfig
    @Published var portText: String
    @Published var bindHost: String
    @Published var allowedOriginsText: String
    @Published var cloudflareStatus: CloudflareTunnelStatus?
    @Published var registeredOAuthClients: [OAuthRegisteredClient] = []
    @Published var isShowingToken = false
    @Published var isAppLaunchAgentLoaded = false
    @Published var isOpenAtLoginEnabled = false
    @Published var lastStatusMessage = "Ready"

    @AppStorage("runAsLaunchAgent") var runAsLaunchAgent = true

    private weak var serverController: ServerController?

    init(serverController: ServerController) {
        self.serverController = serverController
        let loaded = ServingConfigManager.load()
        self.config = loaded
        self.portText = String(loaded.port ?? 8756)
        self.bindHost = loaded.bindHost ?? "127.0.0.1"
        self.allowedOriginsText = (loaded.allowedOrigins ?? []).joined(separator: "\n")
        refreshAppLaunchAgentStatus()
        refreshOpenAtLoginStatus()
        reloadOAuthClients()
    }

    var port: UInt16 {
        UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? config.port ?? 8756
    }

    var token: String {
        config.token ?? ""
    }

    var localBaseURL: String {
        "http://\(bindHost.isEmpty ? "127.0.0.1" : bindHost):\(port)"
    }

    var publicBaseURL: String {
        config.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var clientBaseURL: String {
        ServingConfigManager.clientEndpointBaseURL(port: port, publicBaseURL: config.publicBaseURL)
    }

    var cloudflare: CloudflareSettings {
        get { config.cloudflare ?? CloudflareSettings() }
        set { config.cloudflare = newValue }
    }

    var allowQueryTokenAuth: Bool {
        get { config.allowQueryTokenAuth ?? false }
        set { config.allowQueryTokenAuth = newValue }
    }

    func exposePubliclyBinding(forServiceID serviceID: String) -> Binding<Bool> {
        Binding(
            get: { self.config.settings(forServiceID: serviceID).exposePublicly },
            set: { newValue in
                var settings = self.config.serviceSettings ?? [:]
                settings[serviceID] = ServingServiceSettings(exposePublicly: newValue)
                self.config.serviceSettings = settings
                self.save()
            }
        )
    }

    func publiclyExposedServiceCount(from configs: [ServiceConfig]) -> Int {
        configs.filter { config.settings(forServiceID: $0.id).exposePublicly }.count
    }

    // MARK: - Persistence

    /// Re-reads the config file so edits made outside the app (or by the
    /// serving stack) show up; the model otherwise loads it once at init.
    /// Called when panes appear, so it also overwrites any un-saved edits
    /// in the port/host/origins fields with the on-disk values.
    func reloadConfigFromDisk() {
        let loaded = ServingConfigManager.load()
        config = loaded
        portText = String(loaded.port ?? 8756)
        bindHost = loaded.bindHost ?? "127.0.0.1"
        allowedOriginsText = (loaded.allowedOrigins ?? []).joined(separator: "\n")
    }

    /// Persists the model's edits and restarts the HTTP server so the new
    /// values take effect (the server reads its config once at startup).
    ///
    /// Non-destructive by construction: instead of writing the in-memory
    /// snapshot wholesale (which once deleted a cloudflare block written to
    /// the file by another process while this model held a stale copy), it
    /// re-loads the on-disk config and overlays only the fields this window
    /// edits — and overlays optional sub-blocks only when the model actually
    /// has a value for them. Unknown/untouched keys keep their disk values.
    func save(restartServer: Bool = true) {
        var merged = ServingConfigManager.load()

        if let parsedPort = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), parsedPort > 0 {
            merged.port = parsedPort
        }
        let trimmedHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        merged.bindHost = trimmedHost.isEmpty ? "127.0.0.1" : trimmedHost

        let origins =
            allowedOriginsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        merged.allowedOrigins = origins.isEmpty ? nil : origins

        if let token = config.token {
            merged.token = token
        }
        if let allowQueryTokenAuth = config.allowQueryTokenAuth {
            merged.allowQueryTokenAuth = allowQueryTokenAuth
        }
        if let serviceSettings = config.serviceSettings {
            merged.serviceSettings = serviceSettings
        }
        if let cloudflare = config.cloudflare {
            merged.cloudflare = cloudflare
        }
        if let publicBaseURL = config.publicBaseURL {
            merged.publicBaseURL = publicBaseURL
        }

        config = merged
        ServingConfigManager.save(merged)
        lastStatusMessage = "Saved"

        if restartServer {
            Task {
                await serverController?.stopServer()
                await serverController?.startServer()
                lastStatusMessage = "Saved; server restarted"
            }
        }
    }

    func rotateToken() {
        config.token = ServingConfigManager.generateSecureToken()
        save()
        lastStatusMessage = "Token rotated"
    }

    // MARK: - Cloudflare

    private func cloudflareManager() -> CloudflareManager {
        CloudflareManager(settings: cloudflare, port: port, bindHost: bindHost)
    }

    func refreshCloudflareStatus() async {
        cloudflareStatus = await cloudflareManager().status()
    }

    func prepareCloudflareConfiguration() async {
        config.publicBaseURL = CloudflareManager.publicBaseURL(for: cloudflare)
        let result = await cloudflareManager().prepareLocalConfiguration()
        applyCloudflareResult(result)
    }

    func bootstrapCloudflareTunnel() async {
        let result = await cloudflareManager().bootstrapTunnel()
        applyCloudflareResult(result)
    }

    func startCloudflareTunnel() async {
        cloudflareStatus = await cloudflareManager().startTunnel()
    }

    func stopCloudflareTunnel() async {
        cloudflareStatus = await cloudflareManager().stopTunnel()
    }

    func restartCloudflareTunnel() async {
        cloudflareStatus = await cloudflareManager().restartTunnel()
    }

    private func applyCloudflareResult(_ result: CloudflareOperationResult) {
        if result.didChangeSettings {
            config.cloudflare = result.settings
            save(restartServer: false)
        }
        cloudflareStatus = result.status
        lastStatusMessage = result.status.message
    }

    // MARK: - OAuth Clients

    /// The client registry file is owned by `OAuthTokenStore`; this reads the
    /// same JSON for display. (`OAuthTokenStore` has no list/revoke API yet.)
    func reloadOAuthClients() {
        struct Registry: Codable {
            let clients: [OAuthRegisteredClient]
        }
        let url = AppleCoreServingPaths.oauthClientRegistryURL()
        guard let data = try? Data(contentsOf: url),
            let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else {
            registeredOAuthClients = []
            return
        }
        registeredOAuthClients = registry.clients.sorted { $0.issuedAt > $1.issuedAt }
    }

    // MARK: - Open at Login

    /// Standard login item via SMAppService: opens the app (menu bar icon)
    /// at login. Distinct from the LaunchAgent below, which is a keep-alive
    /// daemon lifecycle; status can change in System Settings, so refresh
    /// whenever the pane appears.
    func refreshOpenAtLoginStatus() {
        isOpenAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastStatusMessage = enabled ? "Open at Login enabled" : "Open at Login disabled"
        } catch {
            Logger.server.error(
                "Open at Login update failed: \(error.localizedDescription, privacy: .public)"
            )
            lastStatusMessage = "Open at Login update failed: \(error.localizedDescription)"
        }
        refreshOpenAtLoginStatus()
    }

    // MARK: - LaunchAgent

    func refreshAppLaunchAgentStatus() {
        isAppLaunchAgentLoaded = LaunchAgentManager.isLoaded(label: AppLaunchAgent.label, uid: getuid())
    }

    func installAppLaunchAgent() {
        AppLaunchAgent.installIfNeeded()
        refreshAppLaunchAgentStatus()
        lastStatusMessage = isAppLaunchAgentLoaded ? "LaunchAgent installed" : "LaunchAgent install failed; see log"
    }

    func removeAppLaunchAgent() {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppLaunchAgent.label).plist")
        let result = LaunchAgentManager.bootout(label: AppLaunchAgent.label, uid: getuid(), plistURL: plistURL)
        try? FileManager.default.removeItem(at: plistURL)
        refreshAppLaunchAgentStatus()
        lastStatusMessage = result.succeeded ? "LaunchAgent removed" : "LaunchAgent removal failed; see log"
    }
}
