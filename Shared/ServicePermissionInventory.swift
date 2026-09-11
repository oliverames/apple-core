// SPDX-License-Identifier: GPL-3.0-or-later

enum ServicePermissionRequirement: String, CaseIterable, Hashable, Sendable {
    case calendar
    case camera
    case microphone
    case screenRecording
    case contacts
    case fullDiskAccess
    case location
    case mailAutomation
    case messagesAutomation
    case messagesDatabase
    case notesAutomation
    case reminders

    /// The app this requirement is consent to drive, when it is one.
    ///
    /// Kept here so the bundle identifiers are stated once. Checking consent
    /// and asking for it both need them, and they had been written out
    /// separately at each call site.
    var automationTarget: (bundleIdentifier: String, appName: String)? {
        switch self {
        case .mailAutomation: ("com.apple.mail", "Mail")
        case .messagesAutomation: ("com.apple.MobileSMS", "Messages")
        case .notesAutomation: ("com.apple.Notes", "Notes")
        default: nil
        }
    }

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
        case .fullDiskAccess: "Full Disk Access"
        case .location: "Location Services"
        case .mailAutomation: "permission to control Mail"
        case .messagesAutomation: "permission to control Messages"
        case .messagesDatabase: "access to the Messages database"
        case .notesAutomation: "permission to control Notes"
        case .reminders: "Reminders access"
        }
    }

    /// The file whose readability answers "is Full Disk Access granted".
    ///
    /// The system consent store is the one protected location every Mac has
    /// regardless of which apps anybody opened: macOS creates it at install
    /// and it belongs to no app whose data this probe would otherwise be
    /// reporting on. A probe keyed to Messages, Mail or Notes answers "is
    /// that app's data there" as much as "is this grant held", and calls a
    /// Mac that simply never used the app a refusal.
    ///
    /// The per-user store under `~/Library/Application Support/com.apple.TCC`
    /// was the first choice and is wrong: it does not exist on every macOS
    /// version, so a granted Mac would read as refused.
    static let fullDiskAccessProbePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// One sentence telling somebody how to grant this, for a tool that has
    /// just failed for want of it. Stated once here so the surfaces that
    /// depend on the same grant stop wording it three different ways.
    var grantInstruction: String {
        switch self {
        case .fullDiskAccess, .messagesDatabase:
            return
                "Grant Apple Core Full Disk Access in System Settings > Privacy & Security, "
                + "then quit and reopen it."
        default:
            return
                "Grant Apple Core \(displayName) in System Settings > Privacy & Security, "
                + "then try again."
        }
    }
}

/// Whether a surface needs a grant to function, or can use it for one named
/// capability while the rest of the surface works without it.
///
/// Without this distinction, declaring a requirement and demanding it before
/// the surface is usable are the same act. That is right for Calendar access
/// on Calendar and wrong for Full Disk Access on Mail, where it unlocks the
/// local index and nothing else changes.
enum ServicePermissionNecessity: String, Hashable, Sendable {
    case required
    case optional
}

/// One grant a service declares, with what it means for that service.
struct ServicePermissionNeed: Hashable, Sendable {
    let requirement: ServicePermissionRequirement
    let necessity: ServicePermissionNecessity
    /// What an optional grant unlocks, named so the UI can offer it as a
    /// capability rather than a condition. Nil when the grant is required,
    /// where the capability is the whole surface.
    let capability: String?

    var isRequired: Bool { necessity == .required }

    static func required(_ requirement: ServicePermissionRequirement) -> Self {
        Self(requirement: requirement, necessity: .required, capability: nil)
    }

    static func optional(
        _ requirement: ServicePermissionRequirement,
        enables capability: String
    ) -> Self {
        Self(requirement: requirement, necessity: .optional, capability: capability)
    }
}

extension Array where Element == ServicePermissionNeed {
    /// The grants the surface cannot work without. This is what activation
    /// and onboarding ask for, which is what keeps an optional grant from
    /// becoming a condition of switching the surface on.
    var requiredRequirements: [ServicePermissionRequirement] {
        filter(\.isRequired).map(\.requirement)
    }

    var optionalNeeds: [ServicePermissionNeed] {
        filter { !$0.isRequired }
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
    static let standard: [String: [ServicePermissionNeed]] = [
        "CalendarService": [.required(.calendar)],
        "CaptureService": [.required(.camera), .required(.microphone), .required(.screenRecording)],
        "ContactsService": [.required(.contacts)],
        // No TCC grant of its own. macOS still prompts for Documents, Desktop
        // and Downloads the first time one is actually touched, but that is
        // per-folder and driven by the user's own choice of shared folders
        // rather than by enabling the surface.
        "FilesystemService": [],
        "LocationService": [.required(.location)],
        // The local index reads Mail's own files on disk. Every other Mail
        // tool goes through Mail itself and works without the grant, so
        // demanding it of every Mail user would be asking for a blanket
        // grant on behalf of one optional feature.
        "MailService": [
            .required(.mailAutomation),
            .optional(.fullDiskAccess, enables: "the local mail index"),
        ],
        "MapsService": [.required(.location)],
        // `messagesDatabase` stays its own requirement rather than folding
        // into `fullDiskAccess`: Messages also accepts a security-scoped
        // bookmark for the one file, picked by hand, which is a real
        // alternative to a blanket grant and is not expressible as a state
        // of the generic one.
        "MessageService": [.required(.messagesAutomation), .required(.messagesDatabase)],
        "NotesService": [
            .required(.notesAutomation),
            .optional(
                .fullDiskAccess,
                enables: "note links, metadata, checklist state and sync status"
            ),
        ],
        "RemindersService": [.required(.reminders)],
        "ShortcutsService": [],
        "UtilitiesService": [],
        "WeatherService": [],
    ]

    static func needs(forServiceTypeName name: String) -> [ServicePermissionNeed]? {
        standard[name]
    }
}
