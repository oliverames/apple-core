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

                Toggle(isOn: $alwaysTrust) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always trust this client")
                        Text("Trusted clients connect without asking again. Manage them in Settings › Security.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
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
    /// Fires exactly once per request: closing the window with the titlebar
    /// close button (neither Allow nor Deny clicked) must still resolve the
    /// pending connection, so it counts as a deny.
    private var pendingDeny: (() -> Void)?

    func showApprovalWindow(
        clientName: String,
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        pendingDeny = onDeny
        let approvalView = ConnectionApprovalView(
            clientName: clientName,
            onApprove: { alwaysTrust in
                self.pendingDeny = nil
                onApprove(alwaysTrust)
                self.closeWindow()
            },
            onDeny: {
                self.pendingDeny = nil
                onDeny()
                self.closeWindow()
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
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Titlebar close without choosing: resolve the request as a deny.
        if let deny = pendingDeny {
            pendingDeny = nil
            deny()
        }
        window = nil
    }
}

#Preview {
    ConnectionApprovalView(
        clientName: "Claude Desktop",
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
}
