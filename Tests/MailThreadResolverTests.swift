import Foundation
import Testing

/// `mail_get_thread` used to group by normalized subject inside one mailbox,
/// which both conflates unrelated messages sharing a subject and drops the
/// half of a conversation that lives in Sent. These fixtures pin both of those
/// as fixed, and pin the subject fallback as still reachable and still
/// labelled approximate.
@Suite("Mail thread resolver")
struct MailThreadResolverTests {
    private static func headers(
        messageId: String?,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> String {
        var lines = ["From: someone@example.com", "Subject: placeholder"]
        if let messageId { lines.append("Message-ID: <\(messageId)>") }
        if let inReplyTo { lines.append("In-Reply-To: <\(inReplyTo)>") }
        if !references.isEmpty {
            lines.append("References: " + references.map { "<\($0)>" }.joined(separator: " "))
        }
        lines.append("")
        lines.append("body text, not a header")
        return lines.joined(separator: "\r\n")
    }

    private static func candidate(
        id: Int,
        mailbox: String,
        subject: String,
        rawHeaders: String,
        account: String = "Fixture"
    ) -> MailThreadCandidate {
        MailThreadCandidate(
            id: id,
            mailbox: mailbox,
            accountName: account,
            subject: subject,
            rawHeaders: rawHeaders
        )
    }

    // MARK: - Header parsing

    @Test("A folded References header keeps every identifier")
    func foldedReferences() {
        let raw = [
            "Message-ID: <c@example.com>",
            "References: <a@example.com>",
            "\t<b@example.com>",
            " <b2@example.com>",
            "Subject: Folded",
        ].joined(separator: "\r\n")

        #expect(MailThreadResolver.messageIdentifier(inHeaders: raw) == "c@example.com")
        #expect(
            MailThreadResolver.referencedIdentifiers(inHeaders: raw) == [
                "a@example.com", "b@example.com", "b2@example.com",
            ]
        )
    }

