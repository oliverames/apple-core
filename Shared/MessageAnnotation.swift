// SPDX-License-Identifier: GPL-3.0-or-later
//
// Semantics for the chat.db columns that say what a message actually *is*.
//
// `messages_fetch` used to answer with sender, text and date, and skip every
// row whose `text` was empty. On this machine that silently discarded 4,534 of
// 17,596 messages: every attachment-only message, every tapback, and every
// "you were added to the conversation" event. A reader that drops a quarter of
// a thread is not a reader of that thread.
//
// The raw columns are integers and opaque GUID strings. Turning them into
// something a caller can act on is pure arithmetic over plain values, so it
// lives here, in Shared/, with tests — not inside a SQLite cursor.
//
// Verified against ~/Library/Messages/chat.db on macOS 27.0 on 2026-09-11:
// 2,531 tapbacks across types 2000-2007/3006/4000, 790 threaded replies,
// 173 edited messages, 69 group events, 6 expressive sends, and services
// iMessage, iMessageLite, SMS and RCS.

import Foundation

/// The raw chat.db columns this module interprets. One value per message row,
/// carried as plain data so the interpretation can be tested without a
/// database.
public struct MessageAnnotationInput: Sendable, Equatable {
    public var associatedMessageType: Int
    public var associatedMessageGUID: String?
    public var associatedMessageEmoji: String?
    public var itemType: Int
    public var groupActionType: Int
    public var groupTitle: String?
    public var dateEdited: Date?
    public var dateRetracted: Date?
    public var attachmentCount: Int
    public var hasText: Bool

    public init(
        associatedMessageType: Int = 0,
        associatedMessageGUID: String? = nil,
        associatedMessageEmoji: String? = nil,
        itemType: Int = 0,
        groupActionType: Int = 0,
        groupTitle: String? = nil,
        dateEdited: Date? = nil,
        dateRetracted: Date? = nil,
        attachmentCount: Int = 0,
        hasText: Bool = true
    ) {
        self.associatedMessageType = associatedMessageType
        self.associatedMessageGUID = associatedMessageGUID
        self.associatedMessageEmoji = associatedMessageEmoji
        self.itemType = itemType
        self.groupActionType = groupActionType
        self.groupTitle = groupTitle
        self.dateEdited = dateEdited
        self.dateRetracted = dateRetracted
        self.attachmentCount = attachmentCount
        self.hasText = hasText
    }
}

/// What kind of thing a row in `message` is. A caller filtering a conversation
/// down to "what people said" wants `.message`; a caller reconstructing the
/// thread wants all of them.
public enum MessageKind: String, Sendable, CaseIterable {
    /// An ordinary message: text, attachments, or both.
    case message
    /// A tapback added to another message.
    case tapback
    /// A tapback that was taken back off another message.
    case tapbackRemoved = "tapback_removed"
    /// A conversation event: someone joined, left, or renamed the group.
    case groupEvent = "group_event"
    /// The row exists but carries no text, no attachment and no event. Apple
    /// leaves these behind; they are reported rather than hidden so a caller
    /// counting a thread gets the same total the database has.
    case empty
}

/// A named tapback. `emoji` and `sticker` carry no fixed name, so the emoji
/// itself is reported alongside.
public enum TapbackStyle: String, Sendable {
    case loved, liked, disliked, laughed, emphasized, questioned
    case emoji, sticker
    case unknown
}

/// The interpreted form of one message row.
public struct MessageAnnotation: Sendable, Equatable {
    public var kind: MessageKind
    /// Non-nil for `.tapback` and `.tapbackRemoved`.
    public var tapback: String?
    /// The custom emoji, for an emoji tapback.
    public var tapbackEmoji: String?
    /// GUID of the message a tapback or reply points at, with chat.db's
    /// `p:0/` / `bp:` part prefix stripped.
    public var targetMessageGUID: String?
    /// A short sentence describing a group event, when this is one.
    public var groupEventDescription: String?
    public var isEdited: Bool
    public var isRetracted: Bool
    public var attachmentCount: Int
}

