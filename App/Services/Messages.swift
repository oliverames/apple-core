import AppKit
import OSLog

/// The app this service drives. Opened on demand before any script runs.
private let scriptedMessagesApp = ScriptedApp("com.apple.MobileSMS")
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath =
    FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Messages/chat.db")
    .path
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30
/// Base64 grows the payload by about a third, so these caps are about the
/// client's context window rather than the disk. The default matches the
/// Notes surface; the ceiling is higher because a photograph from Messages
/// routinely exceeds 256KB and a path on this Mac is no use to a remote
/// client.
private let maximumInlineMessageAttachmentBytes = 256 * 1024
private let maximumRequestableMessageAttachmentBytes = 1024 * 1024

private let messagesPermissionProbeScript = """
    tell application "Messages" to return name
    """

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

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    func activate() async throws {
        log.debug("Starting message service activation")

        _ = try await scriptedMessagesApp.run(
            .appleScript,
            script: messagesPermissionProbeScript
        )

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
            description:
                "Fetch messages from the Messages app. Pass `chat_id` from messages_list_chats to read one "
                + "exact conversation, including a group chat that shares its participants with another thread. "
                + "Participant, date and text filters still apply, and `offset` pages through older results.",
            inputSchema: .object(
                properties: [
                    "chat_id": .string(
                        description:
                            "Chat GUID from messages_list_chats. Targets that conversation exactly; it stays the same when a group is renamed."
                    ),
                    "offset": .integer(
                        description: "Messages to skip before returning results, for paging. Defaults to 0.",
                        default: .int(0)
                    ),
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
                    "include": .array(
                        description:
                            "Which kinds of row to return. Defaults to [\"message\"], which now covers "
                            + "attachment-only messages as well as text. Add \"tapback\" for reactions, "
                            + "\"tapback_removed\" for reactions taken back, \"group_event\" for joins, "
                            + "leaves and renames, and \"empty\" for rows that carry nothing.",
                        items: .string(enum: MessageKind.allCases.map { .string($0.rawValue) })
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

            let participants = try Self.participantArgument(arguments)

            let chatID = arguments["chat_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let startInput: String?
            if let startValue = arguments["start"] {
                guard case .string(let start) = startValue else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Start must be an ISO 8601 string."]
                    )
                }
                startInput = start
            } else {
                startInput = nil
            }
            let endInput: String?
            if let endValue = arguments["end"] {
                guard case .string(let end) = endValue else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "End must be an ISO 8601 string."]
                    )
                }
                endInput = end
            } else {
                endInput = nil
            }
            var dateRange: Range<Date>?
            switch (startInput, endInput) {
            case (let startInput?, let endInput?):
                guard
                    let start = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startInput
                    ),
                    let end = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: endInput
                    )
                else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Start and end must be valid ISO 8601 dates or date-times."
                        ]
                    )
                }
                // Both bounds: normalize date-only values to local midnight.
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: start.date,
                    isDateOnly: start.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: end.date,
                    isDateOnly: end.isDateOnly
                )
                guard normalizedStart <= normalizedEnd else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
                    )
                }
                dateRange = normalizedStart ..< normalizedEnd
            case (nil, nil):
                break
            default:
                // A one-sided bound used to be dropped silently, returning
                // unfiltered history dressed up as a time-scoped answer.
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Provide both start and end for a date range; a single bound is ambiguous."
                    ]
                )
            }

            let include = try Self.includedKinds(arguments["include"])
            let searchTerm = arguments["query"]?.stringValue
            // Clamp like the sibling tools do. The raw value reached SQL as
            // LIMIT after an Int32 conversion, so a huge client-supplied
            // limit meant runaway memory or a trap on overflow.
            let requestedLimit = arguments["limit"]?.intValue ?? defaultLimit
            let limit = min(max(requestedLimit, 1), 1000)
            let offset = min(max(arguments["offset"]?.intValue ?? 0, 0), 100_000)

            // An unknown GUID used to come back as an empty conversation,
            // indistinguishable from a real thread with nothing in the window.
            var chat: MessagesChatSummary?
            if let chatID, !chatID.isEmpty {
                chat = try self.withDatabaseReader { try $0.chat(guid: chatID) }
                guard chat != nil else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "NOT_FOUND: no conversation with chat_id \"\(chatID)\". "
                                + "Use messages_list_chats to get a current chat id."
                        ]
                    )
                }
            }

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try Set(
                self.withDatabaseReader {
                    try $0.participantHandles(matching: participants)
                }.map {
                    Account.Handle(rawValue: $0)
                }
            )
            if !participants.isEmpty, handles.isEmpty {
                return [
                    "@context": "https://schema.org",
                    "@type": "Conversation",
                    "hasPart": Value.array([]),
                ]
            }

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit)"
            )
            // The pre-filter fetch pools a wider window (1024) so that
            // filtering by text/participants doesn't starve the result set;
            // the SQL LIMIT is still bounded.
            let fetched = try db.fetchMessages(
                for: chat.map { iMessage.Chat.ID(rawValue: $0.chatGUID) },
                with: Set(handles),
                in: dateRange,
                limit: max(limit + offset, 1024)
            )

            // One extra query for the whole page, rather than one per message:
            // madrid models id, text, date, sender and isFromMe and nothing
            // else, so service, read state, tapbacks, replies, edits and
            // attachments all come from chat.db directly.
            //
            // If that read fails the surface still answers. Losing the
            // annotations is a smaller harm than losing the conversation.
            var metadata: [String: MessageMetadata] = [:]
            do {
                let guids = fetched.map(\.id.description)
                metadata = try self.withDatabaseReader { try $0.messageMetadata(forGUIDs: guids) }
            } catch {
                log.notice(
                    "Message metadata unavailable; returning messages without annotations: \(error.localizedDescription)"
                )
            }

            for message in fetched {
                guard messages.count < limit + offset else { break }

                let annotation = metadata[message.id.description]?.annotation
                let kind = annotation?.kind ?? (message.text.isEmpty ? .empty : .message)
                // Without metadata there is nothing to tell an attachment-only
                // message from a stray empty row, so the old behaviour stands:
                // an empty message is skipped rather than reported as content.
                guard include.contains(kind) else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    // A tapback or a group event carries no text of its own, so
                    // a text filter cannot match one. Narrowing to text is what
                    // the caller asked for.
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                var entry: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "isFromMe": .bool(message.isFromMe),
                    "kind": .string(kind.rawValue),
                ]
                if let detail = metadata[message.id.description] {
                    Self.annotate(&entry, with: detail)
                }
                messages.append(entry)
            }

            let page = messagesPage(messages, offset: offset, limit: limit)
            log.debug("Successfully fetched \(page.count) messages")
            var conversation: [String: Value] = [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(page.map({ .object($0) })),
            ]
            if let chat {
                conversation["@id"] = .string(chat.chatGUID)
                conversation["isGroup"] = .bool(chat.isGroup)
                conversation["participants"] = .array(chat.participants.map { .string($0) })
                if let displayName = chat.displayName {
                    conversation["name"] = .string(displayName)
                }
            }
            if offset > 0 { conversation["offset"] = .int(offset) }
            // Only a full page can have more behind it; a short page is the end.
            conversation["hasMore"] = .bool(page.count == limit)
            return conversation
        }

        Tool(
            name: "messages_list_chats",
            description:
                "List recent conversations from the Messages app, including each chat's GUID (its stable id, usable "
                + "as chat_id in messages_fetch and messages_send), display name, and participants. The GUID keeps "
                + "two conversations with the same participants apart, and survives a group being renamed. "
                + "Group chats have more than one participant.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum chats to return",
                        default: .int(defaultLimit)
                    ),
                    "offset": .integer(
                        description: "Conversations to skip before returning results, for paging. Defaults to 0.",
                        default: .int(0)
                    ),
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
            let offset = min(max(arguments["offset"]?.intValue ?? 0, 0), 100_000)

            // Read through the direct reader rather than madrid, which has no
            // offset and so cannot page past its first window.
            let summaries = try self.withDatabaseReader { reader in
                try reader.chats(limit: limit, offset: offset)
            }
            let chats: [[String: Value]] = summaries.map { chat in
                var entry: [String: Value] = [
                    "@id": .string(chat.chatGUID),
                    "participants": .array(chat.participants.map { .string($0) }),
                    "isGroup": .bool(chat.isGroup),
                    "messageCount": .int(chat.messageCount),
                ]
                if let displayName = chat.displayName, !displayName.isEmpty {
                    entry["name"] = .string(displayName)
                }
                if let lastMessageDate = chat.lastMessageDate {
                    entry["lastMessageAt"] = .string(lastMessageDate.formatted(.iso8601))
                }
                return entry
            }

            log.debug("Listed \(chats.count) chats")
            var response: [String: Value] = [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "itemListElement": Value.array(chats.map { .object($0) }),
            ]
            if offset > 0 { response["offset"] = .int(offset) }
            response["hasMore"] = .bool(chats.count == limit)
            return response
        }

        Tool(
            name: "messages_attachments",
            description:
                "Find attachments sent and received in Messages: photos, files and stickers, newest first. "
                + "Returns each attachment's stable id, name, type, size and whether its file is actually on "
                + "this Mac. Narrow by conversation, participant, MIME type and date. This lists attachments; "
                + "use messages_fetch_attachment with an id to get the bytes.",
            inputSchema: .object(
                properties: [
                    "chat_id": .string(
                        description: "Chat GUID from messages_list_chats. Omit to search across every conversation."
                    ),
                    "participants": .array(
                        description:
                            "Participant handles (phone or email) whose conversations to search. Phone numbers should use E.164 format.",
                        items: .string()
                    ),
                    "mime_type": .string(
                        description:
                            "MIME type to match, exactly (\"image/png\") or by family (\"image/\" or \"image/*\")."
                    ),
                    "start": .string(
                        description:
                            "Only attachments created at or after this time. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "Only attachments created before this time. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "limit": .integer(
                        description: "Maximum attachments to return",
                        default: .int(50)
                    ),
                    "offset": .integer(
                        description: "Attachments to skip before returning results, for paging. Defaults to 0.",
                        default: .int(0)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Message Attachments",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let chatGUID = arguments["chat_id"]?.stringValue
            let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 500)
            let offset = min(max(arguments["offset"]?.intValue ?? 0, 0), 100_000)
            let mimeType = arguments["mime_type"]?.stringValue
            let start = try Self.optionalBoundary("start", from: arguments, isEnd: false)
            let end = try Self.optionalBoundary("end", from: arguments, isEnd: true)
            if let start, let end, start > end {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
                )
            }
            let participants = try Self.participantArgument(arguments)
            try await self.activate()

            let attachments = try self.withDatabaseReader { reader -> [MessageAttachment] in
                var handles: [String] = []
                if !participants.isEmpty {
                    handles = try reader.participantHandles(matching: participants)
                    // No known handle means no conversation to search, which is
                    // an empty result rather than an unfiltered one.
                    if handles.isEmpty { return [] }
                }
                return try reader.attachments(
                    matching: MessageAttachmentFilter(
                        chatGUID: chatGUID,
                        participantHandles: handles,
                        mimeType: mimeType,
                        start: start,
                        end: end,
                        limit: limit,
                        offset: offset
                    )
                )
            }
            let formatter = ISO8601DateFormatter()
            let described: [Value] = attachments.map { attachment in
                var entry: [String: Value] = [
                    "id": .string(attachment.id),
                    "isSticker": .bool(attachment.isSticker),
                    "sizeBytes": .int(attachment.sizeBytes),
                    "availability": .string(Self.availability(of: attachment).rawValue),
                ]
                if let name = attachment.name { entry["name"] = .string(name) }
                if let mime = attachment.mimeType { entry["mimeType"] = .string(mime) }
                if let uti = attachment.uti { entry["uti"] = .string(uti) }
                if let chat = attachment.chatGUID { entry["chatId"] = .string(chat) }
                if let message = attachment.messageGUID { entry["messageId"] = .string(message) }
                if let created = attachment.created {
                    entry["created"] = .string(formatter.string(from: created))
                }
                return .object(entry)
            }
            var response: [String: Value] = [
                "count": .int(described.count),
                "attachments": .array(described),
            ]
            if offset > 0 { response["offset"] = .int(offset) }
            response["hasMore"] = .bool(described.count == limit)
            return Value.object(response)
        }

        Tool(
            name: "messages_fetch_attachment",
            description:
                "Get one Messages attachment's bytes as base64, by the id from messages_attachments. "
                + "Returns up to \(maximumInlineMessageAttachmentBytes / 1024)KB by default and "
                + "\(maximumRequestableMessageAttachmentBytes / 1024)KB at most, so a client that is not running "
                + "on this Mac can actually read a photo or document. Says which of missing file, "
                + "not-downloaded-from-iCloud, or too large applies when it cannot.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Attachment id from messages_attachments"
                    ),
                    "max_bytes": .integer(
                        description:
                            "Largest attachment to return inline, in bytes. Capped at \(maximumRequestableMessageAttachmentBytes).",
                        default: .int(maximumInlineMessageAttachmentBytes)
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Message Attachment",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard
                let id = arguments["id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
            else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "An attachment id is required. Get one from messages_attachments."
                    ]
                )
            }
            let requested = arguments["max_bytes"]?.intValue ?? maximumInlineMessageAttachmentBytes
            let maximumBytes = min(max(requested, 1), maximumRequestableMessageAttachmentBytes)
            try await self.activate()

            guard
                let attachment = try self.withDatabaseReader({ reader in
                    try reader.attachment(id: id)
                })
            else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "NOT_FOUND: no attachment with id \"\(id)\". Ids come from messages_attachments "
                            + "and change if Messages re-imports the conversation."
                    ]
                )
            }

            let name = attachment.name ?? id
            let payload = try MessagesAttachmentContent.load(
                storedPath: attachment.storedPath,
                name: name,
                declaredSize: attachment.sizeBytes,
                maximumBytes: maximumBytes,
                mimeType: attachment.mimeType
            )

            log.notice("Fetched message attachment \(attachment.id, privacy: .private)")
            var entry: [String: Value] = [
                "id": .string(attachment.id),
                "name": .string(name),
                "byteCount": .int(payload.byteCount),
                "base64": .string(payload.data.base64EncodedString()),
            ]
            if let mime = payload.mimeType { entry["mimeType"] = .string(mime) }
            if let uti = attachment.uti { entry["uti"] = .string(uti) }
            if let chat = attachment.chatGUID { entry["chatId"] = .string(chat) }
            if let message = attachment.messageGUID { entry["messageId"] = .string(message) }
            if let created = attachment.created {
                entry["created"] = .string(ISO8601DateFormatter().string(from: created))
            }
            return Value.object(entry)
        }

        Tool(
            name: "messages_search",
            description:
                "Search message text approximately, ranked by how well each message matches. Unlike the "
                + "query filter on messages_fetch, this finds near matches: a misremembered phrase, a "
                + "misspelling, or words in a different order. Every result says whether the match was the "
                + "exact phrase, all of the words, or only an approximation, so an approximate hit is never "
                + "reported as the caller's own words.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "What to look for. Words are matched individually and approximately."
                    ),
                    "chat_id": .string(
                        description: "Restrict the search to one conversation (GUID from messages_list_chats)."
                    ),
                    "participants": .array(
                        description:
                            "Restrict the search to conversations with these handles (phone or email).",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "limit": .integer(
                        description: "Maximum matches to return",
                        default: .int(20)
                    ),
                    "minScore": .number(
                        description:
                            "Discard matches below this score, between 0 and 1. Raise it for fewer, closer results.",
                        default: .double(MessagesSearchMatching.defaultMinimumScore)
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard let query = arguments["query"]?.stringValue,
                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "A search query is required."]
                )
            }

            let participants = try Self.participantArgument(arguments)
            let chatID = arguments["chat_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 200)
            let minimumScore = min(
                max(arguments["minScore"]?.doubleCoerced ?? MessagesSearchMatching.defaultMinimumScore, 0),
                1
            )

            let start = try Self.optionalBoundary("start", from: arguments, isEnd: false)
            let end = try Self.optionalBoundary("end", from: arguments, isEnd: true)
            var dateRange: Range<Date>?
            if let start, let end {
                guard start < end else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "start must be before end."]
                    )
                }
                dateRange = start ..< end
            } else if let start {
                dateRange = start ..< Date.distantFuture
            } else if let end {
                dateRange = Date.distantPast ..< end
            }

            var chat: MessagesChatSummary?
            if let chatID, !chatID.isEmpty {
                chat = try self.withDatabaseReader { try $0.chat(guid: chatID) }
                guard chat != nil else {
                    throw NSError(
                        domain: "MessagesServiceError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "NOT_FOUND: no conversation with chat_id \"\(chatID)\". "
                                + "Use messages_list_chats to get a current chat id."
                        ]
                    )
                }
            }

            let handles = try Set(
                self.withDatabaseReader {
                    try $0.participantHandles(matching: participants)
                }.map { Account.Handle(rawValue: $0) }
            )
            if !participants.isEmpty, handles.isEmpty {
                return Value.object([
                    "query": .string(query),
                    "matches": .array([]),
                    "scanned": .int(0),
                ])
            }

            // Ranking needs a pool to rank. The pool is bounded so a search
            // cannot walk the entire history, and the bound is reported so a
            // caller can tell a thin answer from an exhaustive one.
            let poolSize = 4000
            let db = try self.createDatabaseConnection()
            var scanned = 0
            var scored: [(score: Double, kind: MessageMatchKind, entry: [String: Value], date: Date)] = []

            for message in try db.fetchMessages(
                for: chat.map { iMessage.Chat.ID(rawValue: $0.chatGUID) },
                with: handles,
                in: dateRange,
                limit: poolSize
            ) {
                guard !message.text.isEmpty else { continue }
                scanned += 1
                guard
                    let match = MessagesSearchMatching.match(
                        query: query,
                        text: message.text,
                        minimumScore: minimumScore
                    )
                else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else {
                    sender = message.sender?.rawValue ?? "unknown"
                }
                let entry: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": .object(["@id": .string(sender)]),
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "matchKind": .string(match.kind.rawValue),
                    "score": .double((match.score * 100).rounded() / 100),
                    "matchedWords": .array(match.matchedWords.map { .string($0) }),
                ]
                scored.append((match.score, match.kind, entry, message.date))
            }

            // Best match first; equally good matches, newest first.
            scored.sort { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.date > right.date
            }
            let page = Array(scored.prefix(limit))

            var result: [String: Value] = [
                "query": .string(query),
                "matches": .array(page.map { .object($0.entry) }),
                "matchCount": .int(page.count),
                "scanned": .int(scanned),
                "minScore": .double(minimumScore),
            ]
            if scanned >= poolSize {
                result["note"] = .string(
                    "Only the most recent \(poolSize) messages in scope were searched. "
                        + "Narrow by chat_id, participants or date range to search further back."
                )
            }
            if let chat { result["chatId"] = .string(chat.chatGUID) }
            return Value.object(result)
        }

        Tool(
            name: "messages_route_check",
            description:
                "Report how Messages on this Mac is likely to route a message to an address, based on what "
                + "it has done with that address before. This predicts the service (iMessage or SMS); it "
                + "does not and cannot guarantee that a message will be delivered. Read-only: it sends "
                + "nothing.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description: "Phone number or email address to check"
                    )
                ],
                required: ["recipient"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Check Message Routing",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let requested = arguments["recipient"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let recipient = requested, !recipient.isEmpty else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "A recipient is required."]
                )
            }
            guard isValidMessageParticipant(recipient) else {
                throw SendError.invalidRecipient
            }
            try await self.activate()

            let observations = try self.withDatabaseReader { reader in
                try reader.routeObservations(matching: [recipient])
            }
            let assessment = MessagesRouteDiagnostic.assess(
                address: recipient,
                observations: observations
            )

            let described: [Value] = assessment.observations.map { observation in
                var entry: [String: Value] = [
                    "handle": .string(observation.handle),
                    "messageCount": .int(observation.messageCount),
                ]
                if let service = MessagesRouteDiagnostic.normalizeService(observation.registeredService) {
                    entry["registeredService"] = .string(service)
                }
                if let service = MessagesRouteDiagnostic.normalizeService(observation.lastOutgoingService) {
                    entry["lastOutgoingService"] = .string(service)
                }
                if let date = observation.lastMessageDate {
                    entry["lastMessageAt"] = .string(date.formatted(.iso8601))
                }
                return .object(entry)
            }

            var result: [String: Value] = [
                "recipient": .string(recipient),
                "confidence": .string(assessment.confidence.rawValue),
                "summary": .string(assessment.summary),
                // Named so that no caller can read it as a delivery receipt.
                "deliveryGuaranteed": .bool(false),
                "deliveryCaveat": .string(assessment.deliveryCaveat),
                "handles": .array(described),
            ]
            if let service = assessment.likelyService {
                result["likelyService"] = .string(service)
            }
            return Value.object(result)
        }

        Tool(
            name: "messages_unread",
            description:
                "Show unread message counts per conversation, busiest first. Use this to answer "
                + "\"do I have any unread messages?\" without reading their contents.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum conversations to return",
                        default: .int(20)
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Unread Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 200)
            try await self.activate()

            let counts: [ChatUnreadCount] = try self.withDatabaseReader { reader in
                try reader.unreadCounts(limit: limit)
            }
            // The per-conversation query caps at `limit` rows; a true total
            // needs its own unbounded count or it misses everything past
            // the page.
            let totalUnread = try self.withDatabaseReader { reader in
                try reader.totalUnreadCount()
            }
            let described: [Value] = counts.map { chat in
                var entry: [String: Value] = [
                    "chatId": .string(chat.chatGUID),
                    "unreadCount": .int(chat.unreadCount),
                ]
                if let name = chat.displayName { entry["displayName"] = .string(name) }
                return .object(entry)
            }
            return Value.object([
                "totalUnread": .int(totalUnread),
                "conversations": .array(described),
            ])
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
                _ = try await scriptedMessagesApp.run(
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
            guard isValidMessageParticipant(recipient) else {
                throw SendError.invalidRecipient
            }

            let service = arguments["service"]?.stringValue ?? "iMessage"
            let address = self.resolveRecipientAddress(for: recipient)

            log.debug("Sending \(service) message to \(address)")
            _ = try await scriptedMessagesApp.run(
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

    /// Parses one optional ISO 8601 bound. Unlike messages_fetch, a single
    /// bound is honored here rather than refused: "attachments since Friday"
    /// is a normal request, and the bound is applied rather than dropped.
    private static func optionalBoundary(
        _ key: String,
        from arguments: [String: Value],
        isEnd: Bool
    ) throws -> Date? {
        guard let value = arguments[key] else { return nil }
        guard case .string(let raw) = value,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: raw)
        else {
            throw NSError(
                domain: "MessagesServiceError",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(key) must be a valid ISO 8601 date or date-time."
                ]
            )
        }
        let calendar = Calendar.current
        return isEnd
            ? calendar.normalizedEndDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
            : calendar.normalizedStartDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
    }

    /// The shared participant-array validation used by fetch and attachments.
    private static func participantArgument(_ arguments: [String: Value]) throws -> [String] {
        guard let value = arguments["participants"] else { return [] }
        guard case .array(let values) = value else {
            throw NSError(
                domain: "MessagesServiceError",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Participants must be an array of phone numbers or email addresses."
                ]
            )
        }
        return try values.map { element in
            guard case .string(let raw) = element else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Each participant must be a phone number or email address."
                    ]
                )
            }
            let participant = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidMessageParticipant(participant) else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Each participant must be a nonempty phone number or email address."
                    ]
                )
            }
            return participant
        }
    }

    /// Whether the file behind a row is actually readable on this Mac, so a
    /// listing can say so before a client spends a call finding out.
    private static func availability(of attachment: MessageAttachment)
        -> MessagesAttachmentAvailability
    {
        MessagesAttachmentContent.availability(
            storedPath: attachment.storedPath,
            name: attachment.name ?? attachment.id,
            declaredSize: attachment.sizeBytes
        )
    }

    private enum SendError: LocalizedError {
        case emptyBody
        case missingRecipient
        case invalidRecipient

        var errorDescription: String? {
            switch self {
            case .emptyBody:
                return "Message body must not be empty"
            case .missingRecipient:
                return "Provide either `recipient` (phone/email) or `chat_id` (chat GUID)"
            case .invalidRecipient:
                return "Recipient must be a valid phone number or email address"
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

        if let matches = try? withDatabaseReader({
            try $0.participantHandles(matching: [recipient], limit: 1)
        }), let match = matches.first {
            log.debug("Matched recipient to existing handle \(match)")
            return match
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

    /// The chat.db path, resolved the same way `createDatabaseConnection`
    /// resolves it, for the direct reader that covers the columns madrid does
    /// not model. Runs the bookmark's security scope for the duration of the
    /// read rather than just to compute a path.
    /// Which message kinds a fetch should return.
    ///
    /// The default is the one kind a caller reading a conversation means:
    /// what people actually sent. Reactions and join/leave notices are real
    /// rows in chat.db, and they are available, but they arrive only when
    /// asked for so an ordinary read is not buried in them.
    static func includedKinds(_ argument: Value?) throws -> Set<MessageKind> {
        guard let argument else { return [.message] }
        guard case .array(let entries) = argument else {
            throw NSError(
                domain: "MessagesServiceError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "include must be an array of strings."]
            )
        }
        if entries.isEmpty { return [.message] }
        var kinds: Set<MessageKind> = []
        for entry in entries {
            guard let raw = entry.stringValue, let kind = MessageKind(rawValue: raw) else {
                throw NSError(
                    domain: "MessagesServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "include must contain only "
                            + MessageKind.allCases.map(\.rawValue).joined(separator: ", ")
                            + "."
                    ]
                )
            }
            kinds.insert(kind)
        }
        return kinds
    }

    /// Folds the chat.db columns madrid omits into one message entry. Only
    /// fields that carry a value are written, so an ordinary message does not
    /// grow a row of nulls.
    static func annotate(_ entry: inout [String: Value], with detail: MessageMetadata) {
        let formatter = ISO8601DateFormatter()
        if let service = detail.service { entry["service"] = .string(service) }
        entry["isRead"] = .bool(detail.isRead)
        if let read = detail.dateRead { entry["readAt"] = .string(formatter.string(from: read)) }
        if let delivered = detail.dateDelivered {
            entry["deliveredAt"] = .string(formatter.string(from: delivered))
        }
        if let subject = detail.subject { entry["subject"] = .string(subject) }
        if let style = detail.expressiveSendStyle { entry["expressiveSendStyle"] = .string(style) }
        if let bundle = detail.balloonBundleID { entry["appBundleIdentifier"] = .string(bundle) }
        if !detail.attachmentNames.isEmpty {
            entry["attachments"] = .array(detail.attachmentNames.map { .string($0) })
        }

        let annotation = detail.annotation
        if annotation.isEdited { entry["isEdited"] = .bool(true) }
        if annotation.isRetracted { entry["isRetracted"] = .bool(true) }
        if let tapback = annotation.tapback { entry["tapback"] = .string(tapback) }
        if let emoji = annotation.tapbackEmoji { entry["tapbackEmoji"] = .string(emoji) }
        if let description = annotation.groupEventDescription {
            entry["event"] = .string(description)
        }
        switch annotation.kind {
        case .tapback, .tapbackRemoved:
            // For a tapback the associated GUID is the message reacted to.
            if let target = annotation.targetMessageGUID {
                entry["reactionTo"] = .string(target)
            }
        default:
            if let reply = detail.replyToGUID { entry["inReplyTo"] = .string(reply) }
        }
    }

    private func withDatabaseReader<T>(_ body: (MessagesDatabaseReader) throws -> T) throws -> T {
        if canAccessDatabaseAtDefaultPath {
            return try body(MessagesDatabaseReader(path: messagesDatabasePath))
        }
        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try body(MessagesDatabaseReader(path: url.path))
        }
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
