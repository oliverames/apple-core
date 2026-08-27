import Foundation
import Testing

@Suite("LaunchAgent manager")
struct LaunchAgentManagerTests {
    @Test("Bootstrap clears a persistent disabled override before loading")
    func bootstrapEnablesServiceFirst() {
        var commands: [[String]] = []
        let result = LaunchAgentManager.bootstrap(
            label: "com.example.test-agent",
            uid: 501,
            plistURL: URL(fileURLWithPath: "/tmp/com.example.test-agent.plist"),
            attempts: 1,
            run: { executable, arguments in
                commands.append([executable] + arguments)
                return (Int32(0), "", "")
            }
        )

        #expect(result.succeeded)
        #expect(
            commands == [
                ["/bin/launchctl", "enable", "gui/501/com.example.test-agent"],
                ["/bin/launchctl", "bootstrap", "gui/501", "/tmp/com.example.test-agent.plist"],
            ]
        )
    }

    @Test("A failed enable probe does not hide a successful bootstrap")
    func bootstrapStillAttemptsLoadAfterEnableFailure() {
        var commands: [[String]] = []
        let result = LaunchAgentManager.bootstrap(
            label: "com.example.test-agent",
            uid: 501,
            plistURL: URL(fileURLWithPath: "/tmp/com.example.test-agent.plist"),
            attempts: 1,
            run: { executable, arguments in
                commands.append([executable] + arguments)
                if arguments.first == "enable" {
                    return (Int32(1), "", "enable failed")
                }
                return (Int32(0), "", "")
            }
        )

        #expect(result.succeeded)
        #expect(
            commands == [
                ["/bin/launchctl", "enable", "gui/501/com.example.test-agent"],
                ["/bin/launchctl", "bootstrap", "gui/501", "/tmp/com.example.test-agent.plist"],
            ]
        )
    }

    @Test("Restart stops when launchctl cannot unload the existing job")
    func restartDoesNotHideBootoutFailure() {
        var commands: [[String]] = []
        let result = LaunchAgentManager.restart(
            label: "com.example.test-agent",
            uid: 501,
            plistURL: URL(fileURLWithPath: "/tmp/com.example.test-agent.plist")
        ) { executable, arguments in
            commands.append([executable] + arguments)
            if arguments.first == "print" {
                return (0, "", "")
            }
            if arguments.first == "bootout" {
                return (5, "", "Operation not permitted")
            }
            return (0, "", "")
        }

        #expect(result.status == 5)
        #expect(result.stderr == "Operation not permitted")
        #expect(!commands.contains(where: { $0.contains("bootstrap") }))
    }
}
