// SPDX-License-Identifier: GPL-3.0-or-later
//
// One mailbox, two vocabularies, and the translation between them.
//
// Mail stores each account in a directory named by the account's UUID, so the
// index speaks in keys like `B2369C0E-…/INBOX`. Every Apple Events tool in
// this service speaks display names instead: `iCloud`, `Work`, `INBOX`. The
// two names refer to the same mailbox and neither side knows the other's.
//
// The join is Mail's own `account.id`, which is exactly the V10 directory
// name. That fact is what makes this file possible; the descriptors are read
// through Apple Events by the caller and matched here, so the matching is
// testable without Mail running and without touching a real mailbox.
//
// Three honesty rules shape the result:
//
//   - An account directory with no matching live account is reported with a
//     null display name rather than a guessed one. Mail leaves directories
//     behind when an account is removed, sometimes renamed `OrphanedAccount -
//     <UUID>`, and their messages are genuinely still on disk.
//   - A name the caller gives that matches nothing is refused, with the real
//     vocabulary listed, rather than quietly searching everything.
//   - A bare mailbox path like `INBOX` deliberately matches every account's
//     INBOX, because that is what a person means, and the result says which
//     mailboxes it expanded to.

import Foundation

/// A live Mail account, as Apple Events reports it.
struct MailAccountDescriptor: Sendable, Equatable, Codable {
    /// Mail's own account id, which is the V10 account directory name.
    let id: String
    /// The display name every other Mail tool takes.
    let name: String
    let emailAddresses: [String]

    init(id: String, name: String, emailAddresses: [String] = []) {
        self.id = id
        self.name = name
        self.emailAddresses = emailAddresses
    }
}

/// One indexed mailbox under both names.
struct MailMailboxName: Sendable, Equatable, Codable {
    /// The index key: `<account directory>/<mailbox path>`.
    let key: String
    let accountID: String
    /// Nil when no live account claims this directory.
    let accountName: String?
    let mailbox: String
    /// What to show a person: `iCloud/INBOX`, or the key when the account is
    /// unknown.
    let displayPath: String
    /// True for a directory Mail has marked as belonging to a removed account.
    let orphaned: Bool
    /// Whether `accountName` can be handed to the Apple Events Mail tools.
    let addressableByAppleEvents: Bool
}

/// What a caller's mailbox argument turned into.
struct MailMailboxResolution: Sendable, Equatable {
    /// Index keys to search, in index order.
    let keys: [String]
    let matched: [MailMailboxName]
    /// Arguments that named nothing in the index.
    let unmatched: [String]
}

enum MailMailboxNaming {
    private static let orphanPrefix = "OrphanedAccount - "

    /// Every indexed mailbox, named both ways.
    static func names(
        keys: [String],
        accounts: [MailAccountDescriptor]
    ) -> [MailMailboxName] {
        var byID: [String: MailAccountDescriptor] = [:]
        for account in accounts { byID[account.id.lowercased()] = account }

        return keys.compactMap { key in
            guard let separator = key.firstIndex(of: "/") else { return nil }
            let accountID = String(key[key.startIndex ..< separator])
            let mailbox = String(key[key.index(after: separator)...])
            let orphaned = accountID.hasPrefix(orphanPrefix)
            // An orphaned directory still carries the UUID it was made from,
            // and occasionally the account comes back, so try it.
            let lookupID = orphaned ? String(accountID.dropFirst(orphanPrefix.count)) : accountID
            let account = byID[lookupID.lowercased()]
            return MailMailboxName(
                key: key,
                accountID: accountID,
                accountName: account?.name,
                mailbox: mailbox,
                displayPath: account.map { "\($0.name)/\(mailbox)" } ?? key,
                orphaned: orphaned,
                addressableByAppleEvents: account != nil && !orphaned
            )
        }
    }

    /// Turns caller-supplied mailbox arguments into index keys.
    ///
    /// Accepted, in order of specificity: the index key itself; an account
    /// display name or email address with a mailbox path; an account name
    /// alone, meaning all of its mailboxes; and a bare mailbox path, meaning
    /// that mailbox in every account. Matching is case-insensitive because
    /// Mail's own mailbox names are.
    static func resolve(
        _ requested: [String],
        keys: [String],
        accounts: [MailAccountDescriptor]
    ) -> MailMailboxResolution {
        let named = names(keys: keys, accounts: accounts)
        var resolved: [String] = []
        var matched: [MailMailboxName] = []
        var unmatched: [String] = []

        for argument in requested {
            let wanted = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { continue }
            let hits = named.filter { matches(wanted, $0, accounts: accounts) }
            if hits.isEmpty {
                unmatched.append(argument)
                continue
            }
            for hit in hits where !resolved.contains(hit.key) {
                resolved.append(hit.key)
                matched.append(hit)
            }
        }
        return MailMailboxResolution(keys: resolved, matched: matched, unmatched: unmatched)
    }

    private static func matches(
        _ wanted: String,
        _ name: MailMailboxName,
        accounts: [MailAccountDescriptor]
    ) -> Bool {
        let candidates = [
            name.key,
            name.displayPath,
            name.mailbox,
            name.accountID,
            name.accountName,
        ].compactMap { $0 }

        if candidates.contains(where: {
            $0.compare(wanted, options: .caseInsensitive) == .orderedSame
        }) {
            return true
        }

        // `oliver@example.com/INBOX` names the same mailbox as the display
        // name does, and is what a person reads off their own screen.
        guard let separator = wanted.firstIndex(of: "/") else {
            return accounts.contains { account in
                account.id.caseInsensitiveCompare(name.accountID) == .orderedSame
                    && account.emailAddresses.contains {
                        $0.caseInsensitiveCompare(wanted) == .orderedSame
                    }
            }
        }
        let prefix = String(wanted[wanted.startIndex ..< separator])
        let suffix = String(wanted[wanted.index(after: separator)...])
        guard suffix.caseInsensitiveCompare(name.mailbox) == .orderedSame else { return false }
        return accounts.contains { account in
            account.id.caseInsensitiveCompare(name.accountID) == .orderedSame
                && account.emailAddresses.contains {
                    $0.caseInsensitiveCompare(prefix) == .orderedSame
                }
        }
    }

    /// The sentence a tool says when a mailbox argument matched nothing.
    static func unmatchedExplanation(
        _ unmatched: [String],
        names: [MailMailboxName]
    ) -> String {
        let vocabulary = names.prefix(40).map { name -> String in
            name.displayPath == name.key ? name.key : "\(name.displayPath) (\(name.key))"
        }
        let more = names.count > 40 ? " …and \(names.count - 40) more." : ""
        let names = unmatched.map { "\"\($0)\"" }.joined(separator: ", ")
        return "NOT_FOUND: no indexed mailbox matches \(names). Indexed mailboxes are: "
            + vocabulary.joined(separator: "; ") + "." + more
    }
}
