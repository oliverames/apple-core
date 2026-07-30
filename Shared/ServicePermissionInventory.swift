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