public enum MessageAnnotator {
    /// chat.db numbers the tapbacks from 2000 and the removals from 3000, with
    /// the same offset for both. Verified on macOS 27.0: 2006 is a custom
    /// emoji reaction (299 of 300 rows carry `associated_message_emoji`) and
    /// 2007 is a sticker reaction.
    static func style(forAssociatedType type: Int) -> TapbackStyle? {
        let offset: Int
        switch type {
        case 2000 ... 2007: offset = type - 2000
        case 3000 ... 3007: offset = type - 3000
        default: return nil
        }
        switch offset {
        case 0: return .loved
        case 1: return .liked
        case 2: return .disliked
        case 3: return .laughed
        case 4: return .emphasized
        case 5: return .questioned
        case 6: return .emoji
        case 7: return .sticker
        default: return .unknown
        }
    }

    /// chat.db writes the target of a tapback or an inline reply as
    /// `p:<part index>/<guid>` or `bp:<guid>`. Callers want the GUID, which is
    /// what every other tool in the surface accepts.
    public static func normalizedTargetGUID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let slash = raw.firstIndex(of: "/") else {
            // "bp:GUID" has no slash; a bare GUID has neither.
            if let colon = raw.firstIndex(of: ":"), raw[raw.startIndex ..< colon].count <= 3 {
                let tail = String(raw[raw.index(after: colon)...])
                return tail.isEmpty ? nil : tail
            }
            return raw
        }
        let tail = String(raw[raw.index(after: slash)...])
        return tail.isEmpty ? nil : tail
    }

    /// `item_type` 1-6 mark the conversation events Messages draws as grey
    /// centred lines. `group_action_type` separates adding from removing.
    /// Anything unrecognised is described as an event rather than guessed at.
    static func groupEventDescription(itemType: Int, groupActionType: Int, groupTitle: String?)
        -> String?
    {
        switch itemType {
        case 1:
            return groupActionType == 1
                ? "A participant left the conversation"
                : "A participant was added to the conversation"
        case 2:
            if let groupTitle, !groupTitle.isEmpty {
                return "The conversation was named \"\(groupTitle)\""
            }
            return "The conversation was renamed"
        case 3:
            return groupActionType == 1
                ? "The conversation photo was removed"
                : "The conversation photo was changed"
        case 4:
            return "A participant's location sharing changed"
        case 5:
            return "A message was marked as unread"
        case 6:
            return "A participant changed their name"
        default:
            return itemType == 0 ? nil : "A conversation event occurred"
        }
    }

    /// Interpret one row.
    public static func annotate(_ input: MessageAnnotationInput) -> MessageAnnotation {
        let isEdited = input.dateEdited != nil
        let isRetracted = input.dateRetracted != nil
        let target = normalizedTargetGUID(input.associatedMessageGUID)

        if let style = style(forAssociatedType: input.associatedMessageType) {
            // A removal reuses the same styles from the 3000 block.
            let removed = (3000 ... 3007).contains(input.associatedMessageType)
            return MessageAnnotation(
                kind: removed ? .tapbackRemoved : .tapback,
                tapback: style.rawValue,
                tapbackEmoji: input.associatedMessageEmoji,
                targetMessageGUID: target,
                groupEventDescription: nil,
                isEdited: isEdited,
                isRetracted: isRetracted,
                attachmentCount: input.attachmentCount
            )
        }

        if input.itemType != 0,
            let description = groupEventDescription(
                itemType: input.itemType,
                groupActionType: input.groupActionType,
                groupTitle: input.groupTitle
            )
        {
            return MessageAnnotation(
                kind: .groupEvent,
                tapback: nil,
                tapbackEmoji: nil,
                targetMessageGUID: target,
                groupEventDescription: description,
                isEdited: isEdited,
                isRetracted: isRetracted,
                attachmentCount: input.attachmentCount
            )
        }

        let carriesSomething = input.hasText || input.attachmentCount > 0
        return MessageAnnotation(
            kind: carriesSomething ? .message : .empty,
            tapback: nil,
            tapbackEmoji: nil,
            // An ordinary message can still point at another one: that is an
            // inline reply, and the target is the message being replied to.
            targetMessageGUID: target,
            groupEventDescription: nil,
            isEdited: isEdited,
            isRetracted: isRetracted,
            attachmentCount: input.attachmentCount
        )
    }
}

/// The `service` column is a free-form string. These are the values observed
/// on macOS 27.0; anything else is passed through unchanged rather than
/// forced into one of them.
public enum MessageServiceName {
    public static func normalized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }

    /// True for the services Apple carries itself, which is what decides
    /// whether features like edit and unsend are available on a message.
    public static func isAppleService(_ raw: String?) -> Bool {
        guard let raw = normalized(raw)?.lowercased() else { return false }
        return raw.hasPrefix("imessage")
    }
}
