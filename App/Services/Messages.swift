import AppKit
import OSLog
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

/// AppleScript sources for sending via Messages.app. Constant source; all
/// user-supplied values arrive through argv (see AppleScriptRunner), so
/// untrusted text is never interpolated into script source.
///
/// The `service`/`buddy` terminology is the compatibility vocabulary that
/// Messages.app still honors on modern macOS (same approach as
/// carterlasalle/mac_messages_mcp, reimplemented independently).
private let sendToBuddyScript = """
    on run argv
        set recipientAddress to item 1 of argv
        set messageBody to item 2 of argv
        set preferredService to item 3 of argv
        tell application "Messages"
            if preferredService is "SMS" then
                set targetService to 1st service whose service type = SMS
            else
                set targetService to 1st service whose service type = iMessage
            end if
            set targetBuddy to buddy recipientAddress of targetService
            send messageBody to targetBuddy
        end tell
        return "sent"
    end run
    """

private let sendToChatScript = """
    on run argv
        set chatGuid to item 1 of argv
        set messageBody to item 2 of argv
        tell application "Messages"
            set targetChat to a reference to chat id chatGuid
            send messageBody to targetChat
        end tell
        return "sent"
    end run
    """

/// Produces candidate handle formats for a phone number, per the pattern
/// documented in docs/planning/DONORS.md (Dhravya) and BUILD_PLAN.md §3.6:
/// Messages may store the same buddy as "+14155551234", "14155551234",
/// or "4155551234". Emails pass through lowercased.
func messagesRecipientCandidates(for recipient: String) -> [String] {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") {
        return [trimmed.lowercased()]
    }

    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return [trimmed] }

    var candidates: [String] = []
    func add(_ candidate: String) {
        if !candidates.contains(candidate) {
            candidates.append(candidate)
        }
    }

    if trimmed.hasPrefix("+") {
        add("+\(digits)")
        add(digits)
    } else if digits.count == 10 {
        // Bare US/CA number: try E.164 first, then prefixed and bare forms.
        add("+1\(digits)")
        add("1\(digits)")
        add(digits)
    } else if digits.count == 11 && digits.hasPrefix("1") {
        add("+\(digits)")
        add(digits)
        add(String(digits.dropFirst()))
    } else {
        add("+\(digits)")
        add(digits)
    }
    return candidates
}

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    func activate() async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description: "Fetch messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate()

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let limit = arguments["limit"]?.intValue

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit ?? -1)"
            )
            for message in try db.fetchMessages(
                with: Set(handles),
                in: dateRange,
                limit: max(limit ?? defaultLimit, 1024)
            ) {
                guard messages.count < (limit ?? defaultLimit) else { break }
                guard !message.text.isEmpty else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                messages.append([
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                ])
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_list_chats",
            description:
                "List recent conversations from the Messages app, including each chat's GUID (usable as chat_id in messages_send), display name, and participants. Group chats have more than one participant.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum chats to return",
                        default: .int(defaultLimit)
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Chats",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            let limit = min(max(arguments["limit"]?.intValue ?? defaultLimit, 1), 200)
            let db = try self.createDatabaseConnection()

            let chats: [[String: Value]] = try db.fetchChats(limit: limit).map { chat in
                var entry: [String: Value] = [
                    "@id": .string(chat.id.rawValue),
                    "participants": .array(
                        chat.participants.map { .string($0.rawValue) }
                    ),
                    "isGroup": .bool(chat.participants.count > 1),
                ]
                if let displayName = chat.displayName, !displayName.isEmpty {
                    entry["name"] = .string(displayName)
                }
                if let lastMessageDate = chat.lastMessageDate {
                    entry["lastMessageAt"] = .string(
                        lastMessageDate.formatted(.iso8601)
                    )
                }
                return entry
            }

            log.debug("Listed \(chats.count) chats")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "itemListElement": Value.array(chats.map { .object($0) }),
            ]
        }

        Tool(
            name: "messages_send",
            description:
                "Send a message via the Messages app. Provide either `recipient` (a phone number or email address) for a direct message, or `chat_id` (a chat GUID from messages_list_chats) to send to an existing conversation, including group chats.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "Phone number or email address of the recipient. Phone numbers are normalized and matched against known conversation participants where possible."
                    ),
                    "chat_id": .string(
                        description:
                            "GUID of an existing chat (from messages_list_chats). Required for group chats; takes precedence over recipient."
                    ),
                    "body": .string(
                        description: "The message text to send"
                    ),
                    "service": .string(
                        description:
                            "Messaging service to use for direct sends. Defaults to iMessage. Ignored when chat_id is provided (the chat's existing service is used).",
                        enum: ["iMessage", "SMS"]
                    ),
                ],
                required: ["body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Message",
                readOnlyHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            guard let body = arguments["body"]?.stringValue,
                !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw SendError.emptyBody
            }

            let chatId = arguments["chat_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recipient = arguments["recipient"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let chatId, !chatId.isEmpty {
                log.debug("Sending message to chat \(chatId)")
                _ = try await AppleScriptRunner.shared.run(
                    .appleScript,
                    script: sendToChatScript,
                    arguments: [chatId, body]
                )
                return [
                    "sent": Value.bool(true),
                    "chatId": .string(chatId),
                ]
            }

            guard let recipient, !recipient.isEmpty else {
                throw SendError.missingRecipient
            }

            let service = arguments["service"]?.stringValue ?? "iMessage"
            let address = self.resolveRecipientAddress(for: recipient)

            log.debug("Sending \(service) message to \(address)")
            _ = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: sendToBuddyScript,
                arguments: [address, body, service]
            )
            return [
                "sent": Value.bool(true),
                "recipient": .string(address),
                "service": .string(service),
            ]
        }
    }

    private enum SendError: LocalizedError {
        case emptyBody
        case missingRecipient

        var errorDescription: String? {
            switch self {
            case .emptyBody:
                return "Message body must not be empty"
            case .missingRecipient:
                return "Provide either `recipient` (phone/email) or `chat_id` (chat GUID)"
            }
        }
    }

    /// Resolves the address to hand to Messages.app: generates normalized
    /// candidate formats for the recipient and prefers one that matches an
    /// existing handle in chat.db (so we address the buddy exactly as
    /// Messages knows them). Falls back to the best-guess candidate when
    /// the database is unavailable or nothing matches — Messages.app can
    /// still start a fresh conversation with a well-formed address.
    private func resolveRecipientAddress(for recipient: String) -> String {
        let candidates = messagesRecipientCandidates(for: recipient)

        if let db = try? createDatabaseConnection(),
            let match = try? db.fetchParticipant(matching: candidates).first
        {
            log.debug("Matched recipient to existing handle \(match.rawValue)")
            return match.rawValue
        }

        return candidates.first ?? recipient
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func createDatabaseConnection() throws -> iMessage.Database {
        if canAccessDatabaseAtDefaultPath {
            return try iMessage.Database()
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try iMessage.Database(path: url.path)
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        alert.informativeText = """
            To read your Messages history, we need to open your database file.

            In the next screen, please select the file `chat.db` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select the Messages database file (chat.db)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "chat.db"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "chat.db"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}
