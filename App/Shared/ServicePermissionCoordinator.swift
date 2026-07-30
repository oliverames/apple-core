// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Presents service permission requests from an app state where Tahoe can
/// actually show them. `NSApplication.activate()` is only a request, so this
/// coordinator temporarily promotes the menu-bar app to a regular app and
/// waits until it is active before touching TCC-protected APIs.
@MainActor
enum ServicePermissionCoordinator {
    private struct PresentationContext {
        let restoreAccessoryPolicy: Bool
    }

    enum PresentationError: LocalizedError {
        case couldNotBecomeActive

        var errorDescription: String? {
            switch self {
            case .couldNotBecomeActive:
                return
                    "Apple Core could not become the active app, so macOS could not safely show the permission request. Open Apple Core Settings and try again."
            }
        }
    }

    static func activate(
        _ service: any Service,
        requirements: [ServicePermissionRequirement]
    ) async throws {
        guard !requirements.isEmpty else {
            try await service.activate()
            return
        }

        let context = try await prepareForPermissionPresentation()
        defer { restorePresentation(context) }
        try await service.activate()
    }

    private static func prepareForPermissionPresentation() async throws -> PresentationContext {
        let restoreAccessoryPolicy = NSApp.activationPolicy() == .accessory

        if restoreAccessoryPolicy, !NSApp.setActivationPolicy(.regular) {
            throw PresentationError.couldNotBecomeActive
        }

        NSApp.activate()

        // App activation is asynchronous and not guaranteed. Waiting for the
        // observed active state prevents the permission call from racing the
        // activation request, which Tahoe otherwise rejects without a prompt.
        for _ in 0 ..< 40 {
            if NSApp.isActive {
                return PresentationContext(restoreAccessoryPolicy: restoreAccessoryPolicy)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        if restoreAccessoryPolicy {
            NSApp.setActivationPolicy(.accessory)
        }
        throw PresentationError.couldNotBecomeActive
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
