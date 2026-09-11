// SPDX-License-Identifier: GPL-3.0-or-later
//
// What is actually wrong with Mail on this Mac, said in a way that survives
// being relayed.
//
// Three things go wrong with a Mail surface and they need separate answers:
//
//   - Apple Core cannot talk to Mail at all (Automation permission), so every
//     tool fails and nothing else in the report means anything;
//   - Apple Core can talk to Mail but cannot read Mail's files (Full Disk
//     Access), so the index-backed tools fail while the scripted ones work;
//   - both work, and the mail itself is incomplete: bodies still on the
//     server, an account with nothing stored locally, an index that has not
//     been refreshed since this morning.
//
// The third is the one that gets misreported. `mail_check_for_new_mail` sends
// Mail a command and returns when Mail accepts it, which is not a report that
// a sync finished, and there is no scripting property anywhere in Mail that
// says an account is connected. So this file never claims reachability. It
// reports the evidence that does exist -- what is stored locally, how much of
// it is only a stub, and how old the newest stored message in each account is
// -- and names it as evidence rather than as a verdict.
//
// Everything here is a pure function of its inputs so the wording can be
// tested without a Mac that has mail on it.

import Foundation

/// One diagnosed condition. `status` is `ok`, `warn` or `fail`.
struct MailCheck: Codable, Sendable, Equatable {
    let name: String
    let status: String
    let detail: String
}

/// An account as Mail describes it over Apple Events.
struct MailDiagnosticAccount: Sendable, Equatable {
    /// Mail's own account id, which is also the name of the account's
    /// directory on disk. It is the only join between this list and the index.
    let id: String
    let name: String
    let enabled: Bool
    let emailAddresses: [String]
}

/// What the local index holds for one account.
struct MailAccountCoverage: Sendable, Equatable {
    let accountID: String
    let messageCount: Int
    /// Messages stored as a stub because the body was never downloaded.
    let incompleteCount: Int
    let newestMessage: Date?
}

struct MailDiagnosticReport: Codable, Sendable, Equatable {
    let healthy: Bool
    let checks: [MailCheck]
    /// Standing caveats that are true whatever the checks said. Always
    /// present, because the most common wrong conclusion about Mail is drawn
    /// from a healthy report rather than from a failing one.
    let notes: [String]
}

enum MailDiagnostics {
    /// How old the newest locally stored message in an account may be before
    /// the account is worth looking at. Two weeks is long enough that a quiet
    /// mailing-list account does not trip it every run.
    static let quietAccountDays = 14

    /// The report when Apple Events cannot reach Mail. Nothing else is
    /// diagnosed, because every other check would fail for this one reason
    /// and the list would read as five problems instead of one.
    static func unreachableReport(_ description: String) -> MailDiagnosticReport {
        MailDiagnosticReport(
            healthy: false,
            checks: [
                MailCheck(
                    name: "Mail.app",
                    status: "fail",
                    detail:
                        "not reachable: \(description). Grant Apple Core control of Mail in "
                        + "System Settings > Privacy & Security > Automation, then try again. "
                        + "Nothing else was checked, because every Mail tool depends on this."
                )
            ],
            notes: [syncNote]
        )
    }

    static var reachableCheck: MailCheck {
        MailCheck(name: "Mail.app", status: "ok", detail: "reachable via Apple Events")
    }

    /// The caveat that has to travel with every healthy report.
    static let syncNote =
        "A healthy report is not a report that mail is up to date. "
        + "mail_check_for_new_mail asks Mail to start a check and returns as soon as Mail "
        + "accepts the command; it never waits for a sync to finish, and Mail exposes no "
        + "scripting property saying an account is connected. Completed download is visible "
        + "here only as the index's undownloaded-body count and each account's newest stored "
        + "message."

    static func accountsCheck(
        accounts: [MailDiagnosticAccount]?,
        error: String?
    ) -> MailCheck {
        guard let accounts else {
            return MailCheck(
                name: "Accounts",
                status: "fail",
                detail: "could not list accounts: \(error ?? "unknown error")"
            )
        }
        guard !accounts.isEmpty else {
            return MailCheck(
                name: "Accounts",
                status: "warn",
                detail: "no Mail accounts are configured, so every Mail tool will come back empty"
            )
        }
        let disabled = accounts.filter { !$0.enabled }
        let enabled = accounts.count - disabled.count
        guard enabled > 0 else {
            return MailCheck(
                name: "Accounts",
                status: "warn",
                detail:
                    "all \(accounts.count) account(s) are disabled in Mail, so no mail is being "
                    + "fetched: \(accounts.map(\.name).joined(separator: ", "))"
            )
        }
        if disabled.isEmpty {
            return MailCheck(
                name: "Accounts",
                status: "ok",
                detail:
                    "\(accounts.count) account(s), all enabled: "
                    + accounts.map(\.name).joined(separator: ", ")
            )
        }
        return MailCheck(
            name: "Accounts",
            status: "warn",
            detail:
                "\(enabled) of \(accounts.count) account(s) enabled. Disabled, so nothing is "
                + "fetched for them: " + disabled.map(\.name).joined(separator: ", ")
        )
    }

