import Foundation
import Testing

/// The concurrency contract around a mail index pass.
///
/// A pass over a real store is minutes of work, so these tests are about the
/// things that only go wrong once the pass outlives the call that asked for
/// it: two callers racing to start one, a status read that has to succeed
/// while the index is being written, and progress that has to move.
///
/// Everything here runs against a temporary store and a temporary index, on
/// its own coordinator. Nothing touches ~/Library/Mail, ~/.config/apple-core
/// or the shared coordinator the tools use.
@Suite("Mail index passes")
struct MailIndexJobTests {
    /// A counter several threads may touch, for proving a closure ran once.
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Progress updates arrive from the pass's own thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MailIndexProgress] = []

        func add(_ progress: MailIndexProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [MailIndexProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A store with enough messages that a pass takes long enough to watch.
    private static func makeBusyCorpus(messages: Int) throws -> MailIndexTests.Corpus {
        let corpus = try MailIndexTests.makeCorpus()
        let body = String(repeating: "Paragraph of message text. ", count: 120)
        for number in 0 ..< messages {
            try MailIndexTests.write(
                into: corpus,
                mailbox: number % 2 == 0 ? "INBOX" : "Work/Clients",
                id: "\(1000 + number)",
                subject: "Message \(number)",
                messageID: "busy-\(number)@example.com",
                body: body
            )
        }
        return corpus
    }

    private static func runningSnapshot(elapsed: Double = 12) -> MailIndexJobSnapshot {
        MailIndexJobSnapshot(
            state: "running",
            jobID: "pass-testjob",
            startedAt: MailIndexJobCoordinator.timestamp(Date()),
            finishedAt: nil,
            elapsedSeconds: elapsed,
            fileLimit: 200_000,
            progress: MailIndexProgress(
                phase: .reading,
                filesSeen: 4000,
                filesParsed: 1200,
                filesToParse: 4000,
                writesApplied: 0,
                writesPlanned: nil,
                detail: "Read 1200 of 4000 new or changed file(s)."
            ),
            failure: nil,
            report: nil
        )
    }

    // MARK: - One pass at a time

    @Test("A second refresh joins the running pass rather than starting another")
    func secondRefreshJoins() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.seed(corpus)

        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.join")
        let gate = DispatchSemaphore(value: 0)
        let runs = Runs()

        let first = coordinator.start(fileLimit: 200_000) { progress in
            runs.increment()
            gate.wait()
            return try MailIndex.refresh(
                store: corpus.store,
                index: corpus.index,
                progress: progress
            )
        }
        #expect(first.started)
        #expect(first.snapshot.isRunning)

        let second = coordinator.start(fileLimit: 200_000) { progress in
            runs.increment()
            return try MailIndex.refresh(
                store: corpus.store,
                index: corpus.index,
                progress: progress
            )
        }
        // Joined, not started: same job, and the second closure never ran.
        #expect(second.started == false)
        #expect(second.snapshot.jobID == first.snapshot.jobID)
        #expect(second.snapshot.isRunning)

        gate.signal()
        let finished = coordinator.wait(upTo: 30)
        #expect(finished?.state == "succeeded")
        #expect(finished?.jobID == first.snapshot.jobID)
        #expect(runs.value == 1)
        #expect(finished?.report?.scannedFiles == 5)

        // A pass after the first finishes is a new job, not a rejection.
        let third = coordinator.start(fileLimit: 200_000) { progress in
            try MailIndex.refresh(store: corpus.store, index: corpus.index, progress: progress)
        }
        #expect(third.started)
        #expect(third.snapshot.jobID != first.snapshot.jobID)
        #expect(coordinator.wait(upTo: 30)?.state == "succeeded")
    }

    @Test("A caller waiting less than the pass takes gets the running pass, not a timeout")
    func waitReturnsTheRunningPass() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.seed(corpus)

        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.wait")
        let gate = DispatchSemaphore(value: 0)
        coordinator.start(fileLimit: 200_000) { progress in
            gate.wait()
            return try MailIndex.refresh(
                store: corpus.store,
                index: corpus.index,
                progress: progress
            )
        }

        let started = Date()
        let waited = coordinator.wait(upTo: 0.4)
        let elapsed = Date().timeIntervalSince(started)
        #expect(waited?.isRunning == true)
        #expect(waited?.failure == nil)
        #expect(elapsed >= 0.3)
        #expect(elapsed < 5)

        gate.signal()
        #expect(coordinator.wait(upTo: 30)?.state == "succeeded")
    }

