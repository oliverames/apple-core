// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where the machinery went.
//
// The settings window used to present all of this as configuration: listener
// port and bind host, the LaunchAgent lifecycle with its own install and
// refresh buttons, allowed origins as a free-text editor, the Cloudflare
// account and tunnel identifiers, three file paths, and four tunnel repair
// verbs. None of it is setup — it is what you look at when something is
// already wrong. So it is a sheet you open deliberately, and everything in it
// is either read-only or an explicit repair.
//
// The values themselves are now chosen automatically: the listener stays on
// loopback, the LaunchAgent is simply how a background server runs, and the
// allowed origins are derived from the addresses actually in use.

import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: ServingSettingsModel
    @ObservedObject var serverController: ServerController

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingToken = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                serverSection
                remoteSection
                repairSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                SettingsCopyButton(title: "Copy Report", systemImage: "doc.on.clipboard") {
                    report
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 560)
        .task {
            model.refreshAppLaunchAgentStatus()
            await model.refreshCloudflareStatus()
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            LabeledContent("Status") {
                Label(
                    serverController.serverStatus,
                    systemImage: serverController.serverStatus == "Running" ? "checkmark.circle.fill" : "stop.circle"
                )
                .foregroundStyle(serverController.serverStatus == "Running" ? .green : .secondary)
            }
            LabeledContent("Local address") {
                Text("\(model.localBaseURL)/mcp")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Background agent") {
                Text(model.isAppLaunchAgentLoaded ? "Loaded" : "Not loaded")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Token") {
                HStack(spacing: 8) {
                    Text(isShowingToken ? model.token : String(repeating: "•", count: 24))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(isShowingToken ? "Hide" : "Show") { isShowingToken.toggle() }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Server")
        }
    }

    private var remoteSection: some View {
        Section {
            LabeledContent("Tunnel") {
                Text(model.cloudflareStatus?.state.rawValue ?? "checking")
                    .foregroundStyle(.secondary)
            }
            if let message = model.cloudflareStatus?.message, !message.isEmpty {
                LabeledContent("Detail") {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.cloudflare.hostname.isEmpty {
                LabeledContent("Hostname") {
                    Text(model.cloudflare.hostname)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if !model.cloudflare.tunnelId.isEmpty {
                LabeledContent("Tunnel ID") {
                    Text(model.cloudflare.tunnelId)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            LabeledContent("cloudflared") {
                Text(model.cloudflaredVersion ?? "not installed")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote access")
        }
    }

    private var repairSection: some View {
        Section {
            Button {
                Task {
                    await serverController.stopServer()
                    await serverController.startServer()
                }
            } label: {
                Label("Restart Server", systemImage: "arrow.clockwise")
            }

            Button {
                model.installAppLaunchAgent()
            } label: {
                Label("Reinstall Background Agent", systemImage: "wrench.and.screwdriver")
            }

            Button {
                Task { await model.bootstrapCloudflareTunnel() }
            } label: {
                Label("Rebuild Tunnel", systemImage: "hammer")
            }
            .disabled(!model.isCloudflaredInstalled)

            Button {
                model.rotateToken()
            } label: {
                Label("Rotate Token", systemImage: "key.horizontal")
            }
        } header: {
            Text("Repair")
        } footer: {
            Text("Rotating the token disconnects every client until each one is given the new one.")
        }
    }

    /// One pasteable block for a bug report, so nobody has to be walked
    /// through reading six fields back over a support thread.
    private var report: String {
        """
        Apple Core diagnostics
        Server: \(serverController.serverStatus)
        Local: \(model.localBaseURL)/mcp
        Remote: \(model.publicBaseURL.isEmpty ? "not configured" : model.publicBaseURL)
        Background agent: \(model.isAppLaunchAgentLoaded ? "loaded" : "not loaded")
        Tunnel: \(model.cloudflareStatus?.state.rawValue ?? "unknown")
        Tunnel detail: \(model.cloudflareStatus?.message ?? "-")
        Hostname: \(model.cloudflare.hostname.isEmpty ? "-" : model.cloudflare.hostname)
        Tunnel ID: \(model.cloudflare.tunnelId.isEmpty ? "-" : model.cloudflare.tunnelId)
        cloudflared: \(model.cloudflaredVersion ?? "not installed")
        Services enabled: \(serverController.computedServiceConfigs.filter { $0.binding.wrappedValue }.count) \
        of \(serverController.computedServiceConfigs.count)
        """
    }
}
