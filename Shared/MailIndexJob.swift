// SPDX-License-Identifier: GPL-3.0-or-later
//
// One mail index pass, driven from outside the request that started it.
//
// A first pass over a real mail store is minutes of work, not seconds. An 11
// GB ~/Library/Mail takes far longer than any MCP client will wait, and a
// blocking tool call over it produces the worst outcome available: the client
// reports a timeout while the server keeps indexing, so the caller is told it
// failed while it is actually succeeding, and a retry starts a second pass
// over the same files.
//
// So a pass is a job. `start` returns as soon as the work is on a background
// queue, `snapshot` describes it while it runs, and `wait` lets a caller
// block for a budget it chooses rather than for however long the store takes.
//
// Two rules hold the whole thing together:
//
//   - Only one pass may touch the index at a time. A second `start` while one
//     is running never runs in parallel; it joins the running job and returns
//     that job's identifier with `started` false.
//   - Progress lives here, in memory, and not in the index. The index is
//     being written during a pass, and progress a caller can only read by
//     taking a lock on the thing being written is progress they cannot read
//     at the one moment it matters.

import Foundation

/// How far a pass has got, in the vocabulary of the work it does.
enum MailIndexPhase: String, Sendable, Equatable, Codable {
    /// Walking Mail's directories to find message files.
    case scanning
    /// Parsing the files that are new or have changed since the last pass.
    case reading
    /// Writing the reconciled plan into the index.
    case writing
    /// The pass finished and is describing itself.
    case finishing
}

/// A running pass's own account of itself, held outside SQLite.
struct MailIndexProgress: Sendable, Equatable, Codable {
    var phase: MailIndexPhase = .scanning
    /// Message files the walk has seen so far.
    var filesSeen: Int = 0
    /// Files parsed out of the set that needed re-reading.
    var filesParsed: Int = 0
    /// How many files need re-reading. Unknown until the walk finishes.
    var filesToParse: Int?
    /// Rows written so far, and how many the plan holds.
    var writesApplied: Int = 0
    var writesPlanned: Int?
    /// One sentence a client can relay without doing arithmetic.
    var detail: String = "Walking Mail's message files."

    /// Fraction done, when the pass knows enough to say. Nil during the walk,
    /// because the number of files is not known until it ends.
    var fraction: Double? {
        switch phase {
        case .scanning:
            return nil
        case .reading:
            guard let total = filesToParse, total > 0 else { return nil }
            return min(1, Double(filesParsed) / Double(total))
        case .writing:
            guard let total = writesPlanned, total > 0 else { return nil }
            return min(1, Double(writesApplied) / Double(total))
        case .finishing:
            return 1
        }
    }
}

/// What `mail_index_status` says about a pass that is running right now.
///
/// Deliberately not the whole job: the status block is embedded in a refresh
/// report, and a report embedded back inside it would be a type that cannot
/// exist. A caller that wants the finished report asks the job, not the
/// status.
struct MailIndexRefreshActivity: Sendable, Equatable, Codable {
    let jobID: String
    let startedAt: String
    let elapsedSeconds: Double
    let phase: String
    let filesSeen: Int
    let filesParsed: Int
    let filesToParse: Int?
    let writesApplied: Int
    let writesPlanned: Int?
    let fractionComplete: Double?
    let detail: String
}

/// A job, running or finished.
struct MailIndexJobSnapshot: Sendable, Equatable, Codable {
    /// `running`, `succeeded` or `failed`.
    let state: String
    let jobID: String
    let startedAt: String
    let finishedAt: String?
    let elapsedSeconds: Double
    let fileLimit: Int
    let progress: MailIndexProgress
    /// Present only when `state` is `failed`, in the words the pass used.
    let failure: String?
    /// Present only when `state` is `succeeded`.
    let report: MailIndexRefreshReport?

    var isRunning: Bool { state == "running" }

    /// The same job reduced to what a status block carries.
    var activity: MailIndexRefreshActivity {
        MailIndexRefreshActivity(
            jobID: jobID,
            startedAt: startedAt,
            elapsedSeconds: elapsedSeconds,
            phase: progress.phase.rawValue,
            filesSeen: progress.filesSeen,
            filesParsed: progress.filesParsed,
            filesToParse: progress.filesToParse,
            writesApplied: progress.writesApplied,
            writesPlanned: progress.writesPlanned,
            fractionComplete: progress.fraction,
            detail: progress.detail
        )
    }
}

/// The result of asking for a pass: which job you got, and whether asking
/// started it.
struct MailIndexJobStart: Sendable, Equatable {
    let snapshot: MailIndexJobSnapshot
    /// False when a pass was already running and this call joined it. A
    /// second pass is never started over the same index.
    let started: Bool
}

/// Runs mail index passes one at a time and reports on them while they run.
///
/// `@unchecked Sendable` with an `NSCondition`: the mutable state is three
/// fields, every touch of them is inside the lock, and the condition is what
/// lets `wait` block for a budget without polling.
final class MailIndexJobCoordinator: @unchecked Sendable {
    /// The one coordinator the tools use. Tests make their own.
    static let shared = MailIndexJobCoordinator()

    private let condition = NSCondition()
    private let queue: DispatchQueue
    private var runningID: String?
    private var runningStart: Date?
    private var runningLimit: Int = 0
    private var runningProgress = MailIndexProgress()
    private var lastFinished: MailIndexJobSnapshot?

    init(label: String = "consulting.ames.apple-core.mail-index") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    // MARK: - Starting

