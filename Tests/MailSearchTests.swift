import Foundation
import Testing

/// Drives the search contract over a synthetic mail store.
///
/// The corpus is the awkward one the issue asks for: messages years apart,
/// three sharing one subject and one timestamp, a message that moves between
/// mailboxes, one that is deleted, one whose body was never downloaded, and
/// one whose Date header does not parse at all. Two accounts, so cross-account
/// search is exercised rather than assumed.
///
/// The test that matters most is the last one in "Paging": a page boundary has
/// to survive a refresh that inserts a message above it and removes one below
/// it. That is the case offset paging gets wrong, and the reason this search
/// pages by cursor.
///
/// Nothing here reads or writes real mail. Both the store root and the index
/// file are per-test temporary directories, the same way MailIndexTests does it.
@Suite("Mail search")
struct MailSearchTests {
    // MARK: - Fixture

    typealias Corpus = MailIndexTests.Corpus

    /// One mailbox of six messages, newest first, one per day.
    static func dated(_ corpus: Corpus, mailbox: String = "INBOX") throws {
        let days = [
            ("601", "Alpha", "Mon, 1 Feb 2021 09:00:00 +0000"),
            ("602", "Bravo", "Tue, 2 Feb 2021 09:00:00 +0000"),
            ("603", "Charlie", "Wed, 3 Feb 2021 09:00:00 +0000"),
            ("604", "Delta", "Thu, 4 Feb 2021 09:00:00 +0000"),
            ("605", "Echo", "Fri, 5 Feb 2021 09:00:00 +0000"),
            ("606", "Foxtrot", "Sat, 6 Feb 2021 09:00:00 +0000"),
        ]
        for (id, subject, date) in days {
            try MailIndexTests.write(
                into: corpus,
                mailbox: mailbox,
                id: id,
                subject: subject,
                messageID: "\(subject.lowercased())@example.com",
                date: date,
                body: "Body of \(subject)"
            )
        }
    }

    static func subjects(_ hits: [MailSearchHit]) -> [String] { hits.map(\.subject) }

    static func request(
        _ corpus: Corpus,
        query: String? = nil,
        limit: Int = 20
    ) -> MailSearchRequest {
        var request = MailSearchRequest()
        request.query = query
        request.limit = limit
        request.fullTextAvailable = corpus.index.fullTextAvailable
        return request
    }

    // MARK: - Cursors

    @Test("A cursor round-trips through its token, dated and undated alike")
    func cursorRoundTrip() {
        let dated = MailSearchCursor(
            dateSent: Date(timeIntervalSince1970: 1_612_170_000.5),
            stableID: "ACCOUNT-A/INBOX/601"
        )
        #expect(MailSearchCursor.decode(dated.token) == dated)

        let undated = MailSearchCursor(dateSent: nil, stableID: "ACCOUNT-A/INBOX/999")
        #expect(MailSearchCursor.decode(undated.token) == undated)
        #expect(undated.token.contains(".-."))
    }

    @Test("A token this build did not write is refused, not treated as a fresh start")
    func cursorRejectsForeignTokens() {
        #expect(MailSearchCursor.decode("") == nil)
        #expect(MailSearchCursor.decode("50") == nil)
        #expect(MailSearchCursor.decode("mc1.notadate.QUJD") == nil)
        #expect(MailSearchCursor.decode("mc9.1.QUJD") == nil)
        #expect(MailSearchCursor.decode("mc1.1.") == nil)
    }

    @Test("The cursor predicate covers the undated tail, and pages never use OFFSET")
    func cursorPredicateShape() throws {
        var bindings: [MailSearchBinding] = []
        let datedClause = MailSearchQuery.cursorPredicate(
            MailSearchCursor(dateSent: Date(timeIntervalSince1970: 100), stableID: "a"),
            bindings: &bindings
        )
        // A dated cursor is followed by older rows, by ties with a larger id,
        // and then by every undated row.
        #expect(datedClause?.contains("m.date_sent IS NULL OR") == true)
        #expect(datedClause?.contains("m.stable_id > ?") == true)
        #expect(bindings == [.double(100), .double(100), .text("a")])

        bindings = []
        let tailClause = MailSearchQuery.cursorPredicate(
            MailSearchCursor(dateSent: nil, stableID: "a"),
            bindings: &bindings
        )
        #expect(tailClause == "(m.date_sent IS NULL AND m.stable_id > ?)")

        var request = MailSearchRequest()
        request.query = "invoice"
        let statement = try MailSearchQuery.page(request)
        #expect(!statement.sql.uppercased().contains("OFFSET"))
        #expect(statement.sql.contains("ORDER BY (m.date_sent IS NULL) ASC"))
    }

