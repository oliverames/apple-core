// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window.
//
// This replaces a six-pane window (Dashboard / Services / Security /
// Cloudflare / Cloud Clients / Server) carrying roughly sixty-five controls.
// Almost none of them were decisions: port, bind host, LaunchAgent lifecycle,
// allowed origins, route mode, tunnel and account identifiers, cloudflared and
// config paths were implementation details surfaced as settings because they
// existed, and each one asked the user to understand something about how the
// server works in order to use it.
//
// There are three decisions in this app: what data Apple Core can reach,
// whether it is reachable from outside this Mac, and which clients are
// allowed. Those are the three panes. Everything else is automatic or lives in
// Diagnostics, which is a sheet, not a pane, because it is for when something
// is wrong rather than for setting anything up.

import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case services = "Services"
    case access = "Access"
    case clients = "Clients"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .services: "square.grid.2x2"
        case .access: "globe"
        case .clients: "desktopcomputer"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel

    @State private var selection: SettingsPane = .services
    @State private var isShowingDiagnostics = false

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 200)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Button {
                    isShowingDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        } detail: {
            switch selection {
            case .services:
                ServicesPane(serverController: serverController)
            case .access:
                AccessPane(model: model)
            case .clients:
                ClientsPane(serverController: serverController, model: model)
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsView(model: model, serverController: serverController)
        }
        .task {
            model.reloadConfigFromDisk()
            await model.refreshCloudflareStatus()
        }
    }
}

// MARK: - Pane chrome

/// Title, one supporting line, and the pane's content in a grouped form.
/// Every pane uses it so the three read as one window rather than three.
private struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)

            Form {
                content
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Services

private struct ServicesPane: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        PaneScaffold(
            title: "Services",
            subtitle: "What Apple Core can reach on this Mac."
        ) {
            Section {
                ForEach(serverController.computedServiceConfigs) { config in
                    ServiceToggleRow(serverController: serverController, config: config)
                }
            } footer: {
                Text("macOS asks your permission the first time each one is switched on.")
            }
        }
    }
}

/// One service. Its own type so switching Calendar on does not re-evaluate the
/// other ten rows, and so the in-flight and error state stay local.
///
/// This row used to carry a second "Remote" switch. See `ServiceAccessPolicy`
/// for why that axis is gone.
private struct ServiceToggleRow: View {
    @ObservedObject var serverController: ServerController
    let config: ServiceConfig

