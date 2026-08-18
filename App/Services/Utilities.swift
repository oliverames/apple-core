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
