import AppKit
import Testing

@MainActor
@Suite("Connection approval window controller")
struct ConnectionApprovalWindowControllerTests {
    @Test("Approval callback can present the next queued request")
    func approvalReentrancyKeepsNextWindow() {
        _ = NSApplication.shared
        let controller = ConnectionApprovalWindowController()
        controller.showApprovalWindow(
            clientName: "First",
            onApprove: { _ in
                controller.showApprovalWindow(
                    clientName: "Second",
                    onApprove: { _ in },
                    onDeny: {}
                )
            },
            onDeny: {}
        )

        #expect(controller.resolveVisibleDialogAsApproved(clientName: "First", alwaysTrust: false))
        #expect(controller.visibleClientName == "Second")
        #expect(controller.resolveVisibleDialogAsDenied(clientName: "Second"))
    }

    @Test("Denial callback can present the next queued request")
    func denialReentrancyKeepsNextWindow() {
        _ = NSApplication.shared
        let controller = ConnectionApprovalWindowController()
        controller.showApprovalWindow(
            clientName: "First",
            onApprove: { _ in },
            onDeny: {
                controller.showApprovalWindow(
                    clientName: "Second",
                    onApprove: { _ in },
                    onDeny: {}
                )
            }
        )

        #expect(controller.resolveVisibleDialogAsDenied(clientName: "First"))
        #expect(controller.visibleClientName == "Second")
        #expect(controller.resolveVisibleDialogAsDenied(clientName: "Second"))
    }
}
