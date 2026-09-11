// SPDX-License-Identifier: GPL-3.0-or-later
//
// What is actually wrong when a shortcut does not run.
//
// The `shortcuts` CLI reports almost everything as a non-zero exit with a
// sentence on stderr, so "it failed" is all a caller learns today, and the
// four things that go wrong need four different responses: the tool is
// missing, macOS refused access, the input was not something the shortcut
// could accept, or the shortcut ran and produced nothing usable. This file
// turns raw probe results into those distinctions.
//
// It runs no processes. The service performs the probes and hands the
// outcomes here, so the classification can be tested against fabricated
// stderr instead of by breaking a real Shortcuts installation.

import Foundation

/// Why a shortcuts operation failed, in the four shapes that call for four
/// different responses.
public enum ShortcutsFailureKind: String, Sendable, Equatable {
    /// The CLI itself is missing or not executable.
    case unavailable
    /// macOS refused: Automation or Shortcuts access is not granted.
    case permissionDenied
    /// The shortcut exists but rejected or could not use its input.
    case inputRejected
    /// The shortcut ran but produced no usable output.
    case outputMissing
    /// The shortcut did not finish inside its bound, which usually means it
    /// is waiting for someone to answer a prompt.
    case timedOut
    /// The shortcut itself reported an error.
    case shortcutError
    /// Something else. Reported as unknown rather than guessed at.
    case unknown
}

/// A check's result, kept separate from why it failed.
public enum ShortcutsCheckState: String, Sendable, Equatable {
    case passed
    case failed
    /// The check could not run because something it depends on is missing.
    /// Not a failure of the thing being checked.
    case skipped
    /// Nothing to check: no diagnostic fixture, or no shared folders.
    case notConfigured
}

public struct ShortcutsCheck: Sendable, Equatable {
    public let name: String
    public let state: ShortcutsCheckState
    public let detail: String
    public let failure: ShortcutsFailureKind?
    /// What to do about it, or nil when there is nothing to do.
    public let advice: String?

    public init(
        name: String,
        state: ShortcutsCheckState,
        detail: String,
        failure: ShortcutsFailureKind? = nil,
        advice: String? = nil
    ) {
        self.name = name
        self.state = state
        self.detail = detail
        self.failure = failure
        self.advice = advice
    }
}

public enum ShortcutsHealthState: String, Sendable, Equatable {
    /// Everything that could be checked worked.
    case ready
    /// The core operations work but something optional is missing or broken.
    case degraded
    /// Nothing will work until this is fixed.
    case blocked
}

public struct ShortcutsHealthReport: Sendable, Equatable {
    public let state: ShortcutsHealthState
    public let summary: String
    public let checks: [ShortcutsCheck]

    public init(state: ShortcutsHealthState, summary: String, checks: [ShortcutsCheck]) {
        self.state = state
        self.summary = summary
        self.checks = checks
    }
}

/// One folder the file input and output arguments can reach.
public struct ShortcutsFolderProbe: Sendable, Equatable {
    public let path: String
    public let exists: Bool
    public let readable: Bool
    /// Whether the share is configured to allow writing, regardless of
    /// whether the folder is reachable at all.
    public let writeAllowed: Bool
    public let writable: Bool

    public init(path: String, exists: Bool, readable: Bool, writeAllowed: Bool, writable: Bool) {
        self.path = path
        self.exists = exists
        self.readable = readable
        self.writeAllowed = writeAllowed
        self.writable = writable
    }
}

/// What running the diagnostic fixture produced.
public struct ShortcutsFixtureProbe: Sendable, Equatable {
    public let name: String
    public let existed: Bool
    public let ran: Bool
    public let timedOut: Bool
    public let exitStatus: Int32?
    public let standardError: String
    /// What came back, so a round trip can be checked rather than assumed.
    public let output: String?
    /// What was sent in, when the fixture was given text.
    public let input: String?

    public init(
        name: String,
        existed: Bool,
        ran: Bool = false,
        timedOut: Bool = false,
        exitStatus: Int32? = nil,
        standardError: String = "",
        output: String? = nil,
        input: String? = nil
    ) {
        self.name = name
        self.existed = existed
        self.ran = ran
        self.timedOut = timedOut
        self.exitStatus = exitStatus
        self.standardError = standardError
        self.output = output
        self.input = input
    }
}

public enum ShortcutsHealth {
    /// The reserved name of the harmless fixture. A diagnostic must never run
    /// one of the user's own shortcuts: those send mail, toggle lights and
    /// spend money. Only a shortcut created for this purpose is run, and only
    /// when its name matches exactly.
    public static let fixtureName = "Apple Core Diagnostic"

