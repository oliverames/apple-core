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

    /// Refused outright. macOS will not prompt again for these, so the only
    /// way back is System Settings; asking again would do nothing.
    var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }
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
        case .mailAutomation, .messagesAutomation, .notesAutomation:
            guard let target = requirement.automationTarget else { return .unknown("No target") }
            return await automationState(
                bundleIdentifier: target.bundleIdentifier,
                appName: target.appName
            )
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
            // procNotFound means the API could not ask, not that consent was
            // refused. Reporting "Mail not running" read as a fault and hid
            // the common case: the grant already exists and cannot be seen
            // from here while the app is closed.
            case OSStatus(procNotFound):
                return .unknown("Can't check while \(appName) is closed")
            default: return .unknown("Status \(status)")
            }
        }.value
    }

    /// Asks macOS for Apple Events consent, showing the system prompt.
    ///
    /// Deliberately separate from `state(of:)`, which stays read-only so that
    /// opening Diagnostics never prompts. Sending the target a launch first is
    /// what makes this work at all: `AEDeterminePermissionToAutomateTarget`
    /// answers `procNotFound` for an app that is not running, and until the
    /// prompt has been answered once the app never appears under Automation in
    /// System Settings, so there is nothing there to switch on. That is why
    /// "Open Settings" was a dead end for a service that had never been asked
    /// for.
    static func requestAutomationAccess(
        for requirement: ServicePermissionRequirement
    ) async -> ServicePermissionState {
        guard let target = requirement.automationTarget else {
            return await state(of: requirement)
        }
        if NSRunningApplication.runningApplications(
            withBundleIdentifier: target.bundleIdentifier
        ).isEmpty {
            await launchQuietly(bundleIdentifier: target.bundleIdentifier)
        }
        return await Task.detached(priority: .userInitiated) {
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.bundleIdentifier)
            guard let aeDesc = descriptor.aeDesc else {
                return ServicePermissionState.unknown("Could not address \(target.appName)")
            }
            let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, true)
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied("Denied")
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            case OSStatus(procNotFound):
                return .unknown("Open \(target.appName), then try again")
            default: return .unknown("Status \(status)")
            }
        }.value
    }

    /// Opens the target without bringing it forward. Consent is about this
    /// app driving that one; stealing focus is not part of the bargain.
    private static func launchQuietly(bundleIdentifier: String) async {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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
