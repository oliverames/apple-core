// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deciding what changed between the index and the store.
//
// The hard part of a mail index is not building it, it is the second run.
// Between two passes a message can be read, moved to another mailbox,
// deleted, or finally downloaded in full, and each of those looks similar on
// disk: a file that used to be at one path is not there any more, and a file
// that was not at another path now is.
//
// Getting that wrong has two failure shapes, and both are worse than a slow
// scan. A move recorded as an insert without the matching delete leaves the
// same message in the index twice, under two mailboxes. A move recorded as a
// delete without the matching insert makes the message disappear from a
// mailbox it is sitting in.
//
// So the plan is computed as a whole before anything is written, and applied
// in one transaction. Moves are recognised by Message-ID: the header is
// stable across a move, while the path and Mail's file id are not.
//
// This file is pure. It takes what the index holds and what the disk holds
// and returns the difference, which is what lets the move, delete and
// partial-download cases be tested without a mailbox.

import Foundation

/// What the index already believes about one message.
struct MailIndexEntry: Sendable, Equatable {
    let stableID: String
    let accountID: String
    let mailbox: String
    let messageID: String?
    let sizeBytes: Int
    let modified: Date
    let isPartial: Bool

    init(
        stableID: String,
        accountID: String,
        mailbox: String,
        messageID: String?,
        sizeBytes: Int,
        modified: Date,
        isPartial: Bool
    ) {
        self.stableID = stableID
        self.accountID = accountID
        self.mailbox = mailbox
        self.messageID = messageID
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.isPartial = isPartial
    }
}

/// Why a message's index row changed identity.
enum MailIndexCarryKind: String, Sendable, Equatable, Codable {
    /// Same message, different mailbox.
    case moved
    /// Same message in the same mailbox, promoted from `.partial.emlx` to a
    /// complete file: the body finished downloading.
    case downloaded
}

struct MailIndexCarry: Sendable, Equatable, Codable {
    let kind: MailIndexCarryKind
    let messageID: String
    let fromMailbox: String
    let toMailbox: String
    let fromStableID: String
    let toStableID: String
}

struct MailIndexPlan: Sendable, Equatable {
    /// Files with no index row, which have to be parsed and inserted.
    let inserted: [MailScannedMessageFile]
    /// Files whose size or modification date moved under an existing row.
    let updated: [MailScannedMessageFile]
    let unchangedIDs: [String]
    /// Index rows whose file is gone. Includes the old row of a move, which
    /// is why removal and insertion have to be applied together.
    let removedIDs: [String]
    let carried: [MailIndexCarry]

    var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removedIDs.isEmpty
    }
}

enum MailIndexReconciler {
    /// Diffs the index against the store.
    ///
    /// `messageIDs` maps a scanned file's stable id to the Message-ID parsed
    /// out of it. Only newly seen files need an entry: an unchanged file's
    /// identifier is already in the index, and a file whose header cannot be
    /// read simply takes part in no move detection.
    static func plan(
        existing: [MailIndexEntry],
        scanned: [MailScannedMessageFile],
        messageIDs: [String: String] = [:]
    ) -> MailIndexPlan {
        var existingByID: [String: MailIndexEntry] = [:]
        for entry in existing { existingByID[entry.stableID] = entry }

        var inserted: [MailScannedMessageFile] = []
        var updated: [MailScannedMessageFile] = []
        var unchanged: [String] = []
        var seen: Set<String> = []
        var carried: [MailIndexCarry] = []

        for file in scanned {
            seen.insert(file.stableID)
            guard let entry = existingByID[file.stableID] else {
                inserted.append(file)
                continue
            }
            // A partial file that is still partial is re-read anyway: the
            // body may have grown without the file being replaced, and an
            // index that reports an incomplete body has to keep checking.
            let changed =
                entry.sizeBytes != file.sizeBytes
                || abs(entry.modified.timeIntervalSince(file.modified)) >= 1
                || entry.isPartial != file.isPartial
                || file.isPartial
            if changed {
                updated.append(file)
                // Mail finishes a download by renaming `<id>.partial.emlx`
                // to `<id>.emlx`, which keeps the file id and so keeps the
                // index row. The body arriving is still an event worth
                // reporting, so it is carried out of the plan here rather
                // than inferred from the move detection below.
                if entry.isPartial, !file.isPartial {
                    carried.append(
                        MailIndexCarry(
                            kind: .downloaded,
                            messageID: entry.messageID ?? messageIDs[file.stableID] ?? "",
                            fromMailbox: "\(entry.accountID)/\(entry.mailbox)",
                            toMailbox: "\(file.accountID)/\(file.mailbox)",
                            fromStableID: entry.stableID,
                            toStableID: file.stableID
                        )
                    )
                }
            } else {
                unchanged.append(file.stableID)
            }
        }

        let removed = existing.filter { !seen.contains($0.stableID) }

        // Move and download detection. A removed row whose Message-ID turns
        // up under a newly inserted file is the same message in a new place,
        // not a deletion and an arrival.
        var insertedByMessageID: [String: MailScannedMessageFile] = [:]
        for file in inserted {
            guard let identifier = messageIDs[file.stableID], !identifier.isEmpty else { continue }
            // First writer wins, so two copies of one message cannot both
            // claim to be the destination of the same move.
            if insertedByMessageID[identifier] == nil {
                insertedByMessageID[identifier] = file
            }
        }

        var claimed: Set<String> = []
        for entry in removed {
            guard let identifier = entry.messageID, !identifier.isEmpty,
                let destination = insertedByMessageID[identifier],
                !claimed.contains(destination.stableID)
            else { continue }
            claimed.insert(destination.stableID)
            let sameMailbox =
                destination.mailbox == entry.mailbox && destination.accountID == entry.accountID
            carried.append(
                MailIndexCarry(
                    kind: sameMailbox && entry.isPartial ? .downloaded : .moved,
                    messageID: identifier,
                    fromMailbox: "\(entry.accountID)/\(entry.mailbox)",
                    toMailbox: "\(destination.accountID)/\(destination.mailbox)",
                    fromStableID: entry.stableID,
                    toStableID: destination.stableID
                )
            )
        }

        return MailIndexPlan(
            inserted: inserted,
            updated: updated,
            unchangedIDs: unchanged,
            removedIDs: removed.map(\.stableID),
            carried: carried
        )
    }

    /// Message-IDs the store holds more than once.
    ///
    /// A copy left behind by a move that Mail has not finished, or a message
    /// filed into two mailboxes, is a real state and not an error. It is
    /// reported rather than deduplicated, because collapsing it would hide a
    /// mailbox the message is genuinely in.
    static func duplicateMessageIDs(in entries: [MailIndexEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let identifier = entry.messageID, !identifier.isEmpty else { continue }
            counts[identifier, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }
}
