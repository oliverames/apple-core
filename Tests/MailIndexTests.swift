import Foundation
import Testing

/// Builds a synthetic Mail store on disk and drives the index over it.
///
/// The corpus is deliberately awkward: messages years apart, three messages
/// sharing one subject, a message that moves between mailboxes, one that is
/// deleted, one that is only partially downloaded and later completes, and a
/// file that is not a readable message at all. Those are the states that
/// separate an index which is merely fast from one that can be believed.
///
/// Nothing here touches ~/Library/Mail or ~/.config/apple-core. Both the
/// store root and the index file are temporary directories created per test.
@Suite("Mail index")
struct MailIndexTests {
    // MARK: - Fixture

    struct Corpus {
        let root: URL
        let index: MailIndexStore
        var store: MailLocalStore { MailLocalStore(root: root) }
    }

    static func makeCorpus() throws -> Corpus {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-mail-index-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Corpus(
            root: root,
            index: MailIndexStore(fileURL: base.appendingPathComponent("mail-index.sqlite"))
        )
    }

    static func remove(_ corpus: Corpus) {
        try? FileManager.default.removeItem(at: corpus.root.deletingLastPathComponent())
    }

    /// Writes one `.emlx` into `account/mailbox`, mirroring Mail's own
    /// `<Mailbox>.mbox/<UUID>/Data/<n>/Messages/<id>.emlx` layout.
    @discardableResult
    static func write(
        into corpus: Corpus,
        account: String = "ACCOUNT-A",
        mailbox: String,
        id: String,
        subject: String,
        messageID: String,
        date: String = "Tue, 3 Feb 2009 09:15:00 +0000",
        body: String = "Body",
        partial: Bool = false,
        flags: Int? = 1
    ) throws -> URL {
        let mailboxDirectory = mailbox.split(separator: "/")
            .reduce(corpus.root.appendingPathComponent("V10/\(account)", isDirectory: true)) {
                $0.appendingPathComponent("\($1).mbox", isDirectory: true)
            }
            .appendingPathComponent("8B1F-UUID/Data/3/Messages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mailboxDirectory,
            withIntermediateDirectories: true
        )
        let url = mailboxDirectory.appendingPathComponent(
            partial ? "\(id).partial.emlx" : "\(id).emlx"
        )
        let message = """
            Subject: \(subject)
            From: Sender <sender@example.com>
            To: Oliver <oliver@example.com>
            Date: \(date)
            Message-ID: <\(messageID)>
            Content-Type: text/plain; charset=utf-8

            \(body)
            """
        try MailEmlxDocumentTests.emlx(message: message, flags: flags).write(to: url)
        return url
    }

    /// The corpus every reconciliation test starts from.
    static func seed(_ corpus: Corpus) throws {
        try write(
            into: corpus,
            mailbox: "INBOX",
            id: "101",
            subject: "Invoice",
            messageID: "old@example.com",
            date: "Mon, 5 Jan 2004 08:00:00 +0000"
        )
        try write(
            into: corpus,
            mailbox: "INBOX",
            id: "102",
            subject: "Invoice",
            messageID: "repeat-one@example.com"
        )
        try write(
            into: corpus,
            mailbox: "INBOX",
            id: "103",
            subject: "Invoice",
            messageID: "repeat-two@example.com"
        )
        try write(
            into: corpus,
            mailbox: "Work/Clients",
            id: "201",
            subject: "Contract",
            messageID: "nested@example.com"
        )
        try write(
            into: corpus,
            account: "ACCOUNT-B",
            mailbox: "INBOX",
            id: "301",
            subject: "Second account",
            messageID: "other-account@example.com"
        )
    }

    // MARK: - Building

