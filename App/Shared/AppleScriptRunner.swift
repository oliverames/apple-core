// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

private let log = Logger.service("applescript")

/// Runs AppleScript or JXA via `osascript` with the script supplied on
/// stdin (never `-e` arguments) and user-supplied values passed as argv,
/// so untrusted text is never concatenated into script source.
///
/// Design per docs/planning/BUILD_PLAN.md §3.5: typed errors mapped from
/// stderr (permission denied / app not running / not found), and a hard
/// timeout because Apple Events calls can hang indefinitely.
///
/// Shared by NotesService and MailService.
actor AppleScriptRunner {
    static let shared = AppleScriptRunner()

    enum Language: Sendable {
        case appleScript
        case jxa

        var osascriptFlag: String {
            switch self {
            case .appleScript: return "AppleScript"
            case .jxa: return "JavaScript"
            }
        }
    }

    enum RunnerError: LocalizedError {
        case permissionDenied
        case appNotRunning
        case notFound(detail: String)
        case timeout(seconds: TimeInterval)
        case failed(stderr: String, exitCode: Int32)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return
                    "PERMISSION_DENIED: Automation access was denied. Grant access in System Settings > Privacy & Security > Automation."
            case .appNotRunning:
                return "APP_NOT_RUNNING: The target application is not running and could not be launched."
            case .notFound(let detail):
                return "NOT_FOUND: \(detail)"
            case .timeout(let seconds):
                return "Script timed out after \(Int(seconds)) seconds"
            case .failed(let stderr, let exitCode):
                return "osascript failed (exit \(exitCode)): \(stderr)"
            case .invalidOutput:
                return "Script produced output that could not be decoded"
            }
        }
    }

    /// Runs a script and returns trimmed stdout.
    ///
    /// - Parameters:
    ///   - language: AppleScript or JXA.
    ///   - script: Constant script source. Must read user input from
    ///     `argv` (`on run argv` / `function run(argv)`), never via
    ///     string interpolation.
    ///   - arguments: User-supplied values, passed as argv.
    func run(
        _ language: Language,
        script: String,
        arguments: [String] = [],
        timeout: TimeInterval = 30
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", language.osascriptFlag, "-"] + arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        defer {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
        }

        try process.run()

        let stdinHandle = stdinPipe.fileHandleForWriting
        try stdinHandle.write(contentsOf: Data(script.utf8))
        try stdinHandle.close()

        // Drain output concurrently so a large payload can't fill the pipe
        // buffer and deadlock the child process before termination.
        let stdoutTask = Task.detached {
            (try? stdoutHandle.readToEnd()) ?? Data()
        }
        let stderrTask = Task.detached {
            (try? stderrHandle.readToEnd()) ?? Data()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await process.waitUntilTermination()
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    process.terminate()
                    throw RunnerError.timeout(seconds: timeout)
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            log.error("osascript run failed: \(error.localizedDescription)")
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            log.error(
                "osascript exited \(process.terminationStatus): \(stderr, privacy: .public)"
            )
            throw Self.mapError(stderr: stderr, exitCode: process.terminationStatus)
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a script whose stdout is JSON and decodes it.
    func runJSON<T: Decodable & Sendable>(
        _ language: Language,
        script: String,
        arguments: [String] = [],
        as type: T.Type,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let output = try await run(
            language,
            script: script,
            arguments: arguments,
            timeout: timeout
        )

        guard let data = output.data(using: .utf8), !output.isEmpty else {
            throw RunnerError.invalidOutput
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    /// Maps known osascript stderr patterns to typed errors.
    private static func mapError(stderr: String, exitCode: Int32) -> RunnerError {
        // -1743: "Not authorized to send Apple events" (TCC denial).
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
            return .permissionDenied
        }
        // -600: application isn't running; -609: connection is invalid.
        if stderr.contains("-600") || stderr.contains("-609")
            || stderr.localizedCaseInsensitiveContains("isn't running")
        {
            return .appNotRunning
        }
        // -1728: can't get object (missing note, folder, mailbox, message).
        if stderr.contains("-1728")
            || stderr.localizedCaseInsensitiveContains("can't get")
            || stderr.localizedCaseInsensitiveContains("Error: NOT_FOUND")
        {
            return .notFound(detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .failed(
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: exitCode
        )
    }
}

extension Process {
    /// Awaits process termination via the termination handler, mirroring
    /// the pattern in `ShortcutsService.runProcess`.
    fileprivate func waitUntilTermination() async {
        await withCheckedContinuation { continuation in
            self.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }
}
