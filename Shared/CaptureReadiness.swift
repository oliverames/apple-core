// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a client needs to know before it aims a capture, and the rules that
// turn live system state into that answer.
//
// Both halves live here rather than beside the Tool closures because the
// interesting states are the ones a unit test cannot reach on a build machine:
// a second display, a window that closed between two calls, a camera nobody
// has been asked about, and a Mac sitting at its lock screen. Modelling them
// as plain values makes those states fixtures instead of manual checks.

import AVFoundation
import Foundation

// MARK: - Legacy window listing

/// `capture_list_windows` is superseded by `capture_list_targets` and is kept
/// only until beta clients have moved off it. Its description and the one
/// field its window entries still say something about live here so the
/// deprecation notice is a string a test can hold to, rather than prose buried
/// in a tool closure.
enum CaptureLegacyWindowListing {
    /// The tool's description. It names the replacement first, because a
    /// client reading a tool list decides from this sentence alone.
    static let toolDescription =
        "Deprecated: use capture_list_targets instead, which answers the same question without "
        + "window titles and without asking for Screen Recording access. Lists the displays, "
        + "applications and windows that can be captured, with the identifiers "
        + "capture_take_screenshot needs. No longer returns window titles."

    /// Whether a window has a title, which is what the entry now reports in
    /// place of the title itself. A title routinely carries a document name or
    /// a message subject, content the caller was never granted; whether the
    /// window has one is all that aiming a capture needs.
    static func hasTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return !title.isEmpty
    }
}

// MARK: - Capture target discovery

/// The metadata needed to aim a capture, and nothing else.
struct CaptureTargetSnapshot: Sendable, Equatable {
    struct Display: Sendable, Equatable {
        let id: UInt32
        let width: Int
        let height: Int
    }

    struct Application: Sendable, Equatable {
        let bundleIdentifier: String
        let name: String
        let processIdentifier: Int
    }

    /// Deliberately no title. A window title routinely carries the name of the
    /// document open in it, which is content the caller has not been granted
    /// and has not asked for. `hasTitle` still separates a document window from
    /// an untitled panel, which is as much as aiming a capture needs.
    struct Window: Sendable, Equatable {
        let id: UInt32
        let ownerBundleIdentifier: String?
        let ownerName: String?
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let isOnScreen: Bool
        let isActive: Bool
        let hasTitle: Bool
    }

    var displays: [Display] = []
    var applications: [Application] = []
    var windows: [Window] = []
}

enum CaptureTargetInventory {
    /// A window identifier from an earlier listing may have closed in the
    /// meantime. Saying so beats failing, because the client's next move is the
    /// same either way: list again and pick a live window.
    enum WindowLookup: Sendable, Equatable {
        case notRequested
        case live(UInt32)
        case stale(UInt32)
    }

    static func lookup(windowID: UInt32?, in snapshot: CaptureTargetSnapshot) -> WindowLookup {
        guard let windowID else { return .notRequested }
        return snapshot.windows.contains { $0.id == windowID } ? .live(windowID) : .stale(windowID)
    }

    /// Narrow a snapshot to what the caller asked for. Off-screen windows are
    /// dropped by default: a minimized window still has an identifier, but
    /// capturing it produces whatever it looked like when it went away.
    static func filtered(
        _ snapshot: CaptureTargetSnapshot,
        bundleIdentifier: String? = nil,
        includeOffscreenWindows: Bool = false
    ) -> CaptureTargetSnapshot {
        var result = snapshot
        if let wanted = bundleIdentifier, !wanted.isEmpty {
            result.applications = snapshot.applications.filter { $0.bundleIdentifier == wanted }
            result.windows = snapshot.windows.filter { $0.ownerBundleIdentifier == wanted }
        }
        if !includeOffscreenWindows {
            result.windows = result.windows.filter(\.isOnScreen)
        }
        return result
    }

    static func staleWindowAdvice(for windowID: UInt32) -> String {
        "Window \(windowID) is gone. Window identifiers are not reused predictably, so take a current "
            + "one from this listing rather than retrying the old one."
    }
}