    // MARK: - Query text

    @Test("Query words are quoted for FTS5, with phrases and prefixes preserved")
    func queryTextBecomesAnFTSExpression() {
        #expect(
            MailSearchQuery.ftsExpression(query: "rent increase", scope: .all)
                == "\"rent\" AND \"increase\""
        )
        #expect(
            MailSearchQuery.ftsExpression(query: "\"rent increase\"", scope: .body)
                == "{body} : (\"rent increase\")"
        )
        #expect(
            MailSearchQuery.ftsExpression(query: "invoi*", scope: .subject)
                == "{subject} : (\"invoi\"*)"
        )
        // Punctuation a user types is data, never FTS5 syntax.
        #expect(
            MailSearchQuery.ftsExpression(query: "NEAR(a b) OR *", scope: .all)
                == "\"NEAR(a\" AND \"b)\" AND \"OR\" AND \"*\""
        )
        #expect(MailSearchQuery.ftsExpression(query: "   ", scope: .all) == nil)
    }

    @Test("Asking for bodies without FTS5 is refused rather than silently narrowed")
    func bodySearchWithoutFTSIsRefused() {
        var request = MailSearchRequest()
        request.query = "rent"
        request.scope = .body
        request.fullTextAvailable = false
        #expect(throws: MailSearchQueryError.bodySearchUnavailable) {
            _ = try MailSearchQuery.page(request)
        }

        // Header scopes still work, by substring.
        request.scope = .subject
        let statement = try? MailSearchQuery.page(request)
        #expect(statement?.sql.contains("m.subject LIKE ?") == true)
        #expect(statement?.sql.contains("messages_fts") == false)
    }

    @Test("A snippet shows the matched word in context")
    func snippetsShowTheMatch() {
        let body =
            String(repeating: "padding ", count: 40) + "the rent is due"
            + String(
                repeating: " trailing",
                count: 40
            )
        let snippet = MailSearchQuery.snippet(body: body, query: "rent")
        #expect(snippet?.contains("rent is due") == true)
        #expect(snippet?.hasPrefix("…") == true)
        #expect(MailSearchQuery.snippet(body: "   ", query: "rent") == nil)
    }

    // MARK: - Matching

    @Test("Body text is searchable across accounts and mailboxes at once")
    func bodySearchSpansTheWholeStore() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "701",
            subject: "Nothing useful",
            messageID: "a@example.com",
            body: "The lease renewal is attached."
        )
        try MailIndexTests.write(
            into: corpus,
            account: "ACCOUNT-B",
            mailbox: "Archive/2021",
            id: "702",
            subject: "Also nothing",
            messageID: "b@example.com",
            body: "Please countersign the lease before Friday."
        )
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "703",
            subject: "Unrelated",
            messageID: "c@example.com",
            body: "Lunch on Tuesday?"
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let hits = try corpus.index.search(Self.request(corpus, query: "lease")).hits
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.mailboxKey)) == ["ACCOUNT-A/INBOX", "ACCOUNT-B/Archive/2021"])
        // The match is shown, not just asserted.
        #expect(hits.allSatisfy { $0.snippet?.lowercased().contains("lease") == true })
    }

    @Test("Scope narrows the search to one field")
    func scopeNarrowsMatching() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "801",
            subject: "Quarterly badger report",
            messageID: "s@example.com",
            body: "Nothing to see."
        )
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "802",
            subject: "Unrelated",
            messageID: "b@example.com",
            body: "A badger was seen in the car park."
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        var subjectOnly = Self.request(corpus, query: "badger")
        subjectOnly.scope = .subject
        #expect(Self.subjects(try corpus.index.search(subjectOnly).hits) == ["Quarterly badger report"])

        var bodyOnly = Self.request(corpus, query: "badger")
        bodyOnly.scope = .body
        #expect(Self.subjects(try corpus.index.search(bodyOnly).hits) == ["Unrelated"])

        var senderOnly = Self.request(corpus, query: "sender@example.com")
        senderOnly.scope = .sender
        #expect(try corpus.index.search(senderOnly).hits.count == 2)
    }

    @Test("Date, mailbox, attachment and read-state filters each narrow the result")
    func filtersNarrowTheResult() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "901",
            subject: "Old invoice",
            messageID: "old@example.com",
            date: "Mon, 5 Jan 2004 08:00:00 +0000",
            body: "invoice",
            flags: 1
        )
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "902",
            subject: "Recent invoice",
            messageID: "recent@example.com",
            date: "Wed, 3 Feb 2021 09:00:00 +0000",
            body: "invoice",
            // Read, with one attachment: bit 0 set, attachment count at bit 10.
            flags: 1 | (1 << 10)
        )
        try MailIndexTests.write(
            into: corpus,
            mailbox: "Work/Clients",
            id: "903",
            subject: "Client invoice",
            messageID: "client@example.com",
            date: "Thu, 4 Feb 2021 09:00:00 +0000",
            body: "invoice",
            flags: 0
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        var since = Self.request(corpus, query: "invoice")
        since.since = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01
        #expect(try corpus.index.search(since).hits.count == 2)

        var until = Self.request(corpus, query: "invoice")
        until.until = Date(timeIntervalSince1970: 1_577_836_800)
        #expect(Self.subjects(try corpus.index.search(until).hits) == ["Old invoice"])

        var mailbox = Self.request(corpus, query: "invoice")
        mailbox.mailboxKeys = ["ACCOUNT-A/Work/Clients"]
        #expect(Self.subjects(try corpus.index.search(mailbox).hits) == ["Client invoice"])

        var attached = Self.request(corpus, query: "invoice")
        attached.hasAttachments = true
        #expect(Self.subjects(try corpus.index.search(attached).hits) == ["Recent invoice"])

        var unread = Self.request(corpus, query: "invoice")
        unread.isRead = false
        #expect(Self.subjects(try corpus.index.search(unread).hits) == ["Client invoice"])
    }

    @Test("A message with no parsable date is ordered last and counted when a date filter applies")
    func undatedMessagesAreOrderedAndCounted() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try Self.dated(corpus)
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "699",
            subject: "Undated",
            messageID: "undated@example.com",
            date: "whenever",
            body: "Body of Undated"
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let all = try corpus.index.search(Self.request(corpus, query: "Body")).hits
        #expect(all.count == 7)
        #expect(all.last?.subject == "Undated")
        #expect(all.last?.dateSent == nil)
        #expect(try corpus.index.search(Self.request(corpus, query: "Body")).undatedExcluded == nil)

        // A date filter cannot include it, so the count says so out loud.
        var bounded = Self.request(corpus, query: "Body")
        bounded.since = Date(timeIntervalSince1970: 0)
        let result = try corpus.index.search(bounded)
        #expect(result.hits.count == 6)
        #expect(result.undatedExcluded == 1)
    }

    @Test("A body that was never downloaded is reported, not silently missing")
    func partialDownloadsAreVisible() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "1001",
            subject: "Roof quote",
            messageID: "partial@example.com",
            body: "placeholder",
            partial: true
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        // The subject is indexed and findable.
        let bySubject = try corpus.index.search(Self.request(corpus, query: "roof")).hits
        #expect(bySubject.count == 1)
        #expect(bySubject[0].bodyComplete == false)
        #expect(bySubject[0].bodyUnavailableReason != nil)

        // And the incomplete ones can be listed on their own.
        var incomplete = Self.request(corpus)
        incomplete.bodyComplete = false
        #expect(Self.subjects(try corpus.index.search(incomplete).hits) == ["Roof quote"])
    }

    @Test("A move follows the message and a delete removes it from results")
    func movesAndDeletesAreReflected() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        let moving = try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "1101",
            subject: "Contract",
            messageID: "moving@example.com",
            body: "signature required"
        )
        let doomed = try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "1102",
            subject: "Spam",
            messageID: "doomed@example.com",
            body: "signature required"
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)
        #expect(try corpus.index.search(Self.request(corpus, query: "signature")).hits.count == 2)

        try FileManager.default.removeItem(at: moving)
        try MailIndexTests.write(
            into: corpus,
            mailbox: "Archive",
            id: "1101",
            subject: "Contract",
            messageID: "moving@example.com",
            body: "signature required"
        )
        try FileManager.default.removeItem(at: doomed)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let hits = try corpus.index.search(Self.request(corpus, query: "signature")).hits
        #expect(hits.count == 1)
        #expect(hits[0].mailboxKey == "ACCOUNT-A/Archive")
    }

    // MARK: - Paging

    @Test("Messages sharing a subject and a timestamp page without repeating or skipping")
    func repeatedSubjectsPageCleanly() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        for id in ["1201", "1202", "1203"] {
            try MailIndexTests.write(
                into: corpus,
                mailbox: "INBOX",
                id: id,
                subject: "Invoice",
                messageID: "\(id)@example.com",
                date: "Wed, 3 Feb 2021 09:00:00 +0000",
                body: "invoice attached"
            )
        }
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        var seen: [String] = []
        var cursor: MailSearchCursor?
        for _ in 0 ..< 3 {
            var request = Self.request(corpus, query: "invoice", limit: 1)
            request.cursor = cursor
            let page = try corpus.index.search(request)
            seen.append(contentsOf: page.hits.map(\.stableID))
            guard let token = page.nextCursor else { break }
            cursor = MailSearchCursor.decode(token)
        }
        #expect(seen.count == 3)
        #expect(Set(seen).count == 3)
    }

    @Test("A cursor stays correct across a refresh that inserts and removes rows mid-page")
    func cursorsSurviveAConcurrentRefresh() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try Self.dated(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let first = try corpus.index.search(Self.request(corpus, query: "Body", limit: 2))
        #expect(Self.subjects(first.hits) == ["Foxtrot", "Echo"])
        #expect(first.hasMore)
        let token = try #require(first.nextCursor)

        // Mail moves under the reader: a newer message arrives above the page
        // boundary and one already returned is deleted.
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "607",
            subject: "Golf",
            messageID: "golf@example.com",
            date: "Sun, 7 Feb 2021 09:00:00 +0000",
            body: "Body of Golf"
        )
        try FileManager.default.removeItem(
            at: corpus.root.appendingPathComponent(
                "V10/ACCOUNT-A/INBOX.mbox/8B1F-UUID/Data/3/Messages/605.emlx"
            )
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        var next = Self.request(corpus, query: "Body", limit: 2)
        next.cursor = MailSearchCursor.decode(token)
        let second = try corpus.index.search(next)
        // The boundary held: page two continues where page one stopped,
        // repeating nothing from it and skipping nothing after it.
        #expect(Self.subjects(second.hits) == ["Delta", "Charlie"])
    }

    @Test("Offset paging repeats a message when one arrives mid-walk; a cursor does not")
    func offsetPagingRepeatsWhatACursorDoesNot() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try Self.dated(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let first = try corpus.index.search(Self.request(corpus, query: "Body", limit: 2))
        #expect(Self.subjects(first.hits) == ["Foxtrot", "Echo"])
        let token = try #require(first.nextCursor)

        // One message arrives above the boundary, and every offset below it
        // now points one row later than it did.
        try MailIndexTests.write(
            into: corpus,
            mailbox: "INBOX",
            id: "607",
            subject: "Golf",
            messageID: "golf@example.com",
            date: "Sun, 7 Feb 2021 09:00:00 +0000",
            body: "Body of Golf"
        )
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        // Offset 2 now returns a message the caller has already been given.
        let byOffset = try corpus.index.messages(limit: 2, offset: 2)
        #expect(byOffset.map(\.subject) == ["Echo", "Delta"])

        // The cursor, holding a sort key rather than a count, does not.
        var next = Self.request(corpus, query: "Body", limit: 2)
        next.cursor = MailSearchCursor.decode(token)
        #expect(Self.subjects(try corpus.index.search(next).hits) == ["Delta", "Charlie"])
    }

    @Test("The last page reports no cursor")
    func lastPageEndsTheWalk() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try Self.dated(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        var request = Self.request(corpus, query: "Body", limit: 6)
        let page = try corpus.index.search(request)
        #expect(page.hits.count == 6)
        #expect(!page.hasMore)
        #expect(page.nextCursor == nil)

        request.limit = 5
        let short = try corpus.index.search(request)
        #expect(short.hasMore)
        #expect(short.nextCursor != nil)
    }

    // MARK: - Naming

    @Test("Index keys are given the account display names the other Mail tools take")
    func indexKeysGetDisplayNames() {
        let accounts = [
            MailAccountDescriptor(
                id: "B2369C0E-FCFF-4F0B-B2E2-43857204F37C",
                name: "iCloud",
                emailAddresses: ["oliver@example.com"]
            )
        ]
        let names = MailMailboxNaming.names(
            keys: [
                "B2369C0E-FCFF-4F0B-B2E2-43857204F37C/INBOX",
                "B2369C0E-FCFF-4F0B-B2E2-43857204F37C/Work/Clients",
                "1EEC6D21-7D42-4163-B3F4-99D396C5FBAE/INBOX",
                "OrphanedAccount - 83CE512E-74B1-42DB-A790-3028CACEC36C/INBOX",
            ],
            accounts: accounts
        )
        #expect(names[0].displayPath == "iCloud/INBOX")
        #expect(names[0].addressableByAppleEvents)
        #expect(names[1].mailbox == "Work/Clients")
        // An account directory no live account claims keeps its key and is
        // reported as unnamed rather than guessed at.
        #expect(names[2].accountName == nil)
        #expect(names[2].displayPath == names[2].key)
        #expect(!names[2].addressableByAppleEvents)
        #expect(names[3].orphaned)
    }

    @Test("A mailbox can be named by key, display path, account, email or bare path")
    func mailboxArgumentsResolveToKeys() {
        let keys = [
            "UUID-A/INBOX",
            "UUID-A/Work/Clients",
            "UUID-B/INBOX",
        ]
        let accounts = [
            MailAccountDescriptor(id: "UUID-A", name: "iCloud", emailAddresses: ["me@example.com"]),
            MailAccountDescriptor(id: "UUID-B", name: "Work", emailAddresses: ["me@work.example"]),
        ]
        func resolve(_ argument: String) -> [String] {
            MailMailboxNaming.resolve([argument], keys: keys, accounts: accounts).keys
        }
        #expect(resolve("UUID-A/INBOX") == ["UUID-A/INBOX"])
        #expect(resolve("iCloud/INBOX") == ["UUID-A/INBOX"])
        #expect(resolve("icloud/work/clients") == ["UUID-A/Work/Clients"])
        #expect(resolve("me@example.com/INBOX") == ["UUID-A/INBOX"])
        // An account name on its own means all of its mailboxes.
        #expect(resolve("iCloud") == ["UUID-A/INBOX", "UUID-A/Work/Clients"])
        // A bare mailbox path means that mailbox in every account, which is
        // what a person means by "search my inboxes".
        #expect(resolve("INBOX") == ["UUID-A/INBOX", "UUID-B/INBOX"])
    }

    @Test("A mailbox name that matches nothing is refused with the real vocabulary")
    func unmatchedMailboxesAreRefused() {
        let keys = ["UUID-A/INBOX"]
        let accounts = [MailAccountDescriptor(id: "UUID-A", name: "iCloud")]
        let resolution = MailMailboxNaming.resolve(
            ["iCloud/INBOX", "Gmail/INBOX"],
            keys: keys,
            accounts: accounts
        )
        #expect(resolution.keys == ["UUID-A/INBOX"])
        #expect(resolution.unmatched == ["Gmail/INBOX"])

        let explanation = MailMailboxNaming.unmatchedExplanation(
            resolution.unmatched,
            names: MailMailboxNaming.names(keys: keys, accounts: accounts)
        )
        #expect(explanation.hasPrefix("NOT_FOUND:"))
        #expect(explanation.contains("iCloud/INBOX"))
    }
}
