// SPDX-License-Identifier: GPL-3.0-or-later
//
// The mail index as one operation, and as one honest description of itself.
//
// Everything a client is told about the index is assembled here: whether it
// can be built at all, how old it is, how many messages it holds, how many of
// those have bodies that are not on this Mac, and which files it could not
// read. That reporting is the point of the feature and not decoration around
// it. A fast index that quietly answers from a subset is worse than the slow
// scan it replaces, because the caller cannot tell the difference between
// "no such message" and "not indexed yet".
//
// So three states are always distinguishable in the output:
//
//   - the index cannot be read at all (no Full Disk Access), which is said in
//     those words rather than returned as zero results;
//   - the index is older than its freshness window, or its last pass stopped
//     early, in which case `stale` is true and the age is given;
//   - the index is current, and the counts below describe exactly what it
//     covers, including the messages whose bodies are still on the server.

import Foundation

/// The index's own account of itself.
struct MailIndexStatus: Sendable, Equatable, Codable {
    /// True only when the index exists, is readable, and its last pass
    /// covered the whole store.
    let usable: Bool
    /// What to do next, in one word: `no_disk_access`, `no_local_mail`,
    /// `building` (nothing usable yet and a pass is running), `refreshing`
    /// (usable or stale, and a pass is running), `empty` (no pass has ever
    /// completed and none is running), `stale` or `current`.
    ///
    /// `building` and `empty` are kept apart on purpose. Both mean the index
    /// cannot answer a question yet, and they call for opposite actions: one
    /// says wait and poll, the other says start a pass. Collapsing them is
    /// how a caller ends up starting a second pass over a store the first is
    /// still walking.
    let indexState: String
    /// The pass running right now, or nil. Read from memory, never from the
    /// index, so it stays readable while the index is being written.
    let activeRefresh: MailIndexRefreshActivity?
    /// `available`, `no_local_mail` or `no_disk_access`.
    let access: String
    let accessDetail: String
    let indexPath: String
    let lastCompleteRefresh: String?
    let ageSeconds: Int?
    let stale: Bool
    let messageCount: Int
    let mailboxCount: Int
    let accountCount: Int
    /// Messages whose body is not fully readable on this Mac: not downloaded,
    /// or in a form this index does not extract text from.
    let incompleteBodyCount: Int
    let unreadableFileCount: Int
    let unreadableExamples: [MailIndexIssue]
    /// Message-IDs the store holds in more than one place. Reported, never
    /// collapsed: each copy is really in the mailbox the index says it is.
    let duplicateMessageCount: Int
    let bodySearchAvailable: Bool
    /// One paragraph a client can relay verbatim.
    let completeness: String
    let warnings: [String]
}

struct MailIndexRefreshReport: Sendable, Equatable, Codable {
    let scannedFiles: Int
    let inserted: Int
    let updated: Int
    let unchanged: Int
    let removed: Int
    let moved: [MailIndexCarry]
    let downloaded: [MailIndexCarry]
    let unreadable: [MailIndexIssue]
    /// False when the pass stopped at its file limit. The index is usable but
    /// incomplete, and the status says so until a pass finishes.
    let scanComplete: Bool
    let durationSeconds: Double
    let status: MailIndexStatus
}

enum MailIndexError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): return detail
        }
    }
}

enum MailIndex {
    /// How long a refresh stays trustworthy. Mail writes a file the moment a
    /// message arrives, so a quarter hour is a compromise between rescanning
    /// constantly and answering from an index that has missed a morning.
    static let freshnessWindow: TimeInterval = 15 * 60

