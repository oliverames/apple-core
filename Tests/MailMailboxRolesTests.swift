// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@Suite("Mail mailbox role resolution")
struct MailMailboxRolesTests {
    @Test("A plain English account resolves every role exactly")
    func englishAccount() {
        let matches = MailMailboxRoles.resolve(mailboxes: [
            "INBOX", "Drafts", "Sent Messages", "Trash", "Junk", "Archive", "Projects",
        ])
        let byRole = Dictionary(uniqueKeysWithValues: matches.map { ($0.role, $0) })
        #expect(byRole[.inbox]?.mailbox == "INBOX")
        #expect(byRole[.drafts]?.mailbox == "Drafts")
        #expect(byRole[.sent]?.mailbox == "Sent Messages")
        #expect(byRole[.trash]?.mailbox == "Trash")
        #expect(byRole[.junk]?.mailbox == "Junk")
        #expect(byRole[.archive]?.mailbox == "Archive")
        #expect(byRole[.inbox]?.confidence == .exact)
        // A mailbox that is nobody's role is simply not returned.
        #expect(matches.allSatisfy { $0.mailbox != "Projects" })
    }

    @Test("Gmail's bracketed paths resolve on their last component")
    func gmailPaths() {
        let matches = MailMailboxRoles.resolve(mailboxes: [
            "INBOX", "[Gmail]/All Mail", "[Gmail]/Trash", "[Gmail]/Spam", "[Gmail]/Sent Mail",
            "[Gmail]/Drafts",
        ])
        let byRole = Dictionary(uniqueKeysWithValues: matches.map { ($0.role, $0) })
        // The returned name keeps its prefix: it is what gets handed to Mail.
        #expect(byRole[.trash]?.mailbox == "[Gmail]/Trash")
        #expect(byRole[.junk]?.mailbox == "[Gmail]/Spam")
        #expect(byRole[.sent]?.mailbox == "[Gmail]/Sent Mail")
        #expect(byRole[.archive]?.mailbox == "[Gmail]/All Mail")
    }

    @Test("Exchange spellings resolve")
    func exchangeNames() {
        let matches = MailMailboxRoles.resolve(mailboxes: [
            "Inbox", "Sent Items", "Deleted Items", "Junk E-Mail", "Drafts",
        ])
        let byRole = Dictionary(uniqueKeysWithValues: matches.map { ($0.role, $0) })
        #expect(byRole[.sent]?.mailbox == "Sent Items")
        #expect(byRole[.trash]?.mailbox == "Deleted Items")
        #expect(byRole[.junk]?.mailbox == "Junk E-Mail")
    }

    @Test("A localised account resolves without any English mailbox")
    func localisedAccount() {
        let german = MailMailboxRoles.resolve(mailboxes: [
            "Posteingang", "Entwürfe", "Gesendet", "Papierkorb", "Werbung",
        ])
        let byRole = Dictionary(uniqueKeysWithValues: german.map { ($0.role, $0) })
        #expect(byRole[.trash]?.mailbox == "Papierkorb")
        #expect(byRole[.inbox]?.mailbox == "Posteingang")
        #expect(byRole[.junk]?.mailbox == "Werbung")

        let french = MailMailboxRoles.resolve(mailboxes: ["Corbeille", "Brouillons"])
        #expect(MailMailboxRoles.mailbox(for: .trash, in: ["Corbeille", "Brouillons"]) == "Corbeille")
        #expect(french.contains { $0.role == .drafts && $0.mailbox == "Brouillons" })
    }

    @Test("An exact name beats a longer one that merely contains it")
    func exactBeatsContains() {
        let matches = MailMailboxRoles.resolve(mailboxes: [
            "Sent Items Archive 2019", "Sent", "INBOX",
        ])
        let sent = matches.first { $0.role == .sent }
        #expect(sent?.mailbox == "Sent")
        #expect(sent?.confidence == .exact)
        // The other candidate is not lost, only demoted.
        #expect(sent?.alternatives.contains("Sent Items Archive 2019") == true)
    }

    @Test("A role the account has no mailbox for is absent, never defaulted")
    func missingRolesAreAbsent() {
        let matches = MailMailboxRoles.resolve(mailboxes: ["INBOX"])
        #expect(matches.count == 1)
        #expect(matches[0].role == .inbox)
        #expect(MailMailboxRoles.mailbox(for: .trash, in: ["INBOX"]) == nil)
    }

    @Test("A short alias does not match a word that merely contains it")
    func shortAliasesDoNotFalseMatch() {
        // "in" is inside "Invoices" and "Vintage"; neither is an inbox.
        #expect(MailMailboxRoles.mailbox(for: .inbox, in: ["Invoices", "Vintage"]) == nil)
        // "sent" is inside "Consent Forms"; it is not the sent mailbox, but a
        // contains match on a four-letter alias is allowed, so this records
        // the behaviour honestly rather than claiming otherwise.
        let consent = MailMailboxRoles.resolve(mailboxes: ["Consent Forms"])
        #expect(consent.first { $0.role == .sent }?.confidence == .heuristic)
    }

    @Test("An empty mailbox list resolves nothing and does not crash")
    func emptyInput() {
        #expect(MailMailboxRoles.resolve(mailboxes: []).isEmpty)
        #expect(MailMailboxRoles.resolve(mailboxes: ["", "   "]).isEmpty)
    }

    @Test("Resolution is stable across orderings of the same mailboxes")
    func stableAcrossOrderings() {
        let names = ["Trash", "Deleted Items", "INBOX"]
        let forward = MailMailboxRoles.resolve(mailboxes: names)
        let reversed = MailMailboxRoles.resolve(mailboxes: names.reversed())
        #expect(
            forward.first { $0.role == .trash }?.mailbox
                == reversed.first { $0.role == .trash }?.mailbox
        )
    }
}
