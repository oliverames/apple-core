// SPDX-License-Identifier: GPL-3.0-or-later

enum ServicePermissionRequirement: String, CaseIterable, Hashable, Sendable {
    case calendar
    case camera
    case microphone
    case screenRecording
    case contacts
    case location
    case mailAutomation
    case messagesAutomation
    case messagesDatabase
    case notesAutomation
    case reminders

    /// What macOS will ask for, in the words its own prompt uses. Onboarding
    /// shows these before enabling anything, so a run of system prompts is
    /// expected rather than a surprise.
    var displayName: String {
        switch self {
        case .calendar: "Calendar access"
        case .camera: "Camera access"
        case .microphone: "Microphone access"
        case .screenRecording: "Screen Recording access"
        case .contacts: "Contacts access"
        case .location: "Location Services"
        case .mailAutomation: "permission to control Mail"
        case .messagesAutomation: "permission to control Messages"
        case .messagesDatabase: "access to the Messages database"
        case .notesAutomation: "permission to control Notes"
        case .reminders: "Reminders access"
        }
    }
}

extension Array where Element == ServicePermissionRequirement {
    /// "Calendar access", or "Camera access, Microphone access and Screen
    /// Recording access" — phrased for a sentence rather than a list.
    var sentenceDescription: String {
        let names = map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

/// Complete permission inventory for every standard service in the app. An
/// explicit empty entry means the service needs no privacy grant. Keeping the
/// inventory in Shared lets unit tests enforce coverage without launching the
/// app or touching live TCC state.
enum ServicePermissionInventory {
    static let standard: [String: [ServicePermissionRequirement]] = [
        "CalendarService": [.calendar],
        "CaptureService": [.camera, .microphone, .screenRecording],
        "ContactsService": [.contacts],
        "LocationService": [.location],
        "MailService": [.mailAutomation],
        "MapsService": [.location],
        "MessageService": [.messagesAutomation, .messagesDatabase],
        "NotesService": [.notesAutomation],
        "RemindersService": [.reminders],
        "ShortcutsService": [],
        "UtilitiesService": [],
        "WeatherService": [],
    ]

    static func requirements(forServiceTypeName name: String) -> [ServicePermissionRequirement]? {
        standard[name]
    }
}
