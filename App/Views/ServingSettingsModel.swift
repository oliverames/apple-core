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

    /// Non-nil while cloudflared is being downloaded and installed.
    @Published var cloudflaredInstallProgress: CloudflaredInstallProgress?
    /// The version of the cloudflared currently in use, for display.
    @Published var cloudflaredVersion: String?
    /// What the Cloudflare login told us: account, zone, and domain. Populated
    /// after sign-in so the pane can stop asking for any of it.
    @Published var cloudflareAccount: CloudflareAccountInfo?
    /// Set when a remote-access step failed, for display next to the control
    /// that started it.
    @Published var cloudflareSetupError: String?
    /// True while the whole remote-access sequence is running.
    @Published var isConfiguringRemoteAccess = false
    /// The one line of progress shown while that sequence runs.
    @Published var remoteSetupStage: String?
    /// Set when the address could not be derived and has to be typed after all.
    @Published var needsManualHostname = false

    /// Drives the first-run sheet. Onboarding is presented on the Settings
    /// window rather than as a window of its own, matching skylight-bridge.
    @Published var isOnboardingPresented = false

    static let onboardingCompletedDefaultsKey = "hasCompletedOnboarding"

    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: onboardingCompletedDefaultsKey)
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedDefaultsKey)
        isOnboardingPresented = false
    }

    @AppStorage("runAsLaunchAgent") var runAsLaunchAgent = true
    @AppStorage("showDockIcon") var showDockIcon = false

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
        let before = config
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

        // The HTTP server reads its config once at startup, so a wizard step
        // that saves with restartServer:false still has to bounce it when a
        // field the server froze actually changed — otherwise the live server
        // keeps advertising the pre-tunnel OAuth issuer and enforcing the
        // stale origin allowlist until relaunch.
        let serverVisibleFieldsChanged =
            before.publicBaseURL != merged.publicBaseURL
            || before.allowedOrigins != merged.allowedOrigins
            || before.port != merged.port
            || before.bindHost != merged.bindHost
            || before.token != merged.token

        if restartServer || serverVisibleFieldsChanged {
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
        // Pick up a cloudflared that appeared since the config was written —
        // installed by Apple Core, or by Homebrew behind its back.
        if let located = CloudflaredInstaller.locateInstalled(), located != cloudflare.cloudflaredPath {
            var settings = cloudflare
            settings.cloudflaredPath = located
            cloudflare = settings
            save(restartServer: false)
        }
        cloudflareStatus = await cloudflareManager().status()
        cloudflaredVersion = CloudflaredInstaller.locateInstalled().flatMap {
            CloudflaredInstaller.installedVersion(at: $0)
        }
        // Deliberately does NOT derive the Cloudflare account here. Doing so
        // whenever a cert.pem happened to exist wrote a hostname and a public
        // base URL into the config of someone who had chosen this Mac only,
        // and then showed them that address as if it were live. Deriving is
        // part of setting up remote access, so it happens there.
    }

    // MARK: - Filesystem roots

    /// Folders the filesystem surface may touch. Empty by default; the
    /// surface can reach nothing until the user adds one.
    var filesystemRoots: [FilesystemRoot] {
        get { config.filesystemRoots ?? [] }
        set {
            config.filesystemRoots = newValue.isEmpty ? nil : newValue
            save(restartServer: false)
        }
    }

    /// Adds a folder, refusing duplicates and folders already covered by an
    /// existing root — sharing ~/Documents twice, or sharing it and then a
    /// folder inside it, only makes the list harder to reason about.
    func addFilesystemRoot(_ url: URL, writable: Bool) {
        let path = FilesystemAccess.canonicalize(url.path)
        var roots = filesystemRoots
        if roots.contains(where: { FilesystemAccess.isContained(path, in: FilesystemAccess.canonicalize($0.path)) }) {
            lastStatusMessage = "That folder is already covered by one you have shared."
            return
        }
        // Drop any existing roots the new one now contains.
        roots.removeAll { FilesystemAccess.isContained(FilesystemAccess.canonicalize($0.path), in: path) }
        roots.append(FilesystemRoot(path: path, writable: writable))
        filesystemRoots = roots.sorted { $0.path < $1.path }
    }

    func removeFilesystemRoot(_ root: FilesystemRoot) {
        filesystemRoots = filesystemRoots.filter { $0.path != root.path }
    }

    func setFilesystemRoot(_ root: FilesystemRoot, writable: Bool) {
        filesystemRoots = filesystemRoots.map {
            $0.path == root.path ? FilesystemRoot(path: $0.path, writable: writable) : $0
        }
    }

    // MARK: - cloudflared installation

    var isCloudflaredInstalled: Bool {
        CloudflaredInstaller.locateInstalled() != nil
    }

    /// Downloads and installs cloudflared, then points the config at it.
    /// Returns true on success so a caller running the full setup sequence can
    /// stop at the first failure.
    @discardableResult
    func installCloudflared() async -> Bool {
        cloudflareSetupError = nil
        let installer = CloudflaredInstaller()
        do {
            let path = try await installer.install { [weak self] progress in
                Task { @MainActor in self?.cloudflaredInstallProgress = progress }
            }
            var settings = cloudflare
            settings.cloudflaredPath = path
            cloudflare = settings
            save(restartServer: false)
            cloudflaredInstallProgress = nil
            await refreshCloudflareStatus()
            lastStatusMessage = "cloudflared installed"
            return true
        } catch {
            cloudflaredInstallProgress = nil
            cloudflareSetupError = error.localizedDescription
            lastStatusMessage = "cloudflared install failed"
            return false
        }
    }

    // MARK: - Derived account

    /// Reads the account, zone and domain out of the Cloudflare login and
    /// fills them in, so none of the three has to be typed. Leaves a hostname
    /// the user already chose alone.
    func refreshCloudflareAccount() async {
        guard let info = try? await CloudflareAccount.resolve() else {
            cloudflareAccount = nil
            return
        }
        cloudflareAccount = info

        var settings = cloudflare
        var changed = false
        if settings.accountId.isEmpty, !info.accountID.isEmpty {
            settings.accountId = info.accountID
            changed = true
        }
        if settings.zoneId.isEmpty, !info.zoneID.isEmpty {
            settings.zoneId = info.zoneID
            changed = true
        }
        if let domain = info.domain, !domain.isEmpty, settings.domain != domain {
            settings.domain = domain
            changed = true
        }
        if settings.hostname.isEmpty, let suggested = info.suggestedHostname {
            settings.hostname = suggested
            changed = true
        }
        if changed {
            cloudflare = settings
            // The public base URL is what clients are told to use, so it is
            // only recorded once remote access is actually being turned on.
            if settings.enabled {
                setPublicBaseURL(CloudflareManager.publicBaseURL(for: settings))
            }
            save(restartServer: false)
        }
    }

    // MARK: - One-step remote access

    /// Everything remote access needs, start to finish, behind one action:
    /// install cloudflared, sign in to Cloudflare, read the account and domain
    /// out of that sign-in, choose an address, create the tunnel and route it.
    ///
    /// The pane used to expose this same sequence as a prerequisite checklist
    /// plus four repair verbs in a menu, and left both the ordering and the
    /// identifiers to the user. None of those steps is a decision — they are
    /// all consequences of one decision, which is whether to have remote
    /// access at all. So the sequence runs, and only its progress is shown.
    func setUpRemoteAccess() async {
        isConfiguringRemoteAccess = true
        defer {
            isConfiguringRemoteAccess = false
            remoteSetupStage = nil
        }
        cloudflareSetupError = nil

        if !isCloudflaredInstalled {
            guard await installCloudflared() else { return }
        }

        if !CloudflareAccount.isSignedIn() {
            remoteSetupStage = "Waiting for you to sign in to Cloudflare in your browser…"
            await performCloudflareLogin()
            guard CloudflareAccount.isSignedIn() else {
                cloudflareSetupError =
                    "The Cloudflare sign-in did not finish. Try again, and approve the domain you want to use."
                return
            }
        }

        remoteSetupStage = "Reading your Cloudflare account…"
        await refreshCloudflareAccount()

        guard !cloudflare.hostname.isEmpty else {
            cloudflareSetupError =
                "Apple Core could not work out an address from your Cloudflare account. Enter one below."
            needsManualHostname = true
            return
        }
        if let invalid = CloudflareManager.hostnameValidationError(for: cloudflare.hostname) {
            cloudflareSetupError = invalid
            needsManualHostname = true
            return
        }

        var settings = cloudflare
        settings.enabled = true
        cloudflare = settings
        setPublicBaseURL(CloudflareManager.publicBaseURL(for: settings))
        save(restartServer: false)

        remoteSetupStage = "Creating the tunnel and routing \(settings.hostname)…"
        await bootstrapCloudflareTunnel()

        if let status = cloudflareStatus, status.state == .error {
            cloudflareSetupError = status.message
        }
    }

    func prepareCloudflareConfiguration() async {
        setPublicBaseURL(CloudflareManager.publicBaseURL(for: cloudflare))
        let result = await cloudflareManager().prepareLocalConfiguration()
        applyCloudflareResult(result)
    }

    func bootstrapCloudflareTunnel() async {
        // Text fields only commit on Return, so a hostname that was typed and
        // then clicked away from was still absent from disk when the tunnel
        // was set up. Normalize and persist what is on screen first.
        normalizeCloudflareHostFields()
        save(restartServer: false)
        let result = await cloudflareManager().bootstrapTunnel()
        applyCloudflareResult(result)
    }

    func setCloudflareEnabled(_ enabled: Bool) async {
        var settings = cloudflare
        settings.enabled = enabled
        cloudflare = settings
        setPublicBaseURL(CloudflareManager.publicBaseURL(for: settings))
        let result = await cloudflareManager().reconcileTunnel()
        applyCloudflareResult(result)
    }

    func startCloudflareTunnel() async {
        cloudflareStatus = await cloudflareManager().startTunnel()
    }

    /// Opens the Cloudflare browser sign-in and waits for it, rather than
    /// making the user come back and press a second "Check Login" button. The
    /// certificate appears on disk the moment they authorize, so poll for it.
    private func performCloudflareLogin() async {
        cloudflareStatus = await cloudflareManager().logInToCloudflare()

        // Two minutes is long enough to find the right Cloudflare account in a
        // browser and short enough that an abandoned sign-in stops spinning.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if CloudflareAccount.isSignedIn() {
                await refreshCloudflareAccount()
                await refreshCloudflareStatus()
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        await refreshCloudflareStatus()
    }

    /// Cleans up whatever was typed into Domain or Hostname the moment the
    /// field is committed, so the pane shows the value cloudflared will
    /// actually receive rather than silently rejecting it later.
    func normalizeCloudflareHostFields() {
        var settings = cloudflare
        settings.domain = CloudflareManager.normalizedHostname(settings.domain)
        settings.hostname = CloudflareManager.normalizedHostname(settings.hostname)
        if settings.hostname.isEmpty, !settings.domain.isEmpty {
            settings.hostname = "mcp.\(settings.domain)"
        }
        if settings != cloudflare {
            cloudflare = settings
        }
        setPublicBaseURL(CloudflareManager.publicBaseURL(for: settings))
    }

    /// Records the tunnel's public base URL and makes sure the matching origin
    /// is allowed. The two were tracked independently, so a config written
    /// before the hostname existed kept a localhost-only origin list and an
    /// OAuth issuer of `http://localhost:<port>` — cloud clients then followed
    /// discovery metadata that pointed at the user's own machine.
    private func setPublicBaseURL(_ url: String) {
        config.publicBaseURL = url
        let required = ServingConfigManager.defaultAllowedOrigins(
            port: port,
            publicBaseURL: url
        )
        var origins = config.allowedOrigins ?? []
        for origin in required where !origins.contains(origin) {
            origins.append(origin)
        }
        config.allowedOrigins = origins.sorted()
    }

    func stopCloudflareTunnel() async {
        let result = await cloudflareManager().disableTunnel()
        applyCloudflareResult(result)
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

    private static func loadLaunchAgentStatusOffMain() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            LaunchAgentManager.isLoaded(label: AppLaunchAgent.label, uid: getuid())
        }.value
    }

    func refreshAppLaunchAgentStatus() {
        // `launchctl print` blocks; run it off the main thread so opening
        // Settings or Diagnostics never waits on launchd.
        Task(priority: .userInitiated) {
            isAppLaunchAgentLoaded = await Self.loadLaunchAgentStatusOffMain()
        }
    }

    func installAppLaunchAgent() {
        Task(priority: .userInitiated) {
            await Task.detached(priority: .userInitiated) {
                AppLaunchAgent.installIfNeeded()
            }.value
            let loaded = await Self.loadLaunchAgentStatusOffMain()
            isAppLaunchAgentLoaded = loaded
            lastStatusMessage =
                loaded ? "LaunchAgent installed" : "LaunchAgent install failed; see log"
        }
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
