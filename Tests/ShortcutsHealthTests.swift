// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// The point of the diagnostic is that four different failures get four
/// different answers, so each one is tested from fabricated probe results.
/// No shortcut is run here, and no CLI is invoked.
@Suite("Shortcuts health")
struct ShortcutsHealthTests {
    static func check(_ report: ShortcutsHealthReport, _ name: String) throws -> ShortcutsCheck {
        try #require(report.checks.first { $0.name == name })
    }

    static let workingFixture = ShortcutsFixtureProbe(
        name: ShortcutsHealth.fixtureName,
        existed: true,
        ran: true,
        exitStatus: 0,
        output: "token-1234\n",
        input: "token-1234"
    )

    static func report(
        executableAvailable: Bool = true,
        listing: Result<Int, ShortcutsProbeFailure> = .success(12),
        fixture: ShortcutsFixtureProbe? = workingFixture,
        folders: [ShortcutsFolderProbe] = [
            ShortcutsFolderProbe(
                path: "/Users/someone/Shared",
                exists: true,
                readable: true,
                writeAllowed: true,
                writable: true
            )
        ]
    ) -> ShortcutsHealthReport {
        ShortcutsHealth.report(
            executableAvailable: executableAvailable,
            executablePath: "/usr/bin/shortcuts",
            listing: listing,
            fixture: fixture,
            folders: folders
        )
    }

    // MARK: Availability

    @Test("A missing command-line tool blocks everything and skips the rest")
    func missingExecutable() throws {
        let report = Self.report(executableAvailable: false)
        #expect(report.state == .blocked)
        #expect(try Self.check(report, "availability").failure == .unavailable)
        #expect(try Self.check(report, "listing").state == .skipped)
    }

    @Test("A healthy Mac reports ready")
    func healthy() throws {
        let report = Self.report()
        #expect(report.state == .ready)
        #expect(report.checks.allSatisfy { $0.state == .passed })
    }

    // MARK: Permission

    @Test("A refusal from macOS is reported as a permission failure, not a shortcut error")
    func permissionDenied() throws {
        let report = Self.report(
            listing: .failure(
                ShortcutsProbeFailure(
                    exitStatus: 1,
                    standardError: "The operation couldn't be completed. Not permitted"
                )
            )
        )
        #expect(report.state == .blocked)
        let listing = try Self.check(report, "listing")
        #expect(listing.failure == .permissionDenied)
        #expect(listing.advice?.contains("Automation") == true)
    }

    @Test("Classification separates permission, input and shortcut errors")
    func classification() {
        #expect(
            ShortcutsHealth.classify(standardError: "Privacy access denied", exitStatus: 1)
                == .permissionDenied
        )
        #expect(
            ShortcutsHealth.classify(standardError: "No shortcut named \"Nope\"", exitStatus: 1)
                == .inputRejected
        )
        #expect(
            ShortcutsHealth.classify(standardError: "The file couldn't be opened", exitStatus: 1)
                == .inputRejected
        )
        #expect(
            ShortcutsHealth.classify(standardError: "Action failed at step 3", exitStatus: 2)
                == .shortcutError
        )
        #expect(ShortcutsHealth.classify(standardError: "", exitStatus: nil) == .unknown)
    }

    // MARK: Fixture behavior

    @Test("An interactive shortcut that never finishes is reported as a timeout")
    func timeout() throws {
        let report = Self.report(
            fixture: ShortcutsFixtureProbe(
                name: ShortcutsHealth.fixtureName,
                existed: true,
                ran: true,
                timedOut: true
            )
        )
        let run = try Self.check(report, "run")
        #expect(run.failure == .timedOut)
        #expect(run.advice?.contains("Interactive") == true)
        // A broken fixture degrades the report; it does not block listing and running.
        #expect(report.state == .degraded)
    }

    @Test("Silent success with no output is a failure, not a pass")
    func silentSuccess() throws {
        let report = Self.report(
            fixture: ShortcutsFixtureProbe(
                name: ShortcutsHealth.fixtureName,
                existed: true,
                ran: true,
                exitStatus: 0,
                output: nil,
                input: "token"
            )
        )
        #expect(try Self.check(report, "run").failure == .outputMissing)
    }

    @Test("Output that is not what went in fails the round trip")
    func wrongOutput() throws {
        let report = Self.report(
            fixture: ShortcutsFixtureProbe(
                name: ShortcutsHealth.fixtureName,
                existed: true,
                ran: true,
                exitStatus: 0,
                output: "something else entirely",
                input: "token-1234"
            )
        )
        let run = try Self.check(report, "run")
        #expect(run.state == .failed)
        #expect(run.failure == .outputMissing)
    }

    @Test("Binary output still counts as output, as long as something came back")
    func binaryOutput() throws {
        // The fixture writes its file; the diagnostic reads it as text. Data
        // that decodes to something non-empty passes without being inspected.
        let report = Self.report(
            fixture: ShortcutsFixtureProbe(
                name: ShortcutsHealth.fixtureName,
                existed: true,
                ran: true,
                exitStatus: 0,
                output: "\u{FFFD}PNG token-1234 binary",
                input: "token-1234"
            )
        )
        #expect(try Self.check(report, "run").state == .passed)
    }

    @Test("A missing fixture is not configured rather than failed, and says how to make one")
    func missingFixture() throws {
        let report = Self.report(
            fixture: ShortcutsFixtureProbe(name: ShortcutsHealth.fixtureName, existed: false)
        )
        let run = try Self.check(report, "run")
        #expect(run.state == .notConfigured)
        #expect(run.advice == ShortcutsHealth.fixtureInstructions)
        #expect(report.state == .degraded)
        // The name is reserved so that a diagnostic never runs the user's own
        // shortcuts, which is the whole safety property of this check.
        #expect(run.detail.contains("Only this exact name is ever run"))
    }

    @Test("Skipping the fixture leaves running unverified rather than claiming health")
    func fixtureNotRun() throws {
        let report = Self.report(fixture: nil)
        #expect(try Self.check(report, "run").state == .notConfigured)
        #expect(report.state == .degraded)
    }

    // MARK: Shared folders

    @Test("A shared folder that has gone away is reported, with why it matters")
    func inaccessibleFolder() throws {
        let report = Self.report(
            folders: [
                ShortcutsFolderProbe(
                    path: "/Volumes/Archive/Shared",
                    exists: false,
                    readable: false,
                    writeAllowed: false,
                    writable: false
                )
            ]
        )
        let folders = try Self.check(report, "sharedFolders")
        #expect(folders.state == .failed)
        #expect(folders.detail.contains("/Volumes/Archive/Shared"))
        #expect(report.state == .degraded)
    }

    @Test("A folder shared for writing that is not writable is reported separately")
    func readOnlyFolder() throws {
        let report = Self.report(
            folders: [
                ShortcutsFolderProbe(
                    path: "/Users/someone/Locked",
                    exists: true,
                    readable: true,
                    writeAllowed: true,
                    writable: false
                )
            ]
        )
        #expect(try Self.check(report, "sharedFolders").detail.contains("not writable"))
    }

    @Test("No shared folders is a note, not a failure: text input still works")
    func noFolders() throws {
        let report = Self.report(folders: [])
        let folders = try Self.check(report, "sharedFolders")
        #expect(folders.state == .notConfigured)
        #expect(folders.detail.contains("Text input and text output still work"))
    }
}
