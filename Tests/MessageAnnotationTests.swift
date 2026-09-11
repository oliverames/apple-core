// SPDX-License-Identifier: GPL-3.0-or-later
//
// The expectations here are calibrated against the real chat.db on this Mac,
// read on 2026-09-11: 2,531 tapback rows spread over associated types 2000-2007
// plus 3006, 790 rows carrying thread_originator_guid, 173 with date_edited,
// and 69 with a non-zero item_type. The type numbers below are not invented.

import Foundation
import Testing

@Suite("Message annotation")
struct MessageAnnotationTests {
    @Test("A plain text message is a message")
    func plainMessage() {
        let result = MessageAnnotator.annotate(MessageAnnotationInput(hasText: true))
        #expect(result.kind == .message)
        #expect(result.tapback == nil)
        #expect(result.isEdited == false)
        #expect(result.isRetracted == false)
    }

    @Test("An attachment with no text is still a message, not an empty row")
    func attachmentOnlyMessage() {
        // 1,341 rows on this machine have empty text and an attachment. The old
        // fetch dropped every one of them.
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(attachmentCount: 1, hasText: false)
        )
        #expect(result.kind == .message)
        #expect(result.attachmentCount == 1)
    }

    @Test("A row with no text, no attachment and no event reports as empty")
    func genuinelyEmpty() {
        let result = MessageAnnotator.annotate(MessageAnnotationInput(hasText: false))
        #expect(result.kind == .empty)
    }

    @Test(
        "Each tapback type maps to its name",
        arguments: [
            (2000, "loved"), (2001, "liked"), (2002, "disliked"),
            (2003, "laughed"), (2004, "emphasized"), (2005, "questioned"),
            (2006, "emoji"), (2007, "sticker"),
        ]
    )
    func tapbackNames(type: Int, expected: String) {
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(associatedMessageType: type)
        )
        #expect(result.kind == .tapback)
        #expect(result.tapback == expected)
    }

    @Test("The 3000 block is the same tapbacks being taken back")
    func removedTapbacks() {
        for offset in 0 ... 7 {
            let added = MessageAnnotator.annotate(
                MessageAnnotationInput(associatedMessageType: 2000 + offset)
            )
            let removed = MessageAnnotator.annotate(
                MessageAnnotationInput(associatedMessageType: 3000 + offset)
            )
            #expect(removed.kind == .tapbackRemoved)
            // Same style, opposite direction.
            #expect(removed.tapback == added.tapback)
        }
    }

    @Test("An emoji tapback carries the emoji it was given")
    func emojiTapback() {
        // 299 of the 300 type-2006 rows on this Mac carry the emoji column.
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(
                associatedMessageType: 2006,
                associatedMessageEmoji: "🤣"
            )
        )
        #expect(result.tapback == "emoji")
        #expect(result.tapbackEmoji == "🤣")
    }

    @Test("An unrecognised associated type is not treated as a tapback")
    func unknownAssociatedType() {
        // Type 4000 exists on this Mac (one row) and is outside both blocks.
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(associatedMessageType: 4000, hasText: true)
        )
        #expect(result.kind == .message)
        #expect(result.tapback == nil)
    }

    @Test(
        "The part prefix is stripped off a target GUID",
        arguments: [
            ("p:0/ABC-123", "ABC-123"),
            ("p:12/ABC-123", "ABC-123"),
            ("bp:ABC-123", "ABC-123"),
            ("ABC-123", "ABC-123"),
        ]
    )
    func targetGUIDNormalization(raw: String, expected: String) {
        #expect(MessageAnnotator.normalizedTargetGUID(raw) == expected)
    }

    @Test("An empty or absent target GUID is absent, not an empty string")
    func emptyTargetGUID() {
        #expect(MessageAnnotator.normalizedTargetGUID(nil) == nil)
        #expect(MessageAnnotator.normalizedTargetGUID("") == nil)
        #expect(MessageAnnotator.normalizedTargetGUID("p:0/") == nil)
    }

    @Test("A GUID with no part prefix survives intact")
    func guidWithoutPrefix() {
        // Apple's GUIDs are uppercase UUIDs, sometimes with a service prefix
        // that is longer than a part marker. Neither may be truncated.
        let raw = "1A2B3C4D-5E6F-7081-9A0B-C1D2E3F40506"
        #expect(MessageAnnotator.normalizedTargetGUID(raw) == raw)
    }

    @Test("A group rename reports the new name")
    func groupRename() {
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(itemType: 2, groupTitle: "Trip planning", hasText: false)
        )
        #expect(result.kind == .groupEvent)
        #expect(result.groupEventDescription == "The conversation was named \"Trip planning\"")
    }

    @Test("Joining and leaving are distinguished by the action type")
    func joinAndLeave() {
        let added = MessageAnnotator.annotate(
            MessageAnnotationInput(itemType: 1, groupActionType: 0, hasText: false)
        )
        let left = MessageAnnotator.annotate(
            MessageAnnotationInput(itemType: 1, groupActionType: 1, hasText: false)
        )
        #expect(added.groupEventDescription?.contains("added") == true)
        #expect(left.groupEventDescription?.contains("left") == true)
    }

    @Test("An unknown item type is reported as an event rather than guessed at")
    func unknownItemType() {
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(itemType: 99, hasText: false)
        )
        #expect(result.kind == .groupEvent)
        #expect(result.groupEventDescription == "A conversation event occurred")
    }

    @Test("Edited and retracted are reported independently of kind")
    func editedAndRetracted() {
        let edited = MessageAnnotator.annotate(
            MessageAnnotationInput(dateEdited: Date(), hasText: true)
        )
        #expect(edited.kind == .message)
        #expect(edited.isEdited)
        #expect(edited.isRetracted == false)

        let retracted = MessageAnnotator.annotate(
            MessageAnnotationInput(dateRetracted: Date(), hasText: false)
        )
        #expect(retracted.isRetracted)
    }

    @Test("An ordinary message can still point at the message it replies to")
    func inlineReply() {
        let result = MessageAnnotator.annotate(
            MessageAnnotationInput(associatedMessageGUID: "p:0/PARENT", hasText: true)
        )
        #expect(result.kind == .message)
        #expect(result.targetMessageGUID == "PARENT")
    }

    @Test("Service names pass through, and Apple services are recognised")
    func serviceNames() {
        // The four values present on this Mac.
        #expect(MessageServiceName.normalized("iMessage") == "iMessage")
        #expect(MessageServiceName.normalized("  ") == nil)
        #expect(MessageServiceName.normalized(nil) == nil)
        #expect(MessageServiceName.isAppleService("iMessage"))
        #expect(MessageServiceName.isAppleService("iMessageLite"))
        #expect(MessageServiceName.isAppleService("SMS") == false)
        #expect(MessageServiceName.isAppleService("RCS") == false)
    }
}
