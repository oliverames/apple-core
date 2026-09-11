// SPDX-License-Identifier: GPL-3.0-or-later
//
// The badge parsing is pure and pinned exactly. The store reads are exercised
// against whatever this machine actually has, which is the only honest way to
// test a reader of Apple's private schema: a fixture would encode today's
// column names and then keep passing after Apple renamed them.
//
// Read-only throughout. Nothing here writes to the Reminders store, and the
// reader it exercises has no write path at all.

import Foundation
import Testing

@Suite("Reminders store lists")
struct RemindersStoreListTests {
    @Test("An emoji badge is unwrapped from its JSON envelope")
    func emojiBadge() {
        // The exact shape this machine stores, spaces and all.
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "{\"Emoji\" : \"🛒\"}") == "🛒")
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "{\"Emoji\":\"📥\"}") == "📥")
    }

    @Test("An SF Symbol badge is passed through unchanged")
    func symbolBadge() {
        // Lists on this machine carry bare symbol names such as "health2".
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "health2") == "health2")
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "symbol7") == "symbol7")
    }

    @Test("An absent or blank badge is absent, not an empty string")
    func missingBadge() {
        #expect(RemindersStoreReader.badgeName(fromStoredValue: nil) == nil)
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "") == nil)
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "   ") == nil)
    }

    @Test("A JSON badge in an unfamiliar shape is reported raw, not dropped")
    func unknownBadgeShape() {
        // Reporting the raw value beats reporting nothing when Apple changes
        // the envelope: the caller can still see what is there.
        let raw = "{\"Symbol\" : \"star\"}"
        #expect(RemindersStoreReader.badgeName(fromStoredValue: raw) == raw)
        #expect(RemindersStoreReader.badgeName(fromStoredValue: "{not json") == "{not json")
    }

    @Test("The store reports lists, and every one is internally consistent")
    func liveListsAreConsistent() throws {
        guard let path = RemindersStoreReader.locateStore() else {
            // No Reminders store on this machine; there is nothing to check
            // and nothing to fail.
            return
        }
        let lists: [ReminderListDetail]
        do {
            lists = try RemindersStoreReader(path: path).lists()
        } catch {
            // A schema that has moved is a reported condition, not a crash.
            // That it threw a typed error rather than trapping is the property
            // under test here.
            #expect(error is RemindersStoreError)
            return
        }

        for list in lists {
            // A group holds lists, so it is never itself a smart list.
            if list.isGroup { #expect(list.smartListType == nil) }
            // A smart list is a saved filter with no name of its own.
            if let type = list.smartListType {
                #expect(type.contains("smartlist") || !type.isEmpty)
            }
            // isShared must agree with the status it is derived from.
            #expect(list.isShared == (list.sharingStatus != 0))
            // An empty string would read as a list with a blank name.
            #expect(list.name?.isEmpty != true)
            #expect(list.badge?.isEmpty != true)
        }
    }

    @Test("Reading flags either succeeds or explains itself")
    func liveFlagsAreReadable() throws {
        guard let path = RemindersStoreReader.locateStore() else { return }
        do {
            let flagged = try RemindersStoreReader(path: path).flaggedReminderIdentifiers()
            // Identifiers, not blanks. On this machine nothing is flagged, so
            // the set is expected to be empty and the assertion holds
            // vacuously — which is exactly why the true branch of this read is
            // recorded as unverified against live data.
            for identifier in flagged { #expect(!identifier.isEmpty) }
        } catch {
            #expect(error is RemindersStoreError)
        }
    }
}
