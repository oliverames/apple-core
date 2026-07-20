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