    @Test("Header names match case insensitively and In-Reply-To joins References")
    func headerNameCasing() {
        let raw = [
            "message-id: <SELF@Example.COM>",
            "in-reply-to: <parent@example.com>",
            "REFERENCES: <root@example.com> <parent@example.com>",
        ].joined(separator: "\n")

        #expect(MailThreadResolver.messageIdentifier(inHeaders: raw) == "self@example.com")
        #expect(
            Set(MailThreadResolver.referencedIdentifiers(inHeaders: raw)) == [
                "parent@example.com", "root@example.com",
            ]
        )
    }

    @Test("Header parsing stops at the blank line, so the body cannot inject identifiers")
    func parsingStopsAtBody() {
        let raw = [
            "Message-ID: <real@example.com>",
            "",
            "References: <injected@example.com>",
        ].joined(separator: "\n")

        #expect(MailThreadResolver.referencedIdentifiers(inHeaders: raw).isEmpty)
    }

    @Test("Subject roots strip runs of reply and forward prefixes")
    func subjectRoots() {
        #expect(MailThreadResolver.subjectRoot("Re: Fwd: Re: Quarterly plan") == "Quarterly plan")
        #expect(MailThreadResolver.subjectRoot("RE[2]: Quarterly plan") == "Quarterly plan")
        #expect(MailThreadResolver.subjectRoot("Quarterly plan") == "Quarterly plan")
        #expect(MailThreadResolver.subjectRoot("Re: ") == "")
        // A colon that is not a reply prefix is left alone.
        #expect(MailThreadResolver.subjectRoot("Invoice: March") == "Invoice: March")
    }

    // MARK: - Acceptance: repeated subjects from different senders

    @Test("Unrelated messages sharing a subject are excluded")
    func repeatedSubjectsAreNotAThread() {
        let anchor = Self.candidate(
            id: 1,
            mailbox: "INBOX",
            subject: "Invoice",
            rawHeaders: Self.headers(messageId: "a1@alpha.example")
        )
        let reply = Self.candidate(
            id: 2,
            mailbox: "INBOX",
            subject: "Re: Invoice",
            rawHeaders: Self.headers(
                messageId: "a2@alpha.example",
                inReplyTo: "a1@alpha.example",
                references: ["a1@alpha.example"]
            )
        )
        // Same subject text, entirely unrelated conversation.
        let stranger = Self.candidate(
            id: 3,
            mailbox: "INBOX",
            subject: "Invoice",
            rawHeaders: Self.headers(messageId: "z9@beta.example")
        )
        let strangerReply = Self.candidate(
            id: 4,
            mailbox: "INBOX",
            subject: "Re: Invoice",
            rawHeaders: Self.headers(
                messageId: "z10@beta.example",
                inReplyTo: "z9@beta.example"
            )
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: 1,
            candidates: [anchor, reply, stranger, strangerReply]
        )

        #expect(resolution.matching == .headers)
        #expect(resolution.approximate == false)
        #expect(resolution.members.map(\.id) == [1, 2])
        #expect(resolution.subjectRoot == "Invoice")
    }

    // MARK: - Acceptance: a chain split across mailboxes

    @Test("A reply chain split across Inbox and Sent resolves as one thread")
    func chainCrossesMailboxes() {
        let received = Self.candidate(
            id: 10,
            mailbox: "INBOX",
            subject: "Quarterly plan",
            rawHeaders: Self.headers(messageId: "root@example.com")
        )
        let sentReply = Self.candidate(
            id: 11,
            mailbox: "Sent Messages",
            subject: "Re: Quarterly plan",
            rawHeaders: Self.headers(
                messageId: "mine@example.com",
                inReplyTo: "root@example.com",
                references: ["root@example.com"]
            )
        )
        let theirFollowUp = Self.candidate(
            id: 12,
            mailbox: "INBOX",
            subject: "Re: Quarterly plan",
            rawHeaders: Self.headers(
                messageId: "third@example.com",
                inReplyTo: "mine@example.com",
                references: ["root@example.com", "mine@example.com"]
            )
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: 10,
            candidates: [received, sentReply, theirFollowUp]
        )

        #expect(resolution.matching == .headers)
        #expect(resolution.members.map(\.id) == [10, 11, 12])
        #expect(Set(resolution.members.map(\.mailbox)) == ["INBOX", "Sent Messages"])
    }

    @Test("A chain links transitively even when the anchor never names the far end")
    func transitiveClosure() {
        // Anchoring on the last message: it references only its parent, and
        // the root is reachable only through that parent's own References.
        let root = Self.candidate(
            id: 20,
            mailbox: "Archive",
            subject: "Thread",
            rawHeaders: Self.headers(messageId: "r@example.com")
        )
        let middle = Self.candidate(
            id: 21,
            mailbox: "Sent Messages",
            subject: "Re: Thread",
            rawHeaders: Self.headers(
                messageId: "m@example.com",
                inReplyTo: "r@example.com",
                references: ["r@example.com"]
            )
        )
        let leaf = Self.candidate(
            id: 22,
            mailbox: "INBOX",
            subject: "Re: Thread",
            rawHeaders: Self.headers(messageId: "l@example.com", inReplyTo: "m@example.com")
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: 22,
            candidates: [root, middle, leaf]
        )

        #expect(resolution.members.map(\.id) == [20, 21, 22])
    }

    @Test("A lone message with headers is a thread of one, not a subject sweep")
    func loneMessageStaysAlone() {
        let anchor = Self.candidate(
            id: 30,
            mailbox: "INBOX",
            subject: "Lunch?",
            rawHeaders: Self.headers(messageId: "only@example.com")
        )
        let sameSubject = Self.candidate(
            id: 31,
            mailbox: "INBOX",
            subject: "Lunch?",
            rawHeaders: Self.headers(messageId: "other@example.com")
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: 30,
            candidates: [anchor, sameSubject]
        )

        #expect(resolution.matching == .headers)
        #expect(resolution.members.map(\.id) == [30])
    }

    // MARK: - Acceptance: disclosed subject fallback

    @Test("A headerless anchor falls back to subject and says so")
    func headerlessAnchorFallsBack() {
        let anchor = Self.candidate(
            id: 40,
            mailbox: "INBOX",
            subject: "Status",
            rawHeaders: "Subject: Status\r\nFrom: a@example.com"
        )
        let sameSubject = Self.candidate(
            id: 41,
            mailbox: "Sent Messages",
            subject: "Re: Status",
            rawHeaders: Self.headers(messageId: "s@example.com")
        )
        let otherSubject = Self.candidate(
            id: 42,
            mailbox: "INBOX",
            subject: "Unrelated",
            rawHeaders: Self.headers(messageId: "u@example.com")
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: 40,
            candidates: [anchor, sameSubject, otherSubject]
        )

        #expect(resolution.matching == .subject)
        #expect(resolution.approximate == true)
        #expect(resolution.note.hasPrefix("APPROXIMATE:"))
        #expect(resolution.members.map(\.id) == [40, 41])
    }

    @Test("The header path is never labelled approximate")
    func headerPathIsExact() {
        let anchor = Self.candidate(
            id: 50,
            mailbox: "INBOX",
            subject: "Exact",
            rawHeaders: Self.headers(messageId: "e@example.com")
        )
        let resolution = MailThreadResolver.resolve(anchorID: 50, candidates: [anchor])
        #expect(resolution.approximate == false)
        #expect(resolution.note == MailThreadResolver.headerNote)
    }

    @Test("An anchor missing from the candidate set yields an empty, disclosed result")
    func missingAnchor() {
        let resolution = MailThreadResolver.resolve(anchorID: 99, candidates: [])
        #expect(resolution.members.isEmpty)
        #expect(resolution.approximate == true)
    }
}
