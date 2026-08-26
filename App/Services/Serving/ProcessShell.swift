// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported verbatim from Bridgeport's top-level `runShell` helper in
// bridgeport.swift. Used by LaunchAgentManager and CloudflareManager to
// shell out to launchctl / cloudflared.

import Foundation
#if os(macOS)
    import Darwin
#endif

@discardableResult
func runShell(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()

        // Drain stderr on a background thread so a child that fills the
        // stderr pipe buffer before closing stdout cannot deadlock us.
        nonisolated(unsafe) var stderrData = Data()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDrained.leave()
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()

        process.waitUntilExit()

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        return (
            process.terminationStatus,
            stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines),
            stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    } catch {
        return (-1, "", error.localizedDescription)
    }
}

/// Runs `runShell` off the cooperative thread pool. cloudflared list/create/
/// route round trips take seconds of wall time each; an actor that called
/// the blocking variant directly pinned a pool worker for all of it and
/// starved every other task in the process, including live HTTP handlers.
/// Await this instead so the actor suspends while the child runs.
func runShellAsync(_ executable: String, _ arguments: [String]) async -> (status: Int32, stdout: String, stderr: String)
{
    await Task.detached(priority: .userInitiated) {
        runShell(executable, arguments)
    }.value
}

/// Starts a child process without waiting for it to exit. Used for
/// `cloudflared tunnel login`, which opens a browser and blocks until the
/// person finishes authorizing — waiting on that inside an actor would hang
/// the Settings window for as long as the browser stayed open. Returns an
/// error description when the process could not be started at all.
@discardableResult
func runShellDetached(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    // Foundation reaps a child only when someone waits on it. Dropping the
    // process on the floor left one zombie per login attempt parented to the
    // app until quit; the handler keeps a reference alive so the child is
    // reaped when it exits after the browser round trip.
    process.terminationHandler = { _ in }

    do {
        try process.run()
        return nil
    } catch {
        return error.localizedDescription
    }
}