    /// Builds or updates the index, then reports what changed.
    ///
    /// Refusing to start is itself an answer: without Full Disk Access this
    /// throws with that reason rather than writing an empty index that would
    /// then be reported as a complete picture of an empty mailbox.
    @discardableResult
    static func refresh(
        store: MailLocalStore = .default,
        index: MailIndexStore = .default,
        fileLimit: Int = 200_000,
        now: Date = Date(),
        progress: @escaping @Sendable (MailIndexProgress) -> Void = { _ in }
    ) throws -> MailIndexRefreshReport {
        let started = Date()
        let access = store.access
        guard access.isAvailable else {
            throw MailIndexError.unavailable(access.explanation)
        }
        try index.prepare()

        // Progress is reported from three places because a pass has three
        // costs and they are not interchangeable: the walk is I/O over
        // directories, the read is I/O plus parsing over files, and the write
        // is SQLite. A caller watching one number that stalls cannot tell a
        // slow pass from a stuck one; a caller watching the phase can.
        var state = MailIndexProgress()
        func publish() { progress(state) }
        publish()

        let scan = try store.scan(fileLimit: fileLimit) { seen in
            state.filesSeen = seen
            state.detail = "Walking Mail's message files: \(seen) found so far."
            publish()
        }
        let existing = try index.entries()

        // Parse first, plan second: move detection needs the Message-ID of
        // every newly seen file, and a file that will not parse has to be
        // reported rather than silently dropped.
        var documents: [String: MailEmlxDocument] = [:]
        var messageIDs: [String: String] = [:]
        var issues = scan.issues

        let firstPass = MailIndexReconciler.plan(existing: existing, scanned: scan.files)
        let toParse = firstPass.inserted + firstPass.updated
        state.phase = .reading
        state.filesSeen = scan.files.count
        state.filesToParse = toParse.count
        state.filesParsed = 0
        state.detail =
            "\(scan.files.count) message file(s) found; \(toParse.count) are new or changed and "
            + "are being read."
        publish()
        for (offset, file) in toParse.enumerated() {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
                let document = try MailEmlxParser.parse(data: data, isPartial: file.isPartial)
                documents[file.stableID] = document
                if let identifier = document.messageID {
                    messageIDs[file.stableID] = identifier
                }
            } catch {
                issues.append(
                    MailIndexIssue(path: file.path, reason: error.localizedDescription)
                )
            }
            if (offset + 1) % 200 == 0 || offset + 1 == toParse.count {
                state.filesParsed = offset + 1
                state.detail = "Read \(offset + 1) of \(toParse.count) new or changed file(s)."
                publish()
            }
        }

        let plan = MailIndexReconciler.plan(
            existing: existing,
            scanned: scan.files,
            messageIDs: messageIDs
        )
        state.phase = .writing
        state.writesPlanned = plan.inserted.count + plan.updated.count
        state.writesApplied = 0
        state.detail = "Writing \(state.writesPlanned ?? 0) row(s) into the index."
        publish()
        try index.apply(
            plan: plan,
            documents: documents,
            issues: issues,
            scanComplete: !scan.truncated,
            now: now
        ) { written in
            state.writesApplied = written
            state.detail = "Wrote \(written) of \(state.writesPlanned ?? 0) row(s)."
            publish()
        }

        state.phase = .finishing
        state.detail = "The pass finished; the index is describing itself."
        publish()