    @Test("A pass that throws is reported as failed, not as a finished index")
    func failedPassIsReported() throws {
        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.fail")
        coordinator.start(fileLimit: 10) { _ in
            throw MailIndexError.unavailable("NO_DISK_ACCESS: made up for the test.")
        }
        let finished = coordinator.wait(upTo: 10)
        #expect(finished?.state == "failed")
        #expect(finished?.report == nil)
        #expect(finished?.failure?.contains("NO_DISK_ACCESS") == true)
    }

    // MARK: - Readable while it runs

    @Test("Status stays readable while a pass writes the index, and progress advances")
    func statusReadableDuringAPass() throws {
        let corpus = try Self.makeBusyCorpus(messages: 800)
        defer { MailIndexTests.remove(corpus) }

        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.live")
        coordinator.start(fileLimit: 200_000) { progress in
            try MailIndex.refresh(store: corpus.store, index: corpus.index, progress: progress)
        }

        var sawRunningStatus = false
        var sawPhaseBeyondScanning = false
        var highestFilesSeen = 0
        var slowestStatus: TimeInterval = 0
        var polls = 0
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            let active = coordinator.activeSnapshot()
            let before = Date()
            let status = MailIndex.status(
                store: corpus.store,
                index: corpus.index,
                activePass: active
            )
            slowestStatus = max(slowestStatus, Date().timeIntervalSince(before))
            polls += 1

            if let activity = status.activeRefresh {
                sawRunningStatus = true
                highestFilesSeen = max(highestFilesSeen, activity.filesSeen)
                if activity.phase != MailIndexPhase.scanning.rawValue {
                    sawPhaseBeyondScanning = true
                }
                // While no pass has completed, the index is building and
                // says so in the same words the paragraph uses. The last
                // poll of a run can catch the moment after the pass wrote
                // its completeness stamp and before the job was recorded as
                // finished; that reads as refreshing, which is also true.
                if status.lastCompleteRefresh == nil {
                    #expect(status.indexState == "building")
                    #expect(status.completeness.hasPrefix("BUILDING:"))
                    #expect(status.usable == false)
                } else {
                    #expect(status.indexState == "refreshing")
                }
                #expect(status.completeness.contains(activity.jobID))
            }
            guard coordinator.activeSnapshot() != nil else { break }
        }

        let finished = coordinator.wait(upTo: 60)
        #expect(finished?.failure == nil)
        #expect(finished?.state == "succeeded")
        #expect(finished?.report?.scannedFiles == 800)

        // The point of the whole exercise: the index was readable throughout,
        // every read answered rather than blocking on the write lock, and the
        // pass was visibly moving while it ran.
        #expect(polls > 1)
        #expect(sawRunningStatus)
        #expect(sawPhaseBeyondScanning)
        #expect(highestFilesSeen > 0)
        #expect(slowestStatus < 5)

