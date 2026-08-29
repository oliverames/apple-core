// SPDX-License-Identifier: GPL-3.0-or-later
//
// Client connection approval window. Rebuilt around Bridgeport's design
// language (bridgeport/Sources/bridgeport/Views/SettingsView.swift: the
// ProductHeader/SettingsGroup card treatment and callout/secondary text
// hierarchy), replacing the iMCP-inherited dialog. The window controller
// keeps the same showApprovalWindow(clientName:onApprove:onDeny:) API that
// ServerController already calls.

import AppKit
import SwiftUI

struct ConnectionApprovalView: View {
    let clientName: String
    let authenticationDetail: String
    let canAlwaysTrust: Bool
    /// Worded per principal: an OAuth client is one identifiable client,
    /// whereas trusting the shared token trusts anything holding it. The
    /// checkbox has to say which of those the user is agreeing to.
    let alwaysTrustTitle: String
    let alwaysTrustDetail: String
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    @State private var alwaysTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Request")
                        .font(.title2.weight(.semibold))
                    Text("Allow “\(clientName)” to connect to Apple Core?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("This client will get access to every service surface you have enabled.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(authenticationDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if canAlwaysTrust {
                        Toggle(isOn: $alwaysTrust) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alwaysTrustTitle)
                                Text(alwaysTrustDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()

                Button("Deny") {
                    onDeny()
                }
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onApprove(alwaysTrust)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class ConnectionApprovalWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var currentClientName: String?
    private var pendingApprove: ((Bool) -> Void)?
    /// Fires exactly once per request: closing the window with the titlebar
    /// close button (neither Allow nor Deny clicked) must still resolve the
    /// pending connection, so it counts as a deny.
    private var pendingDeny: (() -> Void)?

    func showApprovalWindow(
        clientName: String,
        authenticationDetail: String = "Authenticated OAuth client.",
        canAlwaysTrust: Bool = true,
        alwaysTrustTitle: String = "Always trust this OAuth client",
        alwaysTrustDetail: String =
            "Trusted clients connect without asking again. Manage them in Settings › Clients.",
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        currentClientName = clientName
        pendingApprove = onApprove
        pendingDeny = onDeny
        let approvalView = ConnectionApprovalView(
            clientName: clientName,
            authenticationDetail: authenticationDetail,
            canAlwaysTrust: canAlwaysTrust,
            alwaysTrustTitle: alwaysTrustTitle,
            alwaysTrustDetail: alwaysTrustDetail,
            onApprove: { alwaysTrust in
                self.resolveVisibleDialogAsApproved(
                    clientName: clientName,
                    alwaysTrust: alwaysTrust
                )
            },
            onDeny: {
                self.resolveVisibleDialogAsDenied(clientName: clientName)
            }
        )

        let hostingController = NSHostingController(rootView: approvalView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = "Connection Request"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.tabbingMode = .disallowed
        window.center()
        window.delegate = self

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        let windowToClose = window
        window = nil
        windowToClose?.delegate = nil
        windowToClose?.close()
    }

    /// Close and clear the current request before its callback can synchronously
    /// present the next queued request. Otherwise the old request's cleanup
    /// closes the newly presented window through the shared `window` property.
    @discardableResult
    func resolveVisibleDialogAsApproved(clientName: String, alwaysTrust: Bool) -> Bool {
        guard currentClientName == clientName else { return false }
        let approve = pendingApprove
        pendingApprove = nil
        pendingDeny = nil
        currentClientName = nil
        closeWindow()
        approve?(alwaysTrust)
        return true
    }

    var visibleClientName: String? { currentClientName }

    /// Resolves the visible dialog as a denial when its connection drops
    /// before anyone answers, mirroring the Deny button exactly (callback,
    /// then close). Returns false when a different request is on screen.
    @discardableResult
    func resolveVisibleDialogAsDenied(clientName: String) -> Bool {
        guard currentClientName == clientName else { return false }
        currentClientName = nil
        let deny = pendingDeny
        pendingApprove = nil
        pendingDeny = nil
        closeWindow()
        deny?()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
            return
        }
        // Titlebar close without choosing: resolve the request as a deny.
        let deny = pendingDeny
        pendingApprove = nil
        pendingDeny = nil
        currentClientName = nil
        window = nil
        deny?()
    }
}

#Preview {
    ConnectionApprovalView(
        clientName: "Claude Desktop",
        authenticationDetail: "Authenticated OAuth client ames_example…",
        canAlwaysTrust: true,
        alwaysTrustTitle: "Always trust this OAuth client",
        alwaysTrustDetail:
            "Trusted clients connect without asking again. Manage them in Settings › Clients.",
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
}
