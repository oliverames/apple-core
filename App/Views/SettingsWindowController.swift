// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppKit-managed Settings window. Adapted from Bridgeport's
// SettingsWindowController.swift and ping-warden's showSettingsWindow
// pattern (PingWardenApp.swift): the SwiftUI Settings scene stays a
// phantom that only hosts the ⌘, command, while the real window is an
// NSWindow the app delegate opens on demand, flipping the activation
// policy so the accessory menu bar app fronts correctly.

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let serverController: ServerController
    private let model: ServingSettingsModel
    private var dockIconWasVisible = false
    private var window: NSWindow?

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    init(serverController: ServerController) {
        self.serverController = serverController
        self.model = ServingSettingsModel(serverController: serverController)
        super.init()
    }

    func show() {
        dockIconWasVisible = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        if !dockIconWasVisible {
            NSApp.setActivationPolicy(.regular)
        }

        if window == nil {
            let initialSize = NSSize(width: 980, height: 680)
            let hostingController = NSHostingController(
                rootView: SettingsView(serverController: serverController, model: model)
            )
            hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
            hostingController.sceneBridgingOptions = .all

            let newWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Apple Core Settings"
            newWindow.identifier = NSUserInterfaceItemIdentifier("AppleCoreSettingsWindow")
            newWindow.contentViewController = hostingController
            newWindow.minSize = NSSize(width: 860, height: 560)
            newWindow.isReleasedWhenClosed = false
            newWindow.toolbarStyle = .unified
            newWindow.tabbingMode = .disallowed
            newWindow.center()
            newWindow.setFrameAutosaveName("AppleCoreSettings")
            newWindow.delegate = self
            window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // If the user has explicitly opted into showing the Dock icon,
        // keep it visible; otherwise go back to accessory (menu bar only).
        if dockIconWasVisible {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
