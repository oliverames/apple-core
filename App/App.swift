// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu bar lifecycle reworked to follow ping-warden's execution pattern
// (ping-warden/PingWarden/PingWarden/PingWardenApp.swift): an
// NSApplicationDelegate owns an NSStatusItem + NSMenu directly (no
// MenuBarExtra/MenuBarExtraAccess), the SwiftUI Settings scene is a
// phantom that only hosts the app-settings command, and the real
// Settings window is AppKit-managed with activation-policy switching.

import AppKit
import OSLog
import Sparkle
import SwiftUI

/// Registers Apple Core as a per-user LaunchAgent so it keeps running (and
/// relaunches at login) like a background daemon, mirroring Bridgeport's
/// LaunchAgentManager-based daemon lifecycle. Unlike Bridgeport, there is no
/// separate daemon binary here -- the LaunchAgent simply relaunches this
/// same app bundle's executable in place, which is required for TCC to keep
/// recognizing it (see LaunchAgentManager.bundleExecutablePath).
enum AppLaunchAgent {
    static let label = "com.oliverames.applecore.launchagent"

    @MainActor
    static func installIfNeeded() {
        // Only offer this for a build actually running from an installed
        // .app bundle; a bare DerivedData/Xcode run still resolves to a
        // ".app/Contents/MacOS/" path, so this covers normal development
        // and installed builds alike, but not `swift run`-style bare
        // binaries (which have no stable path to relaunch anyway).
        guard let executablePath = Bundle.main.executablePath,
            let stableExecutablePath = LaunchAgentManager.bundleExecutablePath(for: executablePath)
        else {
            Logger.server.info(
                "AppLaunchAgent: not running from an .app bundle in place, skipping LaunchAgent registration"
            )
            return
        }

        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")

        do {
            let logDirectory = AppleCoreServingPaths.configDirectory()
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

            let plistData = try LaunchAgentPlist.makeData(
                label: label,
                executablePath: stableExecutablePath,
                stdoutPath: logDirectory.appendingPathComponent("applecore_stdout.log").path,
                stderrPath: logDirectory.appendingPathComponent("applecore_stderr.log").path
            )

            let plistDirectory = plistURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: plistDirectory.path) {
                try FileManager.default.createDirectory(at: plistDirectory, withIntermediateDirectories: true)
            }
            try plistData.write(to: plistURL, options: .atomic)

            #if os(macOS)
                let uid = getuid()
            #else
                let uid: UInt32 = 0
            #endif
            if !LaunchAgentManager.isLoaded(label: label, uid: uid) {
                let result = LaunchAgentManager.bootstrap(label: label, uid: uid, plistURL: plistURL)
                if !result.succeeded {
                    Logger.server.error("AppLaunchAgent: bootstrap failed: \(result.stderr, privacy: .public)")
                }
            }
        } catch {
            Logger.server.error(
                "AppLaunchAgent: failed to install LaunchAgent: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let enableItemTag = 100
    private static let servicesHeaderTag = 110
    private static let checkForUpdatesItemTag = 120

    private let serverController = ServerController()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?

    // Sparkle auto-updating, following ping-warden's pattern
    // (PingWardenApp.swift): the controller is created with
    // startingUpdater: false and started explicitly so a startup failure can
    // be logged and surfaced instead of silently disabling updates. The feed
    // URL and public EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey)
    // as the single source of truth.
    private var updaterController: SPUStandardUpdaterController?
    private var updaterStartupError: Error?
    private var updaterHasStarted = false

    private var runAsLaunchAgent: Bool {
        UserDefaults.standard.object(forKey: "runAsLaunchAgent") as? Bool ?? true
    }

    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "isEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runAsLaunchAgent {
            AppLaunchAgent.installIfNeeded()
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        _ = startUpdaterIfNeeded()

        setupMenuBar()

        Task {
            await serverController.setEnabled(isEnabled)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Lockout recovery, as in ping-warden: re-opening the app with no
        // visible windows always opens Settings.
        if !flag {
            openSettings()
        }
        return true
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard statusItem?.button != nil else {
            Logger.server.error("Failed to create status item button")
            return
        }

        updateMenuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        // Manual isEnabled/state control: with autoenablesItems left on,
        // AppKit re-enables items every time the menu opens, overriding the
        // assignments in refreshMenuState().
        menu.autoenablesItems = false

        let enableItem = NSMenuItem(
            title: "Enable MCP Server",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.tag = Self.enableItemTag
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let servicesHeader = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesHeader.isEnabled = false
        servicesHeader.tag = Self.servicesHeaderTag
        menu.addItem(servicesHeader)

        for config in serverController.computedServiceConfigs {
            let item = NSMenuItem(
                title: config.name,
                action: #selector(toggleService(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = config.id
            item.image = serviceSymbol(config.iconName)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updatesItem.target = self
        updatesItem.tag = Self.checkForUpdatesItemTag
        menu.addItem(updatesItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: "About Apple Core",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Apple Core",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem?.menu = menu
        refreshMenuState()
    }

    private func serviceSymbol(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        // Per Oliver: a logo showing one thing connecting to another. The
        // symbol depicts two apps joined by a link; the disabled state dims
        // via the button's system disabled appearance. Falls back to the
        // legacy asset images if the symbol is unavailable on the running OS.
        let symbolName = "app.connected.to.app.below.fill"
        let image: NSImage?
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            image = symbol.withSymbolConfiguration(configuration) ?? symbol
        } else {
            image = NSImage(named: isEnabled ? "MenuIcon-On" : "MenuIcon-Off")
        }
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !isEnabled
        button.toolTip = isEnabled ? "Apple Core: MCP server enabled" : "Apple Core: MCP server disabled"
        button.setAccessibilityLabel(button.toolTip)
    }

    private func refreshMenuState() {
        guard let menu = statusMenu else { return }

        let bindings = serviceBindings()

        if let enableItem = menu.items.first(where: { $0.tag == Self.enableItemTag }) {
            enableItem.state = isEnabled ? .on : .off
        }

        for item in menu.items {
            guard let serviceID = item.representedObject as? String else { continue }
            item.state = (bindings[serviceID]?.wrappedValue ?? false) ? .on : .off
            item.isEnabled = isEnabled
        }

        if let updatesItem = menu.items.first(where: { $0.tag == Self.checkForUpdatesItemTag }) {
            // Mirror ping-warden: keep the item clickable while no update
            // session is running; a startup failure is surfaced on click.
            let sessionInProgress = updaterController?.updater.sessionInProgress ?? false
            updatesItem.isEnabled = !sessionInProgress
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        refreshMenuState()
    }

    private func serviceBindings() -> [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: serverController.computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        updateMenuBarIcon()
        refreshMenuState()
        Task {
            await serverController.setEnabled(isEnabled)
        }
    }

    @objc private func toggleService(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String,
            let config = serverController.computedServiceConfigs.first(where: { $0.id == serviceID })
        else { return }

        config.binding.wrappedValue.toggle()

        if config.binding.wrappedValue {
            Task {
                do {
                    try await config.service.activate()
                } catch {
                    config.binding.wrappedValue = false
                    self.refreshMenuState()
                }
            }
        }

        refreshMenuState()
        let bindings = serviceBindings()
        Task {
            await serverController.updateServiceBindings(bindings)
        }
    }

    @objc private func checkForUpdates() {
        guard startUpdaterIfNeeded() else {
            presentUpdaterStartFailureAlert()
            return
        }
        if let activeFeedURL = updaterController?.updater.feedURL?.absoluteString {
            Logger.server.info("Checking Sparkle updates from feed: \(activeFeedURL, privacy: .public)")
        }
        updaterController?.updater.checkForUpdates()
    }

    @discardableResult
    private func startUpdaterIfNeeded() -> Bool {
        guard let updater = updaterController?.updater else {
            return false
        }
        if updaterHasStarted {
            return true
        }
        do {
            try updater.start()
            updaterHasStarted = true
            updaterStartupError = nil
            return true
        } catch {
            updaterStartupError = error
            Logger.server.error(
                "Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func presentUpdaterStartFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText =
            updaterStartupError?.localizedDescription
            ?? "The update system could not be started. Please try again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(serverController: serverController)
        }
        settingsWindowController?.show()
    }

    @objc private func openAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Intentionally empty, and intentionally without a fixed frame
            // (see ping-warden's PingWardenApp for the macOS 26 constraint
            // crash this avoids). This phantom scene exists only to host the
            // app-settings command group below; the real Settings window is
            // AppKit-managed by AppDelegate/SettingsWindowController.
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