    @Test("A first pass indexes every message file, including nested mailboxes")
    func firstPassCoversTheStore() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)

        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index)

        #expect(report.scannedFiles == 5)
        #expect(report.inserted == 5)
        #expect(report.removed == 0)
        #expect(report.scanComplete)
        #expect(report.status.usable)
        #expect(report.status.messageCount == 5)
        #expect(report.status.accountCount == 2)
        #expect(report.status.completeness.hasPrefix("CURRENT"))
        // Nesting is preserved rather than flattened to the leaf name.
        #expect(try corpus.index.mailboxKeys().contains("ACCOUNT-A/Work/Clients"))
    }

    @Test("Repeated subjects stay distinct messages, and old dates survive")
    func repeatedSubjectsAndOldDates() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let invoices = try corpus.index.messages(inMailbox: "INBOX", limit: 50)
            .filter { $0.subject == "Invoice" }
        #expect(invoices.count == 3)
        #expect(Set(invoices.compactMap(\.messageID)).count == 3)
        // Newest first, so the 2004 message sorts last.
        #expect(invoices.last?.messageID == "old@example.com")
        #expect(
            invoices.last?.dateSent == Date(timeIntervalSince1970: 1_073_289_600)
        )
    }

    @Test("A second pass with nothing changed rewrites nothing")
    func secondPassIsIdempotent() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let second = try MailIndex.refresh(store: corpus.store, index: corpus.index)
        #expect(second.inserted == 0)
        #expect(second.updated == 0)
        #expect(second.removed == 0)
        #expect(second.unchanged == 5)
        #expect(second.status.messageCount == 5)
    }

    // MARK: - Reconciliation

    @Test("A moved message appears once, in its new mailbox, and is reported as moved")
    func moveIsNeitherDuplicatedNorLost() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        // Mail moves a message by writing it under the destination mailbox
        // and removing the original file. Its id changes; its Message-ID
        // does not, which is the only thread tying the two together.
        let original = corpus.root.appendingPathComponent(
            "V10/ACCOUNT-A/INBOX.mbox/8B1F-UUID/Data/3/Messages/102.emlx"
        )
        try FileManager.default.removeItem(at: original)
        try Self.write(
            into: corpus,
            mailbox: "Archive",
            id: "402",
            subject: "Invoice",
            messageID: "repeat-one@example.com"
        )

        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index)

        #expect(report.moved.count == 1)
        #expect(report.moved.first?.messageID == "repeat-one@example.com")
        #expect(report.moved.first?.fromMailbox == "ACCOUNT-A/INBOX")
        #expect(report.moved.first?.toMailbox == "ACCOUNT-A/Archive")
        // Once, not twice, and not nowhere.
        #expect(report.status.messageCount == 5)
        let everywhere = try corpus.index.messages(limit: 100)
            .filter { $0.messageID == "repeat-one@example.com" }
        #expect(everywhere.count == 1)
        #expect(everywhere.first?.mailbox == "Archive")
        #expect(report.status.duplicateMessageCount == 0)
    }

    @Test("A deleted message leaves the index")
    func deleteRemovesTheRow() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        try FileManager.default.removeItem(
            at: corpus.root.appendingPathComponent(
                "V10/ACCOUNT-A/INBOX.mbox/8B1F-UUID/Data/3/Messages/103.emlx"
            )
        )
        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index)

        #expect(report.removed == 1)
        #expect(report.moved.isEmpty)
        #expect(report.status.messageCount == 4)
        #expect(
            try corpus.index.messages(limit: 100)
                .allSatisfy { $0.messageID != "repeat-two@example.com" }
        )
    }

    @Test("A partial message is indexed as incomplete, then reported as downloaded")
    func partialDownloadThenCompletion() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        let partial = try Self.write(
            into: corpus,
            mailbox: "INBOX",
            id: "501",
            subject: "Large attachment",
            messageID: "partial@example.com",
            body: "First lines only",
            partial: true
        )

        let first = try MailIndex.refresh(store: corpus.store, index: corpus.index)
        #expect(first.status.incompleteBodyCount == 1)
        #expect(
            first.status.warnings.contains { $0.contains("not fully readable") }
        )
        let indexed = try corpus.index.messages(limit: 100)
            .first { $0.messageID == "partial@example.com" }
        #expect(indexed?.isPartial == true)
        #expect(indexed?.bodyComplete == false)
        #expect(indexed?.bodyUnavailableReason?.isEmpty == false)

        // Mail finishes the download: the .partial.emlx is replaced by a
        // complete file under the same message identifier.
        try FileManager.default.removeItem(at: partial)
        try Self.write(
            into: corpus,
            mailbox: "INBOX",
            id: "501",
            subject: "Large attachment",
            messageID: "partial@example.com",
            body: "First lines only, and the rest"
        )
        let second = try MailIndex.refresh(store: corpus.store, index: corpus.index)

        #expect(second.downloaded.count == 1)
        #expect(second.downloaded.first?.messageID == "partial@example.com")
        #expect(second.moved.isEmpty)
        #expect(second.status.incompleteBodyCount == 0)
        #expect(second.status.messageCount == 6)
    }

    @Test("The same message in two mailboxes is reported, not silently merged")
    func duplicatesAreDisclosed() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        try Self.write(
            into: corpus,
            mailbox: "Archive",
            id: "601",
            subject: "Invoice",
            messageID: "repeat-one@example.com"
        )

        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index)
        #expect(report.status.duplicateMessageCount == 1)
        #expect(report.status.warnings.contains { $0.contains("more than one mailbox") })
        #expect(
            try corpus.index.messages(limit: 100)
                .filter { $0.messageID == "repeat-one@example.com" }
                .count == 2
        )
    }

    @Test("A file that is not a readable message is counted, not skipped in silence")
    func unreadableFilesAreCounted() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        let directory = corpus.root.appendingPathComponent(
            "V10/ACCOUNT-A/INBOX.mbox/8B1F-UUID/Data/3/Messages",
            isDirectory: true
        )
        try Data().write(to: directory.appendingPathComponent("999.emlx"))

        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index)
        #expect(report.unreadable.count == 1)
        #expect(report.status.unreadableFileCount == 1)
        #expect(report.status.unreadableExamples.first?.path.hasSuffix("999.emlx") == true)
        #expect(report.status.warnings.contains { $0.contains("could not be read") })
        // The broken file is absent from the index, and the count says so.
        #expect(report.status.messageCount == 5)
    }

    // MARK: - Honesty

    @Test("A stopped scan is reported as incomplete rather than as a finished pass")
    func truncatedScanIsNotACompletePass() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)

        let report = try MailIndex.refresh(
            store: corpus.store,
            index: corpus.index,
            fileLimit: 2
        )
        #expect(!report.scanComplete)
        #expect(report.status.lastCompleteRefresh == nil)
        #expect(!report.status.usable)
        #expect(report.status.completeness.hasPrefix("EMPTY"))
    }

    @Test("An index older than its freshness window reports itself stale")
    func stalenessIsReported() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)
        let indexedAt = Date()
        try MailIndex.refresh(store: corpus.store, index: corpus.index, now: indexedAt)

        let later = indexedAt.addingTimeInterval(MailIndex.freshnessWindow + 60)
        let status = MailIndex.status(store: corpus.store, index: corpus.index, now: later)

        #expect(status.stale)
        #expect(!status.usable)
        #expect(status.completeness.hasPrefix("STALE"))
        #expect(status.warnings.contains { $0.contains("freshness window") })
        // The messages are still there. Staleness is about what is missing,
        // not about what was indexed.
        #expect(status.messageCount == 5)
    }

    @Test("A store that cannot be enumerated reads as denied access, not as empty")
    func missingDiskAccessIsNamed() throws {
        let corpus = try Self.makeCorpus()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: corpus.root.path
            )
            Self.remove(corpus)
        }
        try Self.seed(corpus)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: corpus.root.path
        )

        let status = MailIndex.status(store: corpus.store, index: corpus.index)
        #expect(status.access == "no_disk_access")
        #expect(status.accessDetail.contains("Full Disk Access"))
        #expect(!status.usable)
        #expect(status.completeness.contains("NO_DISK_ACCESS"))

        // And a refresh refuses rather than writing an empty index that would
        // then be reported as a complete picture of an empty mailbox.
        #expect(throws: MailIndexError.self) {
            try MailIndex.refresh(store: corpus.store, index: corpus.index)
        }
    }

    @Test("A Mac with no local mail is distinguished from one that refused to show it")
    func noLocalMailIsItsOwnState() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        let absent = MailLocalStore(
            root: corpus.root.appendingPathComponent("not-here", isDirectory: true)
        )
        let status = MailIndex.status(store: absent, index: corpus.index)
        #expect(status.access == "no_local_mail")
        #expect(status.completeness.contains("NO_LOCAL_MAIL"))
    }

    @Test("Asking about an index on a locked-out Mac creates no index file")
    func statusDoesNotCreateTheIndexFile() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        let absent = MailLocalStore(
            root: corpus.root.appendingPathComponent("not-here", isDirectory: true)
        )
        _ = MailIndex.status(store: absent, index: corpus.index)
        #expect(!FileManager.default.fileExists(atPath: corpus.index.fileURL.path))
    }

    @Test("The index is Apple Core's own file under the config home, never Mail's")
    func indexLivesInTheConfigHome() {
        let path = MailIndexStore.default.fileURL.path
        #expect(path.hasSuffix("/mail-index.sqlite"))
        if let override = ProcessInfo.processInfo.environment["APPLECORE_CONFIG_HOME"],
            !override.isEmpty
        {
            #expect(path.hasPrefix((override as NSString).expandingTildeInPath))
        } else {
            #expect(path.contains("/.config/apple-core/"))
        }
        #expect(!path.contains("/Library/Mail"))
    }

    @Test("Refreshing never writes to Mail's own storage")
    func mailStorageIsLeftAlone() throws {
        let corpus = try Self.makeCorpus()
        defer { Self.remove(corpus) }
        try Self.seed(corpus)

        func fingerprint() throws -> [String: Date] {
            var found: [String: Date] = [:]
            let enumerator = FileManager.default.enumerator(
                at: corpus.root,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            while case let url as URL = enumerator?.nextObject() {
                found[url.path] =
                    (try url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .contentModificationDate
            }
            return found
        }

        let before = try fingerprint()
        try MailIndex.refresh(store: corpus.store, index: corpus.index)
        let after = try fingerprint()

        #expect(before == after)
        #expect(!FileManager.default.fileExists(atPath: corpus.root.path + "/mail-index.sqlite"))
    }

    // MARK: - Reconciler, without a store

    @Test("Planning classifies inserts, updates, removals and moves together")
    func planClassifiesEveryChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = [
            MailIndexEntry(
                stableID: "A/INBOX/1",
                accountID: "A",
                mailbox: "INBOX",
                messageID: "moved@example.com",
                sizeBytes: 10,
                modified: now,
                isPartial: false
            ),
            MailIndexEntry(
                stableID: "A/INBOX/2",
                accountID: "A",
                mailbox: "INBOX",
                messageID: "gone@example.com",
                sizeBytes: 10,
                modified: now,
                isPartial: false
            ),
            MailIndexEntry(
                stableID: "A/INBOX/3",
                accountID: "A",
                mailbox: "INBOX",
                messageID: "same@example.com",
                sizeBytes: 10,
                modified: now,
                isPartial: false
            ),
        ]
        func file(
            _ mailbox: String,
            _ id: String,
            size: Int = 10,
            modified: Date = now
        ) -> MailScannedMessageFile {
            MailScannedMessageFile(
                stableID: "A/\(mailbox)/\(id)",
                accountID: "A",
                mailbox: mailbox,
                emlxID: id,
                path: "/tmp/\(id).emlx",
                sizeBytes: size,
                modified: modified,
                isPartial: false
            )
        }
        let plan = MailIndexReconciler.plan(
            existing: existing,
            scanned: [
                file("Archive", "9"),
                file("INBOX", "3", size: 20),
                file("INBOX", "4"),
            ],
            messageIDs: [
                "A/Archive/9": "moved@example.com",
                "A/INBOX/4": "new@example.com",
            ]
        )

        #expect(plan.inserted.map(\.stableID).sorted() == ["A/Archive/9", "A/INBOX/4"])
        #expect(plan.updated.map(\.stableID) == ["A/INBOX/3"])
        #expect(plan.unchangedIDs.isEmpty)
        #expect(plan.removedIDs.sorted() == ["A/INBOX/1", "A/INBOX/2"])
        #expect(plan.carried.count == 1)
        #expect(plan.carried.first?.kind == .moved)
        #expect(plan.carried.first?.fromStableID == "A/INBOX/1")
        #expect(plan.carried.first?.toStableID == "A/Archive/9")
    }

    @Test("Two copies of one message cannot both be claimed by the same move")
    func oneMoveClaimsOneDestination() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = [
            MailIndexEntry(
                stableID: "A/INBOX/1",
                accountID: "A",
                mailbox: "INBOX",
                messageID: "twin@example.com",
                sizeBytes: 10,
                modified: now,
                isPartial: false
            )
        ]
        let scanned = ["Archive", "Later"].map { mailbox in
            MailScannedMessageFile(
                stableID: "A/\(mailbox)/9",
                accountID: "A",
                mailbox: mailbox,
                emlxID: "9",
                path: "/tmp/\(mailbox).emlx",
                sizeBytes: 10,
                modified: now,
                isPartial: false
            )
        }
        let plan = MailIndexReconciler.plan(
            existing: existing,
            scanned: scanned,
            messageIDs: [
                "A/Archive/9": "twin@example.com",
                "A/Later/9": "twin@example.com",
            ]
        )
        #expect(plan.inserted.count == 2)
        #expect(plan.carried.count == 1)
        #expect(MailIndexReconciler.duplicateMessageIDs(in: existing).isEmpty)
    }
}
