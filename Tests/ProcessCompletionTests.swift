import Foundation
import Testing

@Suite("Child process completion")
struct ProcessCompletionTests {
    @Test("A completed child is observed even when it exits before the wait")
    func alreadyExited() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(try await ProcessCompletion.wait(for: process, timeout: .seconds(5)))
    }

    @Test("Cancellation terminates the child before returning")
    func cancellation() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let started = ContinuousClock.now
        let task = Task { try await ProcessCompletion.wait(for: process, timeout: .seconds(60)) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!process.isRunning)
            #expect(started.duration(to: .now) < .seconds(10))
        }
    }

    @Test("A timeout also stops a child that ignores graceful termination")
    func resistantChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try process.run()
        let started = ContinuousClock.now
        #expect(try await !ProcessCompletion.wait(for: process, timeout: .milliseconds(200)))
        #expect(!process.isRunning)
        #expect(started.duration(to: .now) < .seconds(10))
    }
}