    @State private var isActivating = false
    @State private var activationError: String?

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 10) {
                Image(systemName: config.iconName)
                    .foregroundStyle(config.color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                    if let activationError {
                        Text(activationError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isActivating {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isActivating)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { config.binding.wrappedValue },
            set: { newValue in
                config.binding.wrappedValue = newValue
                activationError = nil
                Task { @MainActor in
                    if newValue {
                        isActivating = true
                        defer { isActivating = false }
                        do {
                            try await ServicePermissionCoordinator.activate(
                                config.service,
                                requirements: config.permissionRequirements
                            )
                        } catch {
                            config.binding.wrappedValue = false
                            activationError = Self.explain(error, service: config.name)
                        }
                    }
                    await serverController.updateServiceBindings(
                        Dictionary(
                            uniqueKeysWithValues: serverController.computedServiceConfigs.map { ($0.id, $0.binding) }
                        )
                    )
                }
            }
        )
    }

    private static func explain(_ error: Error, service: String) -> String {
        let message = error.localizedDescription
        guard message.lowercased().contains("denied") || message.lowercased().contains("restricted") else {
            return message
        }
        return "\(message) Change it in System Settings › Privacy & Security, then try again."
    }
}

// MARK: - Access

private struct AccessPane: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        PaneScaffold(
            title: "Access",
            subtitle: "Where Apple Core can be reached from."
        ) {
            Section {
                Picker("", selection: reachabilityBinding) {
                    Text("This Mac only").tag(false)
                    Text("Reachable from anywhere").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } footer: {
                Text("Every connection is authenticated, from here or from anywhere.")
            }

            if isRemoteOn {
                Section {
                    RemoteAccessSetup(model: model)
                }
            } else {
                Section {
                    LabeledContent("Address") {
                        Text("\(model.localBaseURL)/mcp")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var isRemoteOn: Bool {
        model.cloudflareStatus?.state == .running || model.cloudflare.enabled
    }

    /// Choosing "Reachable from anywhere" does not itself publish anything; it
    /// reveals the one setup action. Choosing "This Mac only" tears the tunnel
    /// down, which is the whole of turning it off.
    private var reachabilityBinding: Binding<Bool> {
        Binding(
            get: { isRemoteOn },
            set: { wantsRemote in
                if wantsRemote {
                    var settings = model.cloudflare
                    settings.enabled = true
                    model.cloudflare = settings
                    model.save(restartServer: false)
                } else {
                    Task { await model.stopCloudflareTunnel() }
                }
            }
        )
    }
}

// MARK: - Clients

private struct ClientsPane: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel

    @State private var isConfirmingRemoveAll = false

    private var address: String { "\(model.clientBaseURL)/mcp" }

    private var isRemoteOn: Bool {
        model.cloudflareStatus?.state == .running
    }

    var body: some View {
        PaneScaffold(
            title: "Clients",
            subtitle: "Apps allowed to use Apple Core."
        ) {
            Section {
                Text(
                    "Every client connects to the same address using the same token. Apple Core can set some of "
                        + "them up for you; the rest you paste the address into. Whichever it is, the first "
                        + "connection has to be approved here before anything is shared."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Address") {
                    Text(address)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }

                SettingsCopyButton(title: "Copy Address and Token", systemImage: "doc.on.doc") {
                    "\(address)\n\(model.token)"
                }
            }

            Section {
                ForEach(MCPClientCatalog.local(address: address, token: model.token)) { client in
                    ClientRow(client: client, address: address, token: model.token, isRemoteOn: true)
                }
            } header: {
                Text("On this Mac")
            }

            Section {
                ForEach(MCPClientCatalog.cloud) { client in
                    ClientRow(client: client, address: address, token: model.token, isRemoteOn: isRemoteOn)
                }
            } header: {
                Text("Over the internet")
            } footer: {
                Text(
                    isRemoteOn
                        ? "These reach this Mac at the address above."
                        : "Turn on \"Reachable from anywhere\" in Access before these can connect."
                )
            }

            TrustedClientsSection(
                clients: serverController.getTrustedClients(),
                onRemove: { serverController.removeTrustedClient($0) },
                onRemoveAll: { isConfirmingRemoveAll = true }
            )
        }
        .alert("Remove all trusted clients?", isPresented: $isConfirmingRemoveAll) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) { serverController.resetTrustedClients() }
        } message: {
            Text("Each one will have to be approved again the next time it connects.")
        }
    }
}

/// One client. What the trailing control is depends on how much Apple Core can
/// actually do for that client, which is the honest distinction: configure it,
/// hand over a command, or hand over the address.
private struct ClientRow: View {
    let client: MCPClient
    let address: String
    let token: String
    let isRemoteOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: client.iconName)
                .foregroundStyle(client.isInstalled ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(client.name)
                    .foregroundStyle(client.isInstalled ? .primary : .secondary)
                if case let .paste(instructions) = client.setup {
                    Text(instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !client.isInstalled {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            action
        }
        .opacity(client.requiresRemoteAccess && !isRemoteOn ? 0.5 : 1)
        .disabled(client.requiresRemoteAccess && !isRemoteOn)
    }

    @ViewBuilder
    private var action: some View {
        switch client.setup {
        case .automatic:
            Button("Configure") { ClaudeDesktop.showConfigurationPanel() }
                .disabled(!client.isInstalled)
        case let .command(command):
            SettingsCopyButton(title: "Copy Command", systemImage: "terminal") { command }
        case .paste:
            SettingsCopyButton(title: "Copy Address", systemImage: "link") { address }
        }
    }
}

private struct TrustedClientsSection: View {
    let clients: [String]
    let onRemove: (String) -> Void
    let onRemoveAll: () -> Void

    var body: some View {
        Section {
            if clients.isEmpty {
                Text("No clients approved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clients, id: \.self) { client in
                    HStack {
                        Text(client)
                        Spacer()
                        Button("Remove") { onRemove(client) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Remove All", role: .destructive, action: onRemoveAll)
            }
        } header: {
            Text("Approved")
        } footer: {
            Text("These connect without asking. Anything else has to be approved when it first connects.")
        }
    }
}

// MARK: - Shared

struct SettingsCopyButton: View {
    let title: String
    let systemImage: String
    let value: () -> String?

    @State private var isConfirmingCopy = false

    var body: some View {
        Button {
            guard let value = value(), !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation { isConfirmingCopy = true }
            Task {
                try? await Task.sleep(for: .milliseconds(1400))
                withAnimation { isConfirmingCopy = false }
            }
        } label: {
            Label(
                isConfirmingCopy ? "Copied" : title,
                systemImage: isConfirmingCopy ? "checkmark.circle.fill" : systemImage
            )
        }
    }
}