    /// Full Disk Access, phrased as what it costs rather than as a fault:
    /// only the index-backed tools need it.
    static func localStoreCheck(_ access: MailLocalStoreAccess) -> MailCheck {
        switch access {
        case .available:
            return MailCheck(name: "Mail local store", status: "ok", detail: access.explanation)
        case .noLocalMail, .accessDenied:
            return MailCheck(name: "Mail local store", status: "warn", detail: access.explanation)
        }
    }

    static func indexCheck(_ status: MailIndexStatus?) -> MailCheck {
        guard let status else {
            return MailCheck(
                name: "Local index",
                status: "warn",
                detail:
                    "the local mail index could not be read, so mail_index_search and "
                    + "mail_index_messages will fail. Every scripted Mail tool is unaffected."
            )
        }
        let state = status.indexState
        let ok = state == "current"
        var detail =
            "index_state=\(state). \(status.completeness)"
        if !status.warnings.isEmpty {
            detail += " " + status.warnings.joined(separator: " ")
        }
        return MailCheck(
            name: "Local index",
            status: ok ? "ok" : "warn",
            detail: detail
        )
    }

    /// Messages whose bodies are not on this Mac. This is the honest answer to
    /// "did the sync finish", so it is its own check rather than a footnote on
    /// the index check.
    static func downloadCheck(_ status: MailIndexStatus?) -> MailCheck {
        guard let status else {
            return MailCheck(
                name: "Downloaded bodies",
                status: "warn",
                detail:
                    "not known: the local index could not be read, so there is no count of "
                    + "messages whose bodies are still on the server."
            )
        }
        if status.messageCount == 0 {
            return MailCheck(
                name: "Downloaded bodies",
                status: "warn",
                detail:
                    "not known: the index holds no messages yet, so nothing can be said about "
                    + "how much mail is stored on this Mac. Run mail_index_refresh."
            )
        }
        if status.incompleteBodyCount == 0 {
            return MailCheck(
                name: "Downloaded bodies",
                status: "ok",
                detail:
                    "every one of the \(status.messageCount) indexed message(s) has its body on "
                    + "this Mac."
            )
        }
        let share = percentage(status.incompleteBodyCount, of: status.messageCount)
        return MailCheck(
            name: "Downloaded bodies",
            status: "warn",
            detail:
                "\(status.incompleteBodyCount) of \(status.messageCount) indexed message(s) "
                + "(\(share)) have no downloaded body, so their text cannot be read or searched "
                + "locally. Mail downloads these on demand, or on a schedule set per account in "
                + "Mail's account settings."
        )
    }

    static func unreadableFilesCheck(_ status: MailIndexStatus?) -> MailCheck? {
        guard let status, status.unreadableFileCount > 0 else { return nil }
        let examples = status.unreadableExamples.prefix(3).map(\.path).joined(separator: ", ")
        return MailCheck(
            name: "Unreadable files",
            status: "warn",
            detail:
                "\(status.unreadableFileCount) message file(s) in Mail's store could not be read, "
                + "so they are missing from every index-backed answer"
                + (examples.isEmpty ? "." : ". For example: \(examples)")
        )
    }

    /// Per-account evidence. Deliberately not called reachability: an account
    /// with nothing stored locally may be perfectly healthy and configured to
    /// keep everything on the server.
    static func coverageChecks(
        accounts: [MailDiagnosticAccount],
        coverage: [MailAccountCoverage],
        now: Date
    ) -> [MailCheck] {
        guard !accounts.isEmpty, !coverage.isEmpty else { return [] }
        let byID = Dictionary(coverage.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
        var checks: [MailCheck] = []

        let enabled = accounts.filter(\.enabled)
        let missing = enabled.filter { (byID[$0.id]?.messageCount ?? 0) == 0 }
        if !missing.isEmpty {
            checks.append(
                MailCheck(
                    name: "Accounts with no local mail",
                    status: "warn",
                    detail:
                        "\(missing.map(\.name).joined(separator: ", ")) — enabled, but the index "
                        + "holds no messages for them. That is expected for an account set to "
                        + "keep everything on the server, and it is also what a never-connected "
                        + "account looks like. Check the account in Mail to tell them apart."
                )
            )
        }

        var quiet: [String] = []
        for account in enabled {
            guard let row = byID[account.id], row.messageCount > 0,
                let newest = row.newestMessage
            else { continue }
            let days = Int(now.timeIntervalSince(newest) / 86_400)
            if days >= quietAccountDays {
                quiet.append("\(account.name) (\(days) days)")
            }
        }
        if !quiet.isEmpty {
            checks.append(
                MailCheck(
                    name: "Quiet accounts",
                    status: "warn",
                    detail:
                        "the newest message stored locally is old for: "
                        + quiet.joined(separator: ", ")
                        + ". This is a signal to look, not a verdict: a quiet account and an "
                        + "account that has stopped fetching look the same from here."
                )
            )
        }
        return checks
    }

    /// Assembles the report. `checks` arrives already ordered by the caller.
    static func report(checks: [MailCheck], extraNotes: [String] = []) -> MailDiagnosticReport {
        MailDiagnosticReport(
            healthy: !checks.contains { $0.status == "fail" },
            checks: checks,
            notes: [syncNote] + extraNotes
        )
    }

    private static func percentage(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let value = (Double(part) / Double(whole)) * 100
        if value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }
}