    public static let fixtureInstructions =
        "Create a shortcut named \"\(fixtureName)\" that accepts text input and returns it unchanged "
        + "(Receive Text input, then Stop and Output the Shortcut Input). It must have no side effects "
        + "and must not ask anything, because the diagnostic runs it."

    /// Reads the CLI's stderr for the distinction it does not make itself.
    public static func classify(standardError: String, exitStatus: Int32?) -> ShortcutsFailureKind {
        let text = standardError.lowercased()
        if text.contains("not permitted") || text.contains("permission")
            || text.contains("not authorized") || text.contains("denied")
            || text.contains("tccd") || text.contains("privacy")
        {
            return .permissionDenied
        }
        if text.contains("couldn't be opened") || text.contains("no such file")
            || text.contains("input") && (text.contains("invalid") || text.contains("could not"))
        {
            return .inputRejected
        }
        if text.contains("no shortcut") || text.contains("couldn't find")
            || text.contains("not found")
        {
            return .inputRejected
        }
        if exitStatus == nil { return .unknown }
        if standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return exitStatus == 0 ? .unknown : .shortcutError
        }
        return .shortcutError
    }

    public static func advice(for failure: ShortcutsFailureKind) -> String {
        switch failure {
        case .unavailable:
            return
                "The shortcuts command-line tool is part of macOS. If it is missing, the Shortcuts app "
                + "is not installed or this account cannot reach it, and no shortcut tool will work."
        case .permissionDenied:
            return
                "Grant Apple Core access under System Settings > Privacy & Security > Automation, and "
                + "check Shortcuts is allowed to run without asking."
        case .inputRejected:
            return
                "Check the shortcut name or identifier, and that any input file is inside a folder "
                + "shared with Apple Core."
        case .outputMissing:
            return
                "The shortcut finished without returning anything. Add a final \"Stop and Output\" "
                + "action, or write the result to outputPath."
        case .timedOut:
            return
                "The shortcut did not finish. Interactive shortcuts, which ask a question or show a "
                + "dialog, never finish when run this way; remove the interactive steps."
        case .shortcutError:
            return "The shortcut itself reported an error. Open it in Shortcuts to see which action failed."
        case .unknown:
            return "Run the shortcut in the Shortcuts app to see what it does there."
        }
    }

    /// Builds the report from the probes the service performed.
    public static func report(
        executableAvailable: Bool,
        executablePath: String,
        listing: Result<Int, ShortcutsProbeFailure>,
        fixture: ShortcutsFixtureProbe?,
        folders: [ShortcutsFolderProbe]
    ) -> ShortcutsHealthReport {
        var checks: [ShortcutsCheck] = []

        checks.append(
            ShortcutsCheck(
                name: "availability",
                state: executableAvailable ? .passed : .failed,
                detail: executableAvailable
                    ? "\(executablePath) is present and executable."
                    : "\(executablePath) is missing or not executable.",
                failure: executableAvailable ? nil : .unavailable,
                advice: executableAvailable ? nil : advice(for: .unavailable)
            )
        )

        guard executableAvailable else {
            return ShortcutsHealthReport(
                state: .blocked,
                summary: "The shortcuts command-line tool is unavailable, so no shortcut tool can work.",
                checks: checks
                    + [
                        ShortcutsCheck(
                            name: "listing",
                            state: .skipped,
                            detail: "Not attempted: the command-line tool is unavailable."
                        )
                    ]
            )
        }

        var blocked = false
        switch listing {
        case .success(let count):
            checks.append(
                ShortcutsCheck(
                    name: "listing",
                    state: .passed,
                    detail: "Listed \(count) shortcut(s), so reading the library works."
                )
            )
        case .failure(let failure):
            let kind = classify(standardError: failure.standardError, exitStatus: failure.exitStatus)
            blocked = true
            checks.append(
                ShortcutsCheck(
                    name: "listing",
                    state: .failed,
                    detail: failure.standardError.isEmpty
                        ? "Listing shortcuts failed." : "Listing shortcuts failed: \(failure.standardError)",
                    failure: kind,
                    advice: advice(for: kind)
                )
            )
        }

        var degraded = false
        if let fixture {
            let check = fixtureCheck(fixture)
            // An unverified run is not a healthy one: "ready" has to mean the
            // diagnostic actually ran, not that nothing objected.
            if check.state != .passed { degraded = true }
            checks.append(check)
        } else {
            degraded = true
            checks.append(
                ShortcutsCheck(
                    name: "run",
                    state: .notConfigured,
                    detail:
                        "No diagnostic fixture was run, so running, input and output are unverified.",
                    advice: fixtureInstructions
                )
            )
        }

        if folders.isEmpty {
            checks.append(
                ShortcutsCheck(
                    name: "sharedFolders",
                    state: .notConfigured,
                    detail:
                        "No folders are shared with Apple Core, so inputPath and outputPath cannot be used. "
                        + "Text input and text output still work.",
                    advice: "Share a folder in Apple Core's settings to pass files to shortcuts."
                )
            )
        } else {
            let unreachable = folders.filter { !$0.exists || !$0.readable }
            let unwritable = folders.filter { $0.writeAllowed && $0.exists && !$0.writable }
            if unreachable.isEmpty, unwritable.isEmpty {
                checks.append(
                    ShortcutsCheck(
                        name: "sharedFolders",
                        state: .passed,
                        detail: "All \(folders.count) shared folder(s) are reachable."
                    )
                )
            } else {
                degraded = true
                var problems: [String] = []
                if !unreachable.isEmpty {
                    problems.append(
                        "unreachable: " + unreachable.map(\.path).joined(separator: ", ")
                    )
                }
                if !unwritable.isEmpty {
                    problems.append(
                        "shared for writing but not writable: "
                            + unwritable.map(\.path).joined(separator: ", ")
                    )
                }
                checks.append(
                    ShortcutsCheck(
                        name: "sharedFolders",
                        state: .failed,
                        detail: problems.joined(separator: "; "),
                        failure: .inputRejected,
                        advice:
                            "A shared folder that has moved, been renamed, or lives on an unmounted volume "
                            + "will fail every inputPath and outputPath that uses it."
                    )
                )
            }
        }

        let state: ShortcutsHealthState = blocked ? .blocked : (degraded ? .degraded : .ready)
        let summary: String
        switch state {
        case .ready:
            summary = "Shortcuts is working: the library can be listed, and the diagnostic ran and returned its input."
        case .degraded:
            summary =
                "Shortcuts can be listed and run, but at least one check could not be completed. "
                + "See each check for what is missing."
        case .blocked:
            summary = "Shortcuts is not usable right now. See the failed check for what to fix."
        }
        return ShortcutsHealthReport(state: state, summary: summary, checks: checks)
    }

    private static func fixtureCheck(_ fixture: ShortcutsFixtureProbe) -> ShortcutsCheck {
        guard fixture.existed else {
            return ShortcutsCheck(
                name: "run",
                state: .notConfigured,
                detail:
                    "No shortcut named \"\(fixture.name)\" exists, so running, input and output are "
                    + "unverified. Only this exact name is ever run, so that a diagnostic never "
                    + "triggers one of your own shortcuts.",
                advice: fixtureInstructions
            )
        }
        if fixture.timedOut {
            return ShortcutsCheck(
                name: "run",
                state: .failed,
                detail: "\"\(fixture.name)\" did not finish inside the diagnostic's time limit.",
                failure: .timedOut,
                advice: advice(for: .timedOut)
            )
        }
        if let status = fixture.exitStatus, status != 0 {
            let kind = classify(standardError: fixture.standardError, exitStatus: status)
            return ShortcutsCheck(
                name: "run",
                state: .failed,
                detail: "\"\(fixture.name)\" exited with status \(status): \(fixture.standardError)",
                failure: kind,
                advice: advice(for: kind)
            )
        }
        guard let output = fixture.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ShortcutsCheck(
                name: "run",
                state: .failed,
                detail: "\"\(fixture.name)\" ran and produced no output.",
                failure: .outputMissing,
                advice: advice(for: .outputMissing)
            )
        }
        if let input = fixture.input,
            !output.contains(input.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            // Succeeding silently, with output that is not what went in, is
            // the failure this check exists to catch.
            return ShortcutsCheck(
                name: "run",
                state: .failed,
                detail:
                    "\"\(fixture.name)\" ran but returned something other than its input, so text input "
                    + "and output cannot both be relied on.",
                failure: .outputMissing,
                advice: fixtureInstructions
            )
        }
        return ShortcutsCheck(
            name: "run",
            state: .passed,
            detail: "\"\(fixture.name)\" ran and returned its input, so running, text input and text output all work."
        )
    }
}

/// A probe that failed, as the service observed it.
public struct ShortcutsProbeFailure: Sendable, Equatable, Error {
    public let exitStatus: Int32?
    public let standardError: String

    public init(exitStatus: Int32?, standardError: String) {
        self.exitStatus = exitStatus
        self.standardError = standardError
    }
}
