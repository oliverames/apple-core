import AppKit
import MenuBarExtraAccess
import OSLog
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
            Logger.server.info("AppLaunchAgent: not running from an .app bundle in place, skipping LaunchAgent registration")
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
            Logger.server.error("AppLaunchAgent: failed to install LaunchAgent: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @AppStorage("runAsLaunchAgent") private var runAsLaunchAgent = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard runAsLaunchAgent else { return }
        AppLaunchAgent.installIfNeeded()
    }
}

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @State private var isMenuPresented = false

    var body: some Scene {
        MenuBarExtra("iMCP", image: #"MenuIcon-\#(isEnabled ? "On" : "Off")"#) {
            ContentView(
                serverManager: serverController,
                isEnabled: $isEnabled,
                isMenuPresented: $isMenuPresented
            )
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: $isMenuPresented)

        Settings {
            SettingsView(serverController: serverController)
        }

        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