// MARK: - Per-modality readiness

/// Permission state for one capture modality, mirrored off
/// `AVAuthorizationStatus` so the readiness rules stay testable without a TCC
/// database behind them.
enum CapturePermissionState: String, Sendable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }
}

enum CaptureModality: String, Sendable, CaseIterable {
    case camera
    case microphone
    case screen
}

enum CaptureModalityStatus: String, Sendable, CaseIterable {
    case ready
    case denied
    case restricted
    case notDetermined
    case noHardware
    case lockedSession
}

enum CaptureReadiness {
    /// Camera and microphone. Permission is decided first because an
    /// unauthorized process can see an empty device list for reasons that say
    /// nothing about the hardware. "No hardware" is therefore only claimed once
    /// the modality is authorized and the list is still empty.
    static func deviceStatus(
        permission: CapturePermissionState,
        hasDevice: Bool
    ) -> CaptureModalityStatus {
        switch permission {
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .authorized: return hasDevice ? .ready : .noHardware
        }
    }

    /// Screen. The session test comes before the display count on purpose:
    /// ScreenCaptureKit reports zero displays on a locked Mac, and passing that
    /// on as "no displays" is what made an ordinary locked screen read as a bug
    /// in the app.
    static func screenStatus(
        isAuthorized: Bool,
        isGUISessionActive: Bool,
        displayCount: Int
    ) -> CaptureModalityStatus {
        guard isAuthorized else { return .denied }
        guard isGUISessionActive else { return .lockedSession }
        return displayCount > 0 ? .ready : .noHardware
    }

    static func detail(for status: CaptureModalityStatus, modality: CaptureModality) -> String {
        switch (status, modality) {
        case (.ready, .camera):
            return "A camera is attached and Camera access is granted."
        case (.ready, .microphone):
            return "A microphone is attached and Microphone access is granted."
        case (.ready, .screen):
            return "Screen Recording access is granted and at least one display is attached."
        case (.denied, .camera):
            return "Camera access is denied for Apple Core in System Settings."
        case (.denied, .microphone):
            return "Microphone access is denied for Apple Core in System Settings."
        case (.denied, .screen):
            // Preflighting cannot tell "refused" from "never asked": both come
            // back false, and the only thing that separates them is the prompt
            // this check exists to avoid.
            return "Screen Recording access is not granted for Apple Core, or has never been asked for."
        case (.restricted, _):
            return "\(modality.rawValue) access is restricted by a device policy, so it cannot be granted here."
        case (.notDetermined, _):
            return "\(modality.rawValue) access has not been asked for yet. Until it is, neither the "
                + "permission nor the hardware can be reported without prompting."
        case (.noHardware, .camera):
            return "Camera access is granted, but no camera is attached to this Mac."
        case (.noHardware, .microphone):
            return "Microphone access is granted, but no microphone is attached to this Mac."
        case (.noHardware, .screen):
            return "Screen Recording access is granted and somebody is signed in, but no display is attached."
        case (.lockedSession, _):
            return "This Mac's screen is locked, or nobody is signed in at the console, so it reports no "
                + "capturable displays. That is the state of the machine rather than a failed capture."
        }
    }
}

// MARK: - Accessibility readiness

/// Whether the interface can be read as text, and what to do when it cannot.
///
/// Accessibility is a different grant from Screen Recording, lives in a
/// different pane of System Settings, and is the one people have not heard of.
/// Reporting it beside the camera and the screen is what stops
/// `capture_read_text` reading as broken when it is merely switched off.
enum CaptureAccessibilityReadiness {
    static func status(isTrusted: Bool) -> String {
        isTrusted ? "ready" : "permissionRequired"
    }

    static func detail(isTrusted: Bool) -> String {
        isTrusted
            ? "Apple Core can read application interfaces as text with capture_read_text."
            : "Accessibility permission has not been granted, so capture_read_text cannot read an interface. "
                + "System Settings › Privacy & Security › Accessibility. Screenshots and OCR do not need it."
    }
}
