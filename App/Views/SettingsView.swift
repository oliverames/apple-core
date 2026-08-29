// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window.
//
// This replaces a six-pane window (Dashboard / Services / Security /
// Cloudflare / Cloud Clients / Server) carrying roughly sixty-five controls.
// Almost none of them were decisions: port, bind host, LaunchAgent lifecycle,
// allowed origins, route mode, tunnel and account identifiers, cloudflared and
// config paths were implementation details surfaced as settings because they
// existed. There are three decisions in this app — what data Apple Core can
// reach, whether it is reachable from outside this Mac, and which clients are
// allowed — so there are three panes, and the machinery moved to Diagnostics.
//
// The layout follows skylight-bridge: NavigationSplitView with a sidebar List,
// detail pages that are grouped `Form`s titled by `.navigationTitle` rather
// than an in-content heading, `SectionHeader`/`TipFooter` section grammar, and
// `groupedPageLayout()` margins. See `Components.swift`.

import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
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
            .listStyle(.sidebar)
            .navigationTitle("Apple Core")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        .help("Server status, tunnel details, and repair actions")
                    }
                }
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsView(model: model, serverController: serverController)
        }
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView(
                serverController: serverController,
                model: model,
                onFinish: {
                    model.completeOnboarding()
                    selection = .services
                }
            )
            .interactiveDismissDisabled()
        }
        .alert(
            "Could Not Save Settings",
            isPresented: Binding(
                get: { model.configurationSaveError != nil },
                set: { isPresented in
                    if !isPresented { model.configurationSaveError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.configurationSaveError = nil
            }
        } message: {
            Text(model.configurationSaveError ?? "Apple Core could not save its configuration.")
        }
        .alert(
            "Could Not Disconnect Client",
            isPresented: Binding(
                get: { model.clientManagementError != nil },
                set: { isPresented in
                    if !isPresented { model.clientManagementError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.clientManagementError = nil
            }
        } message: {
            Text(model.clientManagementError ?? "Apple Core could not disconnect the OAuth client.")
        }
        .task {
            model.reloadConfigFromDisk()
            await model.refreshCloudflareStatus()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .services:
            ServicesPane(serverController: serverController, model: model)
        case .access:
            AccessPane(model: model)
        case .clients:
            ClientsPane(serverController: serverController, model: model)
        }
    }
}

// MARK: - Services

private struct ServicesPane: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(serverController.computedServiceConfigs) { config in
                    ServiceToggleRow(serverController: serverController, config: config)
                }
            } header: {
                SectionHeader(
                    title: "Apple Services",
                    subtitle: "Only what you switch on here is ever available to a client."
                )
            } footer: {
                TipFooter(text: "macOS asks your permission the first time each service is switched on.")
            }

            SharedFoldersSection(model: model)
        }
        .formStyle(.grouped)
        .groupedPageLayout()
        .navigationTitle("Services")
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
        HStack(spacing: 12) {
            Image(systemName: config.iconName)
                .foregroundStyle(config.color)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .fontWeight(.medium)
                if let activationError {
                    Text(activationError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !config.permissionRequirements.isEmpty {
                    Text("Needs \(config.permissionRequirements.sentenceDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if activationError != nil {
                StatusBadge(title: "Not granted", tone: .warning)
            }

            if isActivating {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("Enabled", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isActivating)
                .accessibilityLabel("Enable \(config.name)")
        }
        .padding(.vertical, 4)
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
                            activationError = Self.explain(error)
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

    private static func explain(_ error: Error) -> String {
        let message = error.localizedDescription
        guard message.lowercased().contains("denied") || message.lowercased().contains("restricted") else {
            return message
        }
        return "Grant it in System Settings › Privacy & Security, then try again."
    }
}

// MARK: - Access

private struct AccessPane: View {
    @ObservedObject var model: ServingSettingsModel

    private var isRemoteOn: Bool {
        model.cloudflareStatus?.state == .running || model.cloudflare.enabled
    }

    var body: some View {
        Form {
            Section {
                Picker("Reachable from", selection: reachabilityBinding) {
                    Text("This Mac only").tag(false)
                    Text("Anywhere").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                LabeledContent("Address") {
                    Text(
                        isRemoteOn && !model.publicBaseURL.isEmpty
                            ? "\(model.clientBaseURL)/mcp"
                            : "\(model.localBaseURL)/mcp"
                    )
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            } header: {
                SectionHeader(
                    title: "Where Apple Core Can Be Reached",
                    subtitle: "Clients on this Mac always work. Anywhere adds cloud clients."
                )
            } footer: {
                TipFooter(text: "Every connection is authenticated, from here or from anywhere.")
            }

            if isRemoteOn {
                Section {
                    RemoteAccessSetup(model: model)
                } header: {
                    SectionHeader(title: "Remote Access")
                }

                AuthorizationPageProtectionSection(model: model)
            }
        }
        .formStyle(.grouped)
        .groupedPageLayout()
        .navigationTitle("Access")
    }

    /// Choosing "Anywhere" does not itself publish anything; it reveals the one
    /// setup action. Choosing "This Mac only" tears the tunnel down, which is
    /// the whole of turning it off.
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

/// Cloudflare Access over the OAuth authorization page, and nothing else.
///
/// The page is the only one on this host a person opens in a browser, so it is
/// the only one an identity check can sit in front of without breaking things.
/// The copy says so, because "protect my server with Access" is the obvious
/// thing to want and the thing that would stop every client connecting.
private struct AuthorizationPageProtectionSection: View {
    @ObservedObject var model: ServingSettingsModel

    private var protectBinding: Binding<Bool> {
        Binding(
            get: { model.cloudflare.accessProtectAuthorizePage },
            set: { newValue in
                var settings = model.cloudflare
                settings.accessProtectAuthorizePage = newValue
                model.cloudflare = settings
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Require a Cloudflare login on the authorization page", isOn: protectBinding)

            if model.cloudflare.accessProtectAuthorizePage {
                LabeledContent("Allowed people") {
                    TextField(
                        "you@example.com, someone@example.com",
                        text: $model.accessEmailsText,
                        axis: .vertical
                    )
                    .lineLimit(1 ... 3)
                    .textFieldStyle(.roundedBorder)
                }

                LabeledContent("API token") {
                    SecureField("Cloudflare API token with Access permissions", text: $model.accessAPIToken)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button(
                    model.cloudflare.accessProtectAuthorizePage ? "Apply Protection" : "Remove Protection"
                ) {
                    Task { await model.applyAccessProtection() }
                }
                .disabled(model.isApplyingAccessProtection)

                if model.isApplyingAccessProtection {
                    ProgressView().controlSize(.small)
                }
            }

            if let message = model.accessStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.accessErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            SectionHeader(
                title: "Authorization Page",
                subtitle: "Adds a Cloudflare login in front of the page where the Apple Core token is typed."
            )
        } footer: {
            TipFooter(
                text:
                    "Only that page is protected. The MCP endpoint and the client registration and token endpoints stay open, because clients call them without a browser and would otherwise stop connecting."
            )
        }
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
        Form {
            Section {
                LabeledContent("Address") {
                    Text(address)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCopyButton(title: "Copy Address and Token", systemImage: "doc.on.doc") {
                    "\(address)\n\(model.token)"
                }
            } header: {
                SectionHeader(
                    title: "How Clients Connect",
                    subtitle: "Every client uses the same address and token. Some Apple Core can set up for you; "
                        + "for the rest you paste the details in."
                )
            } footer: {
                TipFooter(text: "The first time any client connects, Apple Core asks you to approve it.")
            }

            Section {
                ForEach(MCPClientCatalog.local(address: address, token: model.token)) { client in
                    ClientRow(client: client, address: address, isAvailable: true)
                }
            } header: {
                SectionHeader(title: "On This Mac")
            }

            Section {
                ForEach(MCPClientCatalog.cloud) { client in
                    ClientRow(client: client, address: address, isAvailable: isRemoteOn)
                }
            } header: {
                SectionHeader(title: "Over the Internet")
            } footer: {
                if !isRemoteOn {
                    TipFooter(text: "Set Access to Anywhere before these can connect.")
                }
            }

            SharedTokenTrustSection(
                isTrusted: serverController.sharedTokenTrust() != nil,
                onRevoke: { serverController.revokeSharedTokenTrust() }
            )

            OAuthClientsSection(
                clients: model.registeredOAuthClients,
                trustedClientIDs: Set(serverController.getTrustedClients().map(\.clientID)),
                isBusy: model.isManagingOAuthClients,
                onDisconnect: { client in
                    Task { await model.disconnectOAuthClient(client.clientID) }
                },
                onRemoveAll: { isConfirmingRemoveAll = true }
            )
        }
        .formStyle(.grouped)
        .groupedPageLayout()
        .navigationTitle("Clients")
        .task {
            await model.reloadOAuthClients()
        }
        .alert("Disconnect all OAuth clients?", isPresented: $isConfirmingRemoveAll) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect All", role: .destructive) {
                Task { await model.disconnectAllOAuthClients() }
            }
            .disabled(model.isManagingOAuthClients)
        } message: {
            Text("Apple Core will revoke their credentials and close their active sessions.")
        }
    }
}

/// One client. What the trailing control is depends on how much Apple Core can
/// actually do for that client: configure it, hand over a command, or hand over
/// the address.
private struct ClientRow: View {
    let client: MCPClient
    let address: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: client.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .fontWeight(.medium)
                if case let .paste(instructions) = client.setup {
                    Text(instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if client.isInstalled {
                    Text("Installed on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            action
        }
        .padding(.vertical, 4)
        .opacity(isAvailable ? 1 : 0.5)
        .disabled(!isAvailable)
    }

    @ViewBuilder
    private var action: some View {
        switch client.setup {
        case .automatic:
            Button("Set Up…") { ClaudeDesktop.showConfigurationPanel() }
                .disabled(!client.isInstalled)
        case let .command(command):
            SettingsCopyButton(title: "Copy Command", systemImage: "terminal") { command }
        case .paste:
            SettingsCopyButton(title: "Copy Address", systemImage: "link") { address }
        }
    }
}

private struct SharedTokenTrustSection: View {
    let isTrusted: Bool
    let onRevoke: () -> Void

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isTrusted ? "Connects without approval" : "Approval required")
                    Text(
                        isTrusted
                            ? "Anything presenting the shared token connects without asking. Rotating the token also undoes this."
                            : "Every new connection using the shared token asks for approval first."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isTrusted {
                    Button("Require Approval", role: .destructive, action: onRevoke)
                }
            }
            .padding(.vertical, 2)
        } header: {
            SectionHeader(
                title: "Shared Token",
                subtitle: "The token identifies no particular client, so trusting it covers every client that has it."
            )
        }
    }
}

private struct OAuthClientsSection: View {
    let clients: [OAuthRegisteredClient]
    let trustedClientIDs: Set<String>
    let isBusy: Bool
    let onDisconnect: (OAuthRegisteredClient) -> Void
    let onRemoveAll: () -> Void

    var body: some View {
        Section {
            if clients.isEmpty {
                Text("No OAuth clients registered yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(clients, id: \.clientID) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.clientName)
                            Text("OAuth client \(client.clientID.prefix(12))…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                trustedClientIDs.contains(client.clientID)
                                    ? "Connects without approval" : "Approval required"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Disconnect") { onDisconnect(client) }
                            .disabled(isBusy)
                    }
                    .padding(.vertical, 2)
                }
                Button("Disconnect All…", role: .destructive, action: onRemoveAll)
                    .disabled(isBusy)
            }
        } header: {
            SectionHeader(
                title: "OAuth Clients",
                subtitle: "Disconnecting a client revokes its credentials and closes its active sessions."
            )
        }
    }
}

// MARK: - Shared folders

/// The filesystem surface's allowlist. This is the one service whose scope the
/// user has to define, because macOS does not define it for us, so it gets a
/// section rather than just a switch.
private struct SharedFoldersSection: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        Section {
            if model.filesystemRoots.isEmpty {
                Text("No folders shared. The Filesystem service can reach nothing until you add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(model.filesystemRoots) { root in
                    SharedFolderRow(
                        root: root,
                        onSetWritable: { model.setFilesystemRoot(root, writable: $0) },
                        onRemove: { model.removeFilesystemRoot(root) }
                    )
                }
            }

            Button {
                chooseFolder()
            } label: {
                Label("Share a Folder…", systemImage: "folder.badge.plus")
            }
        } header: {
            SectionHeader(
                title: "Shared Folders",
                subtitle: "What the Filesystem service can reach. Everything else on this Mac stays private."
            )
        } footer: {
            TipFooter(
                text: "Folders are read-only until you allow writing. Sharing a folder also shares everything "
                    + "inside it."
            )
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Choose a folder Apple Core may read."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addFilesystemRoot(url, writable: false)
    }
}

private struct SharedFolderRow: View {
    let root: FilesystemRoot
    let onSetWritable: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.teal)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: root.path).lastPathComponent)
                    .fontWeight(.medium)
                Text(abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 12)

            Toggle("Allow writing", isOn: Binding(get: { root.writable }, set: onSetWritable))
                .toggleStyle(.checkbox)
                .accessibilityLabel("Allow writing to \(root.path)")

            Button("Remove", action: onRemove)
        }
        .padding(.vertical, 4)
    }

    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return root.path.hasPrefix(home)
            ? "~" + root.path.dropFirst(home.count)
            : root.path
    }
}
