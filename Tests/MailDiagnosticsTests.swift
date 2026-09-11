import Foundation
import Testing

/// The wording of the Mail diagnosis, which is the whole feature: a report a
/// client relays wrongly is worse than no report.
@Suite("Mail diagnostics")
struct MailDiagnosticsTests {

    private func account(
        _ id: String,
        _ name: String,
        enabled: Bool = true
    ) -> MailDiagnosticAccount {
        MailDiagnosticAccount(
            id: id,
            name: name,
            enabled: enabled,
            emailAddresses: ["\(name.lowercased())@example.com"]
        )
    }

    private func status(
        state: String = "current",
        messages: Int = 100,
        incomplete: Int = 0,
        unreadable: Int = 0,
        examples: [MailIndexIssue] = [],
        warnings: [String] = []
    ) -> MailIndexStatus {
        MailIndexStatus(
            usable: state == "current",
            indexState: state,
            activeRefresh: nil,
            access: "available",
            accessDetail: "readable",
            indexPath: "/tmp/index.sqlite",
            lastCompleteRefresh: nil,
            ageSeconds: 30,
            stale: state == "stale",
            messageCount: messages,
            mailboxCount: 4,
            accountCount: 2,
            incompleteBodyCount: incomplete,
            unreadableFileCount: unreadable,
            unreadableExamples: examples,
            duplicateMessageCount: 0,
            bodySearchAvailable: true,
            completeness: "The index covers \(messages) message(s).",
            warnings: warnings
        )
    }

    // MARK: - Reachability

    @Test("An unreachable Mail stops the report at one failing check")
    func unreachable() {
        let report = MailDiagnostics.unreachableReport("connection is invalid")
        #expect(report.healthy == false)
        #expect(report.checks.count == 1)
        #expect(report.checks[0].status == "fail")
        #expect(report.checks[0].detail.contains("Automation"))
        #expect(report.notes.contains(MailDiagnostics.syncNote))
    }

    @Test("A healthy report still carries the sync caveat")
    func healthyStillWarnsAboutSync() {
        let report = MailDiagnostics.report(checks: [MailDiagnostics.reachableCheck])
        #expect(report.healthy)
        #expect(report.notes.first?.contains("mail_check_for_new_mail") == true)
        #expect(report.notes.first?.contains("never waits for a sync to finish") == true)
    }

    @Test("A warn does not make the report unhealthy; a fail does")
    func healthIsAboutFailures() {
        let warn = MailCheck(name: "x", status: "warn", detail: "d")
        let fail = MailCheck(name: "y", status: "fail", detail: "d")
        #expect(MailDiagnostics.report(checks: [warn]).healthy)
        #expect(MailDiagnostics.report(checks: [warn, fail]).healthy == false)
    }

    // MARK: - Accounts

    @Test("Every account enabled is ok")
    func allAccountsEnabled() {
        let check = MailDiagnostics.accountsCheck(
            accounts: [account("A1", "Work"), account("A2", "Home")],
            error: nil
        )
        #expect(check.status == "ok")
        #expect(check.detail.contains("Work"))
    }

    @Test("A disabled account is named rather than counted away")
    func someAccountsDisabled() {
        let check = MailDiagnostics.accountsCheck(
            accounts: [account("A1", "Work"), account("A2", "Old", enabled: false)],
            error: nil
        )
        #expect(check.status == "warn")
        #expect(check.detail.contains("Old"))
        #expect(check.detail.contains("1 of 2"))
    }

