// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading permission state without asking for it.
//
// Every service already requests what it needs when you switch it on, and
// reports the refusal in that row. What was missing is the standing answer to
// "does this Mac currently grant Notes access?", which you want when a tool
// call fails days later and the toggle still looks fine. Diagnostics is where
// that belongs, so this file probes each requirement read-only: every API used
// here reports the recorded TCC answer and never triggers a consent prompt.

import AVFoundation
import AppKit
import Contacts
import CoreGraphics
import CoreLocation
import EventKit
import Foundation

/// What macOS currently records for one permission.
enum ServicePermissionState: Equatable, Sendable {
    case granted
    /// Granted, but narrower than the service needs (write-only calendars,
    /// a limited contact selection).
    case limited(String)
    case denied(String)
    /// Never asked for, so no prompt has been shown and nothing is refused.
    case notDetermined
    /// The state cannot be read right now, with the reason.
    case unknown(String)

    var label: String {
        switch self {
        case .granted: "Granted"
        case .limited(let detail): detail
        case .denied(let detail): detail
        case .notDetermined: "Not requested"
        case .unknown(let detail): detail
        }
    }

    var tone: StatusBadge.Tone {
        switch self {
        case .granted: .positive
        case .limited, .denied: .warning
        case .notDetermined, .unknown: .neutral
        }
    }

    var isGranted: Bool { self == .granted }
}

/// Read-only probes for the permission inventory. Nothing here prompts.
enum ServicePermissionStatus {
    static func state(of requirement: ServicePermissionRequirement) async -> ServicePermissionState {
        switch requirement {
        case .calendar:
            return eventKitState(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return eventKitState(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            return contactsState(CNContactStore.authorizationStatus(for: .contacts))
        case .camera:
            return captureDeviceState(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return captureDeviceState(AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenRecording:
            // Preflight cannot separate "refused" from "never asked": both
            // read as false. Say only what is true, that it is not granted.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied("Not granted")
        case .location:
            return await locationState()
        case .mailAutomation:
            return await automationState(bundleIdentifier: "com.apple.mail", appName: "Mail")
        case .messagesAutomation:
            return await automationState(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages")
        case .notesAutomation:
            return await automationState(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        case .messagesDatabase:
            return messagesDatabaseState()
        }
    }

    /// Every requirement any built service declares, in inventory order, each
    /// paired with the services that need it. One Location row rather than a
    /// Location row for Location and another for Maps.
    static func requirementsInUse(
        by configs: [ServiceConfig]
    ) -> [(requirement: ServicePermissionRequirement, services: [String])] {
        ServicePermissionRequirement.allCases.compactMap { requirement in
            let services =
                configs
                .filter { $0.permissionRequirements.contains(requirement) }
                .map(\.name)
            return services.isEmpty ? nil : (requirement, services)
        }
    }

    // MARK: - Probes

    private static func eventKitState(_ status: EKAuthorizationStatus) -> ServicePermissionState {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .limited("Write only")
        case .notDetermined: .notDetermined
        case .restricted: .denied("Restricted")
        case .denied: .denied("Denied")
        @unknown default: .unknown("Unrecognized status")
        }
    }

    private static func contactsState(_ status: CNAuthorizationStatus) -> ServicePermissionState {
        switch status {
        case .authorized: .granted
        case .limited: .limited("Limited selection")
        case .notDetermined: .notDetermined
        case .restricted: .denied("Restricted")
        case .denied: .denied("Denied")
        @unknown default: .unknown("Unrecognized status")
        }
    }

    private static func captureDeviceState(
        _ status: AVAuthorizationStatus
    ) -> ServicePermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .denied("Restricted")
        case .denied: .denied("Denied")
        @unknown default: .unknown("Unrecognized status")
        }
    }

    @MainActor
    private static func locationState() -> ServicePermissionState {
        // Reading `authorizationStatus` from a fresh manager reports the
        // recorded answer without starting location updates, so no prompt.
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: .granted
        case .notDetermined: .notDetermined
        case .restricted: .denied("Restricted")
        case .denied: .denied("Denied")
        default: .unknown("Unrecognized status")
        }
    }

    /// Apple Events consent for one app, asked of the system rather than by
    /// sending a probe event. `askUserIfNeeded: false` is what keeps this
    /// read-only.
    private static func automationState(
        bundleIdentifier: String,
        appName: String
    ) async -> ServicePermissionState {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
            guard let descriptor = target.aeDesc else {
                return ServicePermissionState.unknown("Could not address \(appName)")
            }
            let status = AEDeterminePermissionToAutomateTarget(
                descriptor,
                typeWildCard,
                typeWildCard,
                false
            )
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied("Denied")
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            case OSStatus(procNotFound): return .unknown("\(appName) not running")
            default: return .unknown("Status \(status)")
            }
        }.value
    }

    /// Full Disk Access, phrased as the thing it gates. MessageService also
    /// accepts a security-scoped bookmark picked by hand, which is why an
    /// unreadable default path is not simply a denial.
    private static func messagesDatabaseState() -> ServicePermissionState {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
            .path
        if FileManager.default.isReadableFile(atPath: path) {
            return .granted
        }
        let hasBookmark =
            UserDefaults.standard.data(
                forKey: "me.mattt.iMCP.messagesDatabaseBookmark"
            ) != nil
        return hasBookmark ? .limited("Granted by file") : .denied("Needs Full Disk Access")
    }
}

extension ServicePermissionRequirement {
    /// The System Settings pane that grants this, so a row that reports a
    /// refusal can also open the place where it is undone.
    var privacySettingsURL: URL? {
        let anchor: String
        switch self {
        case .calendar: anchor = "Privacy_Calendars"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .contacts: anchor = "Privacy_Contacts"
        case .location: anchor = "Privacy_LocationServices"
        case .mailAutomation, .messagesAutomation, .notesAutomation: anchor = "Privacy_Automation"
        case .messagesDatabase: anchor = "Privacy_AllFiles"
        case .reminders: anchor = "Privacy_Reminders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Title case for a settings row, where `displayName` is written to sit
    /// inside a sentence.
    var settingsTitle: String {
        switch self {
        case .calendar: "Calendar"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .contacts: "Contacts"
        case .location: "Location Services"
        case .mailAutomation: "Automation: Mail"
        case .messagesAutomation: "Automation: Messages"
        case .messagesDatabase: "Full Disk Access"
        case .notesAutomation: "Automation: Notes"
        case .reminders: "Reminders"
        }
    }
}
