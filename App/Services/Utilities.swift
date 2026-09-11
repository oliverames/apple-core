import AppKit
import Foundation
import JSONSchema
import OSLog
import UserNotifications

private let log = Logger.service("utilities")

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "utilities_beep",
            description: "Play a system sound",
            inputSchema: .object(
                properties: [
                    "sound": .string(
                        default: .string(Sound.default.rawValue),
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    )
                ],
                required: ["sound"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { input in
            let rawValue = input["sound"]?.stringValue ?? Sound.default.rawValue
            guard let sound = Sound(rawValue: rawValue) else {
                log.error("Invalid sound: \(rawValue)")
                throw NSError(
                    domain: "SoundError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid sound"
                    ]
                )
            }

            return NSSound.play(sound)
        }

        Tool(
            name: "utilities_notify",
            description:
                "Post a macOS notification. Use this to get the user's attention when they are not looking at the conversation.",
            inputSchema: .object(
                properties: [
                    "title": .string(description: "Notification title"),
                    "body": .string(description: "Notification body text"),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Post Notification",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw UtilitiesError.missingArgument("title")
            }
            let body = arguments["body"]?.stringValue ?? ""

            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            // Notification authorization is requested lazily here rather than
            // when the service is enabled: most sessions never post one, and a
            // prompt on enable would be a prompt for nothing.
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                throw UtilitiesError.notificationsNotAuthorized
            }
            try await center.add(request)
            return Value.object(["posted": .bool(true), "title": .string(title)])
        }

        Tool(
            name: "utilities_clipboard_read",
            description: "Read the text currently on the clipboard",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Read Clipboard",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            guard let text = NSPasteboard.general.string(forType: .string) else {
                return Value.object(["hasText": .bool(false)])
            }
            return Value.object(["hasText": .bool(true), "text": .string(text)])
        }

        Tool(
            name: "utilities_clipboard_write",
            description: "Replace the clipboard contents with text",
            inputSchema: .object(
                properties: [
                    "text": .string(description: "Text to put on the clipboard")
                ],
                required: ["text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write Clipboard",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let text = arguments["text"]?.stringValue else {
                throw UtilitiesError.missingArgument("text")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return Value.object(["written": .bool(true), "characters": .int(text.count)])
        }

        Tool(
            name: "utilities_open_url",
            description:
                "Open a URL in the user's default application. Use this to show the user a web page or open a document.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The URL to open")
                ],
                required: ["url"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Open URL",
                readOnlyHint: false,
                openWorldHint: true
            )
        ) { arguments in
            guard let raw = arguments["url"]?.stringValue, let url = URL(string: raw) else {
                throw UtilitiesError.missingArgument("url")
            }
            // Only schemes that open something the user can see. Without this,
            // a tool call could reach any registered URL handler on the Mac,
            // which is a much larger surface than "show me a page".
            let allowedSchemes = ["http", "https", "mailto", "facetime", "sms", "tel"]
            guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
                throw UtilitiesError.unsupportedScheme(url.scheme ?? "none")
            }
            let opened = NSWorkspace.shared.open(url)
            return Value.object(["opened": .bool(opened), "url": .string(url.absoluteString)])
        }

        Tool(
            name: "utilities_system_info",
            description: "Get basic information about this Mac: name, macOS version, and uptime",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "System Information",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let info = ProcessInfo.processInfo
            return Value.object([
                "computerName": .string(Host.current().localizedName ?? "Mac"),
                "systemVersion": .string(info.operatingSystemVersionString),
                "uptimeSeconds": .int(Int(info.systemUptime)),
                "processorCount": .int(info.processorCount),
            ])
        }

        Tool(
            name: "utilities_connector_health",
            description:
                "Report which Apple Core surfaces are live on this Mac, what each one is waiting on, "
                + "which folders are shared, and the version information a support conversation needs. "
                + "Read-only, and raises no permission prompts. Call this first when a tool is missing or failing.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Connector Health",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            await connectorHealthReport()
        }
    }
}

/// Gathers the live values `ConnectorHealth` shapes into a report. Every probe
/// here reads recorded state: nothing calls a surface, so nothing prompts.
private func connectorHealthReport() async -> ConnectorHealthReport {
    let built = Dictionary(
        uniqueKeysWithValues: ServiceRegistry.services.map {
            (String(describing: type(of: $0)), $0.tools.count)
        }
    )
    let defaults = UserDefaults.standard
    let info = Bundle.main.infoDictionary ?? [:]

    var surfaces: [ConnectorSurfaceInput] = []
    // The inventory, not the registry, decides which surfaces exist: a service
    // compiled out of this build has to appear as unsupported rather than
    // vanish, or a client cannot tell "not on this Mac" from "never existed".
    for serviceTypeName in ServicePermissionInventory.standard.keys.sorted() {
        let requirements = ServicePermissionInventory.standard[serviceTypeName] ?? []
        let isBuilt = built[serviceTypeName] != nil
        let isEnabled =
            defaults.object(
                forKey: ConnectorHealth.enablementDefaultsKey(forServiceTypeName: serviceTypeName)
            ) as? Bool ?? ConnectorHealth.defaultEnabled(forServiceTypeName: serviceTypeName)

        // A surface nobody switched on is reported as switched off, full stop.
        // Reading its permissions anyway would list refusals for things the
        // user has not agreed to use yet, and spend a TCC round trip each.
        var permissions: [ConnectorPermissionInput] = []
        if isBuilt && isEnabled {
            for requirement in requirements {
                let state = await ServicePermissionStatus.state(of: requirement)
                permissions.append(
                    ConnectorPermissionInput(
                        requirement: requirement.settingsTitle,
                        state: state.connectorState,
                        detail: state.label
                    )
                )
            }
        }

        surfaces.append(
            ConnectorSurfaceInput(
                serviceTypeName: serviceTypeName,
                isBuilt: isBuilt,
                isEnabled: isEnabled,
                toolCount: built[serviceTypeName] ?? 0,
                permissions: permissions
            )
        )
    }

    let sharedFolders = (ServingConfigManager.load().filesystemRoots ?? []).map {
        ConnectorHealthReport.SharedFolder(path: $0.path, writable: $0.writable)
    }

    return ConnectorHealth.report(
        application: ConnectorHealthReport.Application(
            name: info["CFBundleName"] as? String ?? "Apple Core",
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        ),
        // The menu bar switch, read from the same default `App.swift` binds.
        isConnectorEnabled: defaults.object(forKey: "isEnabled") as? Bool ?? true,
        surfaces: surfaces,
        sharedFolders: sharedFolders
    )
}

extension ServicePermissionState {
    /// The recorded answer, reduced to what a client can act on. `limited`
    /// keeps its wording in the detail, which is where the narrowing is
    /// described.
    var connectorState: ConnectorPermissionState {
        switch self {
        case .granted: .granted
        case .limited: .limited
        case .denied: .denied
        case .notDetermined: .notRequested
        case .promptBlocked: .promptBlocked
        case .unknown: .unreadable
        }
    }
}

enum UtilitiesError: LocalizedError {
    case missingArgument(String)
    case unsupportedScheme(String)
    case notificationsNotAuthorized

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .unsupportedScheme(scheme):
            return "Apple Core will not open \(scheme): URLs."
        case .notificationsNotAuthorized:
            return "Notifications are not allowed for Apple Core in System Settings."
        }
    }
}