        // And once it is over, the status describes a finished index with no
        // pass attached.
        let after = MailIndex.status(store: corpus.store, index: corpus.index, activePass: nil)
        #expect(after.activeRefresh == nil)
        #expect(after.indexState == "current")
        #expect(after.messageCount == 800)
        #expect(after.usable)
    }

    @Test("A refresh reports progress through every phase of the pass")
    func progressCoversEveryPhase() throws {
        let corpus = try Self.makeBusyCorpus(messages: 120)
        defer { MailIndexTests.remove(corpus) }

        let collected = Collected()
        let report = try MailIndex.refresh(store: corpus.store, index: corpus.index) { progress in
            collected.add(progress)
        }
        let updates = collected.values

        #expect(report.scannedFiles == 120)
        #expect(updates.count >= 4)
        #expect(updates.contains { $0.phase == .scanning })
        #expect(updates.contains { $0.phase == .reading && $0.filesToParse == 120 })
        #expect(updates.contains { $0.phase == .writing && $0.writesPlanned == 120 })
        #expect(updates.last?.phase == .finishing)

        // Files parsed never goes backwards, and ends at everything there was.
        let parsed = updates.filter { $0.phase == .reading }.map(\.filesParsed)
        #expect(parsed == parsed.sorted())
        #expect(parsed.last == 120)

        let written = updates.filter { $0.phase == .writing }.map(\.writesApplied)
        #expect(written == written.sorted())
        #expect(written.last == 120)

        // Fraction is only claimed once the pass knows the denominator.
        #expect(updates.first { $0.phase == .scanning }?.fraction == nil)
        #expect(updates.last?.fraction == 1)
    }

    // MARK: - Saying which of the two "not yet" states this is

    @Test("An empty index and a building index are different states")
    func buildingIsNotEmpty() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.seed(corpus)

        let idle = MailIndex.status(store: corpus.store, index: corpus.index, activePass: nil)
        #expect(idle.indexState == "empty")
        #expect(idle.activeRefresh == nil)
        #expect(idle.completeness.hasPrefix("EMPTY:"))
        #expect(idle.warnings.contains { $0.contains("never completed a full pass") })

        let building = MailIndex.status(
            store: corpus.store,
            index: corpus.index,
            activePass: Self.runningSnapshot()
        )
        #expect(building.indexState == "building")
        #expect(building.activeRefresh?.jobID == "pass-testjob")
        #expect(building.activeRefresh?.filesSeen == 4000)
        #expect(building.activeRefresh?.fractionComplete == 0.3)
        #expect(building.completeness.hasPrefix("BUILDING:"))
        #expect(building.usable == false)
        #expect(building.warnings.contains { $0.contains("joins this one") })
    }

    @Test("A pass over an index that has completed one before reads as refreshing")
    func refreshingIsNotBuilding() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.seed(corpus)
        try MailIndex.refresh(store: corpus.store, index: corpus.index)

        let current = MailIndex.status(store: corpus.store, index: corpus.index, activePass: nil)
        #expect(current.indexState == "current")
        #expect(current.usable)

        let refreshing = MailIndex.status(
            store: corpus.store,
            index: corpus.index,
            activePass: Self.runningSnapshot()
        )
        #expect(refreshing.indexState == "refreshing")
        #expect(refreshing.activeRefresh?.jobID == "pass-testjob")
        // A running pass does not make a current index unusable: what the
        // index already holds is still a completed pass over the store.
        #expect(refreshing.usable)
        #expect(refreshing.completeness.hasPrefix("CURRENT:"))
        #expect(refreshing.completeness.contains("pass-testjob"))

        let stale = MailIndex.status(
            store: corpus.store,
            index: corpus.index,
            now: Date().addingTimeInterval(MailIndex.freshnessWindow + 60),
            activePass: Self.runningSnapshot()
        )
        #expect(stale.indexState == "refreshing")
        #expect(stale.stale)
        #expect(stale.completeness.hasPrefix("STALE:"))
    }

    @Test("An index the job coordinator can start a real pass over reports it end to end")
    func startRefreshDrivesARealPass() throws {
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }
        try MailIndexTests.seed(corpus)

        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.end-to-end")
        let start = try coordinator.startRefresh(
            store: corpus.store,
            index: corpus.index,
            fileLimit: 200_000
        )
        #expect(start.started)
        #expect(start.snapshot.fileLimit == 200_000)

        let finished = coordinator.wait(upTo: 30)
        #expect(finished?.state == "succeeded")
        #expect(finished?.finishedAt != nil)
        // The report the job carries describes the index as the pass left it,
        // not as still building.
        #expect(finished?.report?.status.indexState == "current")
        #expect(finished?.report?.status.activeRefresh == nil)
        #expect(finished?.report?.status.messageCount == 5)
    }

    @Test("A store with no Full Disk Access refuses before any job is started")
    func missingStoreRefusesSynchronously() throws {
        let missing = MailLocalStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-core-absent-\(UUID().uuidString)")
        )
        let corpus = try MailIndexTests.makeCorpus()
        defer { MailIndexTests.remove(corpus) }

        let coordinator = MailIndexJobCoordinator(label: "apple-core.tests.no-store")
        #expect(throws: MailIndexError.self) {
            try coordinator.startRefresh(store: missing, index: corpus.index)
        }
        #expect(coordinator.snapshot() == nil)
    }
}