    @Test("All accounts disabled, no accounts, and a failed listing differ")
    func accountEdgeCases() {
        #expect(
            MailDiagnostics.accountsCheck(
                accounts: [account("A1", "Work", enabled: false)],
                error: nil
            ).status == "warn"
        )
        #expect(MailDiagnostics.accountsCheck(accounts: [], error: nil).status == "warn")
        let failed = MailDiagnostics.accountsCheck(accounts: nil, error: "no permission")
        #expect(failed.status == "fail")
        #expect(failed.detail.contains("no permission"))
    }

    // MARK: - Local store

    @Test("No Full Disk Access is a warning that names what still works")
    func accessDenied() {
        let check = MailDiagnostics.localStoreCheck(.accessDenied("/Users/x/Library/Mail"))
        #expect(check.status == "warn")
        #expect(check.detail.contains("NO_DISK_ACCESS"))
        #expect(check.detail.contains("Every other Mail tool works without this"))
    }

    @Test("An empty store is not reported as a denial")
    func noLocalMail() {
        let check = MailDiagnostics.localStoreCheck(.noLocalMail("/Users/x/Library/Mail"))
        #expect(check.status == "warn")
        #expect(check.detail.contains("NO_LOCAL_MAIL"))
    }

    @Test("A readable store is ok")
    func storeAvailable() {
        #expect(MailDiagnostics.localStoreCheck(.available(root: "/x")).status == "ok")
    }

    // MARK: - Index and downloads

    @Test("Only a current index is ok")
    func indexStates() {
        #expect(MailDiagnostics.indexCheck(status(state: "current")).status == "ok")
        for state in ["stale", "empty", "building", "refreshing", "no_disk_access"] {
            #expect(MailDiagnostics.indexCheck(status(state: state)).status == "warn")
        }
        #expect(MailDiagnostics.indexCheck(nil).status == "warn")
    }

    @Test("Index warnings are carried through to the check")
    func indexWarningsCarried() {
        let check = MailDiagnostics.indexCheck(
            status(state: "stale", warnings: ["The last pass stopped early."])
        )
        #expect(check.detail.contains("The last pass stopped early."))
    }

    @Test("Undownloaded bodies are counted and shared, never called a sync")
    func undownloadedBodies() {
        let check = MailDiagnostics.downloadCheck(status(messages: 200, incomplete: 50))
        #expect(check.status == "warn")
        #expect(check.detail.contains("50 of 200"))
        #expect(check.detail.contains("25%"))
        #expect(check.detail.contains("no downloaded body"))
    }

    @Test("A fully downloaded index is ok")
    func allDownloaded() {
        let check = MailDiagnostics.downloadCheck(status(messages: 10, incomplete: 0))
        #expect(check.status == "ok")
    }

    @Test("An empty index says not known rather than fully downloaded")
    func emptyIndexDownloads() {
        let check = MailDiagnostics.downloadCheck(status(messages: 0, incomplete: 0))
        #expect(check.status == "warn")
        #expect(check.detail.contains("not known"))
        #expect(MailDiagnostics.downloadCheck(nil).detail.contains("not known"))
    }

    @Test("A sub-one-percent share does not round to zero")
    func smallShare() {
        let check = MailDiagnostics.downloadCheck(status(messages: 10_000, incomplete: 3))
        #expect(check.detail.contains("<1%"))
    }

    @Test("Unreadable files are reported with examples, or not at all")
    func unreadableFiles() {
        #expect(MailDiagnostics.unreadableFilesCheck(status(unreadable: 0)) == nil)
        let check = MailDiagnostics.unreadableFilesCheck(
            status(
                unreadable: 2,
                examples: [MailIndexIssue(path: "/a.emlx", reason: "x")]
            )
        )
        #expect(check?.status == "warn")
        #expect(check?.detail.contains("/a.emlx") == true)
    }

    // MARK: - Per-account coverage

    private func coverage(
        _ id: String,
        messages: Int,
        incomplete: Int = 0,
        newest: Date?
    ) -> MailAccountCoverage {
        MailAccountCoverage(
            accountID: id,
            messageCount: messages,
            incompleteCount: incomplete,
            newestMessage: newest
        )
    }

    @Test("An enabled account with nothing stored is flagged without a verdict")
    func accountWithNoLocalMail() {
        let now = Date()
        let checks = MailDiagnostics.coverageChecks(
            accounts: [account("A1", "Work"), account("A2", "Never")],
            coverage: [
                coverage("A1", messages: 10, newest: now),
                coverage("A2", messages: 0, newest: nil),
            ],
            now: now
        )
        let missing = checks.first { $0.name == "Accounts with no local mail" }
        #expect(missing?.status == "warn")
        #expect(missing?.detail.contains("Never") == true)
        #expect(missing?.detail.contains("expected for an account set to keep everything") == true)
    }

    @Test("A disabled account is not flagged for having no local mail")
    func disabledAccountNotFlagged() {
        let now = Date()
        let checks = MailDiagnostics.coverageChecks(
            accounts: [account("A1", "Off", enabled: false)],
            coverage: [coverage("A1", messages: 0, newest: nil)],
            now: now
        )
        #expect(checks.isEmpty)
    }

    @Test("An account whose newest stored message is old is called quiet, not broken")
    func quietAccount() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let checks = MailDiagnostics.coverageChecks(
            accounts: [account("A1", "Stalled")],
            coverage: [coverage("A1", messages: 5, newest: old)],
            now: now
        )
        let quiet = checks.first { $0.name == "Quiet accounts" }
        #expect(quiet?.status == "warn")
        #expect(quiet?.detail.contains("Stalled (40 days)") == true)
        #expect(quiet?.detail.contains("a signal to look, not a verdict") == true)
    }

    @Test("A recently active account raises nothing")
    func activeAccount() {
        let now = Date()
        let checks = MailDiagnostics.coverageChecks(
            accounts: [account("A1", "Work")],
            coverage: [coverage("A1", messages: 5, newest: now.addingTimeInterval(-3_600))],
            now: now
        )
        #expect(checks.isEmpty)
    }

    @Test("No coverage at all produces no per-account checks")
    func noCoverage() {
        #expect(
            MailDiagnostics.coverageChecks(
                accounts: [account("A1", "Work")],
                coverage: [],
                now: Date()
            ).isEmpty
        )
    }
}