        return MailIndexRefreshReport(
            scannedFiles: scan.files.count,
            inserted: plan.inserted.count,
            updated: plan.updated.count,
            unchanged: plan.unchangedIDs.count,
            removed: plan.removedIDs.count,
            moved: plan.carried.filter { $0.kind == .moved },
            downloaded: plan.carried.filter { $0.kind == .downloaded },
            unreadable: issues,
            scanComplete: !scan.truncated,
            durationSeconds: Date().timeIntervalSince(started),
            // Explicitly no active pass: this status describes the index as
            // this pass left it, and this pass is over. The job is still
            // marked running until the coordinator records the result, and
            // inheriting that here would make a finished report describe
            // itself as still building.
            status: status(store: store, index: index, now: now, activePass: nil)
        )
    }

    /// Describes the index without touching Mail's store beyond an access
    /// check, so a client can ask "can I trust this" cheaply.
    static func status(
        store: MailLocalStore = .default,
        index: MailIndexStore = .default,
        now: Date = Date(),
        activePass: MailIndexJobSnapshot? = MailIndexJobCoordinator.shared.activeSnapshot()
    ) -> MailIndexStatus {
        let access = store.access
        let accessCode: String
        switch access {
        case .available: accessCode = "available"
        case .noLocalMail: accessCode = "no_local_mail"
        case .accessDenied: accessCode = "no_disk_access"
        }

        // No index file is created, migrated or rebuilt as a side effect of
        // asking about one. An index that is not there yet is reported as a
        // pass that has never completed, which is exactly what it is.
        let prepared = index.isPrepared()
        let counts =
            prepared
            ? ((try? index.counts()) ?? (messages: 0, partial: 0, mailboxes: 0, accounts: 0))
            : (messages: 0, partial: 0, mailboxes: 0, accounts: 0)
        let issues = prepared ? ((try? index.issues(limit: 5)) ?? []) : []
        let issueCount = prepared ? ((try? index.issueCount()) ?? 0) : 0
        let duplicates = prepared ? ((try? index.duplicateMessageIDCount()) ?? 0) : 0

        let completeRefresh =
            prepared
            ? (try? index.metadata("last_complete_refresh"))
                .flatMap { $0 }
                .flatMap(Double.init)
                .map { Date(timeIntervalSince1970: $0) } : nil
        let age = completeRefresh.map { Int(now.timeIntervalSince($0)) }
        let stale = age.map { Double($0) > freshnessWindow } ?? true
        let usable = access.isAvailable && prepared && completeRefresh != nil && !stale

        var warnings: [String] = []
        if !access.isAvailable { warnings.append(access.explanation) }
        if let activePass {
            warnings.append(
                "A refresh pass (\(activePass.jobID)) is running now, "
                    + "\(Int(activePass.elapsedSeconds)) second(s) in: "
                    + activePass.progress.detail
                    + " Poll mail_index_status rather than starting another; a second refresh "
                    + "joins this one instead of running beside it."
            )
        }
        if completeRefresh == nil, activePass == nil {
            warnings.append(
                "The index has never completed a full pass, so it does not yet describe this "
                    + "Mac's mail. Run mail_index_refresh before relying on it."
            )
        } else if stale, let age {
            warnings.append(
                "The index was last refreshed \(age) seconds ago, past its \(Int(freshnessWindow))"
                    + "-second freshness window, so messages that arrived, moved or were deleted "
                    + "since then are not reflected."
            )
        }
        if counts.partial > 0 {
            warnings.append(
                "\(counts.partial) indexed message(s) have bodies that are not fully readable on "
                    + "this Mac, usually because the body has not been downloaded from the "
                    + "server. Their headers are indexed; their text is not."
            )
        }
        if issueCount > 0 {
            warnings.append(
                "\(issueCount) message file(s) could not be read or parsed and are absent from "
                    + "the index. They are listed in unreadable_examples."
            )
        }
        if duplicates > 0 {
            warnings.append(
                "\(duplicates) message(s) appear in more than one mailbox. Each copy is indexed "
                    + "where it actually is; they are not merged."
            )
        }
        let fullTextAvailable = prepared && index.fullTextAvailable
        if prepared, !fullTextAvailable {
            warnings.append(
                "This SQLite has no FTS5 module, so message bodies are stored but cannot be "
                    + "matched. Header and subject data is unaffected."
            )
        }

        // The state word and the paragraph are written together so they can
        // never disagree. A running pass takes precedence in both, because it
        // is the only fact that changes what the caller should do next.
        let indexState: String
        if !access.isAvailable {
            indexState = accessCode
        } else if activePass != nil {
            indexState = completeRefresh == nil ? "building" : "refreshing"
        } else if completeRefresh == nil {
            indexState = "empty"
        } else {
            indexState = stale ? "stale" : "current"
        }

        let passLine =
            activePass.map {
                " A refresh pass (\($0.jobID)) has been running for "
                    + "\(Int($0.elapsedSeconds)) second(s): \($0.progress.detail) "
                    + "Poll mail_index_status until it reports a completed pass."
            } ?? ""

        let completeness: String
        if !access.isAvailable {
            completeness = access.explanation
        } else if completeRefresh == nil, activePass != nil {
            completeness =
                "BUILDING: the index holds no completed pass yet, and one is running now."
                + passLine
                + " Treat every answer from the index as unavailable rather than as absent until "
                + "it finishes."
        } else if completeRefresh == nil {
            completeness =
                "EMPTY: the index holds no completed pass over Mail's local store. Treat every "
                + "answer from it as unavailable rather than as absent."
        } else if stale {
            completeness =
                "STALE: the index covers \(counts.messages) message(s) in \(counts.mailboxes) "
                + "mailbox(es) as of the last complete refresh, \(age ?? 0) second(s) ago. "
                + "Anything that changed since is missing." + passLine
        } else {
            completeness =
                "CURRENT: the index covers \(counts.messages) message(s) in \(counts.mailboxes) "
                + "mailbox(es) across \(counts.accounts) account(s), refreshed \(age ?? 0) "
                + "second(s) ago. \(counts.partial) of those have bodies that are not fully "
                + "readable on this Mac, and \(issueCount) file(s) could not be read at all."
                + passLine
        }

        return MailIndexStatus(
            usable: usable,
            indexState: indexState,
            activeRefresh: activePass?.activity,
            access: accessCode,
            accessDetail: access.explanation,
            indexPath: index.fileURL.path,
            lastCompleteRefresh: completeRefresh.map {
                ISO8601DateFormatter().string(from: $0)
            },
            ageSeconds: age,
            stale: stale,
            messageCount: counts.messages,
            mailboxCount: counts.mailboxes,
            accountCount: counts.accounts,
            incompleteBodyCount: counts.partial,
            unreadableFileCount: issueCount,
            unreadableExamples: issues,
            duplicateMessageCount: duplicates,
            bodySearchAvailable: fullTextAvailable,
            completeness: completeness,
            warnings: warnings
        )
    }
}
