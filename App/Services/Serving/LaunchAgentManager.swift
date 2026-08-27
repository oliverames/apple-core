// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from Bridgeport's LaunchAgentManager.swift verbatim. This file has
// no Bridgeport-specific naming; it is a generic launchctl wrapper.

import Foundation

typealias LaunchAgentShellRunner = (_ executable: String, _ arguments: [String]) -> (
    status: Int32, stdout: String, stderr: String
)

public struct LaunchAgentCommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool {
        status == 0
    }
}

public enum LaunchAgentManager {
    /// Returns the executable path the LaunchAgent should run.
    ///
    /// A binary inside an .app bundle must run in place: TCC attributes
    /// Apple Events and other privacy consent to the signed bundle, and a
    /// bare copy elsewhere is silently denied automation with no prompt.
    /// Bare binaries (swift run, .build products) return nil.
    public static func bundleExecutablePath(for currentExecPath: String) -> String? {
        let standardized = URL(fileURLWithPath: currentExecPath).standardizedFileURL.path
        return standardized.contains(".app/Contents/MacOS/") ? standardized : nil
    }

    public static func isLoaded(label: String, uid: UInt32) -> Bool {
        isLoaded(label: label, uid: uid, run: runShell)
    }

    static func isLoaded(label: String, uid: UInt32, run: LaunchAgentShellRunner) -> Bool {
        let result = run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        return result.status == 0
    }

    /// Async variants for actor contexts: launchctl blocks its caller for
    /// the whole round trip, so awaiting these suspends the actor instead of
    /// pinning a cooperative-pool worker (or the main thread).
    public static func isLoadedAsync(label: String, uid: UInt32) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            isLoaded(label: label, uid: uid)
        }.value
    }

    @discardableResult
    public static func bootstrapAsync(
        label: String,
        uid: UInt32,
        plistURL: URL,
        attempts: Int = 5
    ) async -> LaunchAgentCommandResult {
        await Task.detached(priority: .userInitiated) {
            bootstrap(label: label, uid: uid, plistURL: plistURL, attempts: attempts)
        }.value
    }

    @discardableResult
    public static func bootoutAsync(label: String, uid: UInt32, plistURL: URL?) async
        -> LaunchAgentCommandResult
    {
        await Task.detached(priority: .userInitiated) {
            bootout(label: label, uid: uid, plistURL: plistURL)
        }.value
    }

    @discardableResult
    public static func bootout(label: String, uid: UInt32, plistURL: URL? = nil) -> LaunchAgentCommandResult {
        bootout(label: label, uid: uid, plistURL: plistURL, run: runShell)
    }

    static func bootout(
        label: String,
        uid: UInt32,
        plistURL: URL? = nil,
        run: LaunchAgentShellRunner
    ) -> LaunchAgentCommandResult {
        let labelResult = commandResult(run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]))
        if labelResult.succeeded {
            waitUntilUnloaded(label: label, uid: uid, run: run)
            return labelResult
        }

        guard let plistURL else {
            return labelResult
        }

        let plistResult = commandResult(run("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path]))
        if plistResult.succeeded {
            waitUntilUnloaded(label: label, uid: uid, run: run)
            return plistResult
        }

        return labelResult
    }

    @discardableResult
    public static func bootstrap(label: String, uid: UInt32, plistURL: URL, attempts: Int = 5)
        -> LaunchAgentCommandResult
    {
        bootstrap(label: label, uid: uid, plistURL: plistURL, attempts: attempts, run: runShell)
    }

    static func bootstrap(
        label: String,
        uid: UInt32,
        plistURL: URL,
        attempts: Int = 5,
        run: LaunchAgentShellRunner
    ) -> LaunchAgentCommandResult {
        let clampedAttempts = max(1, attempts)
        var lastResult = LaunchAgentCommandResult(
            status: -1,
            stdout: "",
            stderr: "launchctl bootstrap was not attempted"
        )

        // `launchctl disable` persists across boots and prevents bootstrap
        // from loading the job at all. The app's enabled configuration is the
        // source of truth here, so clear any stale override before loading it.
        _ = run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])

        for attempt in 0 ..< clampedAttempts {
            let result = commandResult(run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path]))
            lastResult = result

            if result.succeeded || isLoaded(label: label, uid: uid, run: run)
                || result.stderr.localizedCaseInsensitiveContains("service is already loaded")
            {
                return LaunchAgentCommandResult(status: 0, stdout: result.stdout, stderr: result.stderr)
            }

            if attempt < clampedAttempts - 1 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        return lastResult
    }

    @discardableResult
    public static func restart(label: String, uid: UInt32, plistURL: URL) -> LaunchAgentCommandResult {
        restart(label: label, uid: uid, plistURL: plistURL, run: runShell)
    }

    static func restart(
        label: String,
        uid: UInt32,
        plistURL: URL,
        run: LaunchAgentShellRunner
    ) -> LaunchAgentCommandResult {
        if isLoaded(label: label, uid: uid, run: run) {
            let bootoutResult = bootout(label: label, uid: uid, plistURL: plistURL, run: run)
            if isLoaded(label: label, uid: uid, run: run) {
                if !bootoutResult.succeeded {
                    return bootoutResult
                }
                return LaunchAgentCommandResult(
                    status: -1,
                    stdout: bootoutResult.stdout,
                    stderr: "launchctl reported success, but \(label) is still loaded"
                )
            }
        }
        return bootstrap(label: label, uid: uid, plistURL: plistURL, run: run)
    }

    private static func commandResult(_ result: (status: Int32, stdout: String, stderr: String))
        -> LaunchAgentCommandResult
    {
        LaunchAgentCommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    private static func waitUntilUnloaded(label: String, uid: UInt32, run: LaunchAgentShellRunner = runShell) {
        for attempt in 0 ..< 5 {
            if !isLoaded(label: label, uid: uid, run: run) {
                return
            }

            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
