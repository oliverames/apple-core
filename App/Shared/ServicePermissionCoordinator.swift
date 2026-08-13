// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Presents service permission requests from an app state where Tahoe can
/// actually show them. `NSApplication.activate()` is only a request, so this
/// coordinator temporarily promotes the menu-bar app to a regular app and
/// keeps requesting activation before touching TCC-protected APIs. Activation
/// is best-effort: the permission request proceeds even if the app never
/// observes itself becoming active, because the services now detect and
/// report a prompt that macOS refused to display.
@MainActor
enum ServicePermissionCoordinator {
    private struct PresentationContext {
        let restoreAccessoryPolicy: Bool
    }

    static func activate(
        _ service: any Service,
        requirements: [ServicePermissionRequirement]
    ) async throws {
        guard !requirements.isEmpty else {
            try await service.activate()
            return
        }

        let context = await prepareForPermissionPresentation()
        defer { restorePresentation(context) }
        try await service.activate()
    }

    private static func prepareForPermissionPresentation() async -> PresentationContext {
        let restoreAccessoryPolicy =
            NSApp.activationPolicy() == .accessory && NSApp.setActivationPolicy(.regular)

        // App activation is asynchronous and not guaranteed, and a single
        // cooperative request issued from a status-menu action is routinely
        // ignored while menu tracking winds down. Re-request every poll
        // iteration instead of once, and treat activation as best-effort:
        // aborting here guarantees no prompt, while proceeding lets tccd
        // decide whether it can present one.
        for _ in 0 ..< 40 where !NSApp.isActive {
            NSApp.activate()
            try? await Task.sleep(for: .milliseconds(50))
        }

        return PresentationContext(restoreAccessoryPolicy: restoreAccessoryPolicy)
    }

    private static func restorePresentation(_ context: PresentationContext) {
        guard context.restoreAccessoryPolicy else { return }

        let dockIconRequested =
            UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        let settingsWindowVisible = NSApp.windows.contains {
            $0.identifier?.rawValue == "AppleCoreSettingsWindow" && $0.isVisible
        }
        if !dockIconRequested && !settingsWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
