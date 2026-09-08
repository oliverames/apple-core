// SPDX-License-Identifier: GPL-3.0-or-later
extension ServiceConfig {
    var displayName: String { name == "Filesystem" ? "Files" : name }

    var purposeDescription: String {
        switch name {
        case "Calendar": "Calendars and events"
        case "Capture": "Screens, camera, and audio"
        case "Contacts": "People and contact groups"
        case "Filesystem": "Files in the folders you share"
        case "Location": "This Mac’s current location"
        case "Mail": "Mail accounts and messages"
        case "Maps": "Places, directions, and distances"
        case "Messages": "Conversations and messages"
        case "Notes": "Notes, folders, and attachments"
        case "Reminders": "Lists and reminders"
        case "Shortcuts": "Browse and run your shortcuts"
        case "Weather": "Weather conditions and forecasts"
        default: "System information and utilities"
        }
    }
}
