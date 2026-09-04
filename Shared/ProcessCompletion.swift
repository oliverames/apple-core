// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum ProcessCompletion {
    /// Wait for a launched child without letting task cancellation strand it.
    /// A child that ignores SIGTERM receives SIGKILL after a short grace period.
    static func wait(for process: Process, timeout: Duration) async throws -> Bool {
        try await withTaskCancellationHandler {
            let exited = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { _ in continuation.resume() }
                    }
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return false
                }
                let exited = try await group.next() ?? false
                if !exited { terminate(process) }
                group.cancelAll()
                return exited
            }
            try Task.checkCancellation()
            return exited
        } onCancel: {
            terminate(process)
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
