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
    @State private var permissionStates: [ServicePermissionRequirement: ServicePermissionState] = [:]
    /// The requirement whose consent prompt is on screen, so its row can show
    /// progress and its button cannot be pressed twice.
    @State private var requestingPermission: ServicePermissionRequirement?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                serverSection
                permissionsSection
                remoteSection
                repairSection
            }
            .formStyle(.grouped)
            .groupedPageLayout()

            EditorFooter(
                confirmTitle: "Done",
                cancelTitle: "Copy Report",
                onCancel: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                },
                onConfirm: { dismiss() }
            )
        }
        .frame(width: 620, height: 560)
        .task {
            model.refreshAppLaunchAgentStatus()
            await refreshPermissionStates()
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
            SectionHeader(title: "Server", subtitle: "What Apple Core is doing right now.")
        }
    }

    /// What macOS actually grants right now, rather than what each service
    /// asked for when it was switched on. Read-only: opening Diagnostics
    /// never triggers a consent prompt.
    private var permissionsSection: some View {
        Section {
            ForEach(permissionRows, id: \.requirement) { row in
                let state = permissionStates[row.requirement]
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.requirement.settingsTitle)
                        Text(row.services.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if let state {
                        // An automation grant that has never been asked for
                        // does not appear under Automation in System Settings
                        // at all, so sending someone there was a dead end.
                        // Ask for it instead, and keep Settings for the case
                        // that genuinely needs it: a refusal, which macOS will
                        // not prompt about again.
                        if state == .promptBlocked {
                            // Neither button helps here. macOS recorded
                            // nothing, so Settings has no row to show, and
                            // asking again returns the same refusal.
                            EmptyView()
                        } else if !state.isGranted, !state.isDenied,
                            row.requirement.automationTarget != nil
                        {
                            Button("Request Access") {
                                Task { await requestAccess(for: row.requirement) }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(requestingPermission == row.requirement)
                        } else if !state.isGranted, let url = row.requirement.privacySettingsURL {
                            Button("Open Settings") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }

                        if requestingPermission == row.requirement {
                            ProgressView().controlSize(.small)
                        } else {
                            StatusBadge(title: state.label, tone: state.tone)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, 2)

                if permissionStates[row.requirement] == .promptBlocked {
                    Text(
                        "macOS would not show the request, so nothing was recorded and there is no "
                            + "switch for it in System Settings. This Mac is set up to block consent "
                            + "prompts for apps Apple did not sign, which custom boot-args such as "
                            + "amfi_get_out_of_my_way cause. Restoring the default security settings "
                            + "and restarting lets the request through."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                }
            }

            Button {
                Task { await refreshPermissionStates() }
            } label: {
                Label("Recheck Permissions", systemImage: "arrow.clockwise")
            }
        } header: {
            SectionHeader(
                title: "Permissions",
                subtitle: "What macOS grants this Mac's copy of Apple Core."
            )
        } footer: {
            TipFooter(
                text:
                    "Changing a switch in System Settings quits Apple Core's access immediately; use Recheck to see the new state."
            )
        }
    }

    /// Asks macOS for one automation grant, then re-reads it.
    ///
    /// User-initiated only. `state(of:)` stays read-only so that merely
    /// opening this pane never puts a consent prompt on screen.
    private func requestAccess(for requirement: ServicePermissionRequirement) async {
        requestingPermission = requirement
        defer { requestingPermission = nil }
        let updated = await ServicePermissionStatus.requestAutomationAccess(for: requirement)
        permissionStates[requirement] = updated
    }

    private var permissionRows: [(requirement: ServicePermissionRequirement, services: [String])] {
        ServicePermissionStatus.requirementsInUse(by: serverController.computedServiceConfigs)
    }

    private func refreshPermissionStates() async {
        var states: [ServicePermissionRequirement: ServicePermissionState] = [:]
        for row in permissionRows {
            states[row.requirement] = await ServicePermissionStatus.state(of: row.requirement)
        }
        permissionStates = states
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
            SectionHeader(title: "Remote Access")
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
            SectionHeader(title: "Repair", subtitle: "For when something above is wrong.")
        } footer: {
            TipFooter(
                text: "Rotating the bearer token disconnects clients that use it. OAuth clients stay signed in."
            )
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
        Permissions:
        \(permissionReport)
        """
    }

    private var permissionReport: String {
        permissionRows
            .map { row in
                "  \(row.requirement.settingsTitle): \(permissionStates[row.requirement]?.label ?? "not checked")"
            }
            .joined(separator: "\n")
    }
}