    /// Starts a pass, or joins the one already running.
    ///
    /// `work` is handed a progress sink it may call from any thread. It runs
    /// on this coordinator's own serial queue, so even a caller that ignores
    /// the return value cannot get two passes writing the same index.
    @discardableResult
    func start(
        fileLimit: Int,
        work:
            @escaping @Sendable (@escaping @Sendable (MailIndexProgress) -> Void) throws ->
            MailIndexRefreshReport
    ) -> MailIndexJobStart {
        condition.lock()
        if let running = snapshotLocked(now: Date()), running.isRunning {
            condition.unlock()
            return MailIndexJobStart(snapshot: running, started: false)
        }
        let jobID = "pass-" + UUID().uuidString.prefix(8).lowercased()
        let started = Date()
        runningID = jobID
        runningStart = started
        runningLimit = fileLimit
        runningProgress = MailIndexProgress()
        let snapshot = snapshotLocked(now: started) ?? Self.emptySnapshot(jobID: jobID)
        condition.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let sink: @Sendable (MailIndexProgress) -> Void = { [weak self] progress in
                self?.record(progress, for: jobID)
            }
            do {
                let report = try work(sink)
                self.finish(jobID: jobID, report: report, failure: nil)
            } catch {
                self.finish(jobID: jobID, report: nil, failure: error.localizedDescription)
            }
        }

        return MailIndexJobStart(snapshot: snapshot, started: true)
    }

    // MARK: - Reading

    /// The running pass, or the last one to finish, or nil if none ever ran
    /// in this process.
    func snapshot(now: Date = Date()) -> MailIndexJobSnapshot? {
        condition.lock()
        defer { condition.unlock() }
        return snapshotLocked(now: now)
    }

    /// The running pass only. This is what a status block reports, because
    /// "a pass finished twenty minutes ago" is already said by the index's
    /// own freshness, and only a pass running *now* changes what a caller
    /// should do next.
    func activeSnapshot(now: Date = Date()) -> MailIndexJobSnapshot? {
        guard let snapshot = snapshot(now: now), snapshot.isRunning else { return nil }
        return snapshot
    }

    /// Blocks for at most `seconds`, then reports wherever the job got to.
    ///
    /// This is the whole answer to the timeout: a caller decides how long it
    /// is willing to wait, and gets a truthful snapshot either way, instead
    /// of a connection that dies while the work continues unobserved.
    func wait(upTo seconds: TimeInterval, now: @escaping @Sendable () -> Date = Date.init)
        -> MailIndexJobSnapshot?
    {
        condition.lock()
        defer { condition.unlock() }
        guard let waitingFor = runningID else { return snapshotLocked(now: now()) }
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while runningID == waitingFor, Date() < deadline {
            condition.wait(until: deadline)
        }
        return snapshotLocked(now: now())
    }

    // MARK: - Internals

    private func record(_ progress: MailIndexProgress, for jobID: String) {
        condition.lock()
        if runningID == jobID { runningProgress = progress }
        condition.broadcast()
        condition.unlock()
    }

    private func finish(jobID: String, report: MailIndexRefreshReport?, failure: String?) {
        condition.lock()
        let now = Date()
        let startedAt = runningStart ?? now
        var progress = runningProgress
        progress.phase = .finishing
        progress.detail =
            failure.map { "The pass stopped: \($0)" }
            ?? "The pass finished and the index describes it."
        lastFinished = MailIndexJobSnapshot(
            state: failure == nil ? "succeeded" : "failed",
            jobID: jobID,
            startedAt: Self.timestamp(startedAt),
            finishedAt: Self.timestamp(now),
            elapsedSeconds: now.timeIntervalSince(startedAt),
            fileLimit: runningLimit,
            progress: progress,
            failure: failure,
            report: report
        )
        runningID = nil
        runningStart = nil
        condition.broadcast()
        condition.unlock()
    }

    private func snapshotLocked(now: Date) -> MailIndexJobSnapshot? {
        guard let runningID, let runningStart else { return lastFinished }
        return MailIndexJobSnapshot(
            state: "running",
            jobID: runningID,
            startedAt: Self.timestamp(runningStart),
            finishedAt: nil,
            elapsedSeconds: now.timeIntervalSince(runningStart),
            fileLimit: runningLimit,
            progress: runningProgress,
            failure: nil,
            report: nil
        )
    }

    private static func emptySnapshot(jobID: String) -> MailIndexJobSnapshot {
        MailIndexJobSnapshot(
            state: "running",
            jobID: jobID,
            startedAt: timestamp(Date()),
            finishedAt: nil,
            elapsedSeconds: 0,
            fileLimit: 0,
            progress: MailIndexProgress(),
            failure: nil,
            report: nil
        )
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

extension MailIndexJobCoordinator {
    /// Starts a real pass over a store, which is what the tool calls.
    ///
    /// The access check happens on the caller's thread, before anything is
    /// dispatched: a Mac without Full Disk Access should be told so in the
    /// response to the call that asked, not in a job that fails somewhere
    /// behind it.
    @discardableResult
    func startRefresh(
        store: MailLocalStore = .default,
        index: MailIndexStore = .default,
        fileLimit: Int = 200_000
    ) throws -> MailIndexJobStart {
        let access = store.access
        guard access.isAvailable else {
            throw MailIndexError.unavailable(access.explanation)
        }
        return start(fileLimit: fileLimit) { progress in
            try MailIndex.refresh(
                store: store,
                index: index,
                fileLimit: fileLimit,
                progress: progress
            )
        }
    }
}
