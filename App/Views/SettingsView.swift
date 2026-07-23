// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window UI. Adapted from Bridgeport's
// Sources/bridgeport/Views/SettingsView.swift: same NavigationSplitView
// pane layout, SettingsGroup cards, and interaction patterns, with
// Bridgeport's per-connector rows replaced by per-service-surface rows
// (the fixed ServiceRegistry set), plus Apple Core's trusted-client list.

import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case services = "Services"
    case security = "Security"
    case cloudflare = "Cloudflare"
    case clients = "Cloud Clients"
    case server = "Server"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.bottom.50percent"
        case .services: "square.grid.2x2"
        case .security: "lock.shield"
        case .cloudflare: "network"
        case .clients: "cloud"
        case .server: "server.rack"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel
    @State private var selection: SettingsPane = .dashboard
    @State private var isCloudflareAdvancedExpanded = false
    @State private var showingResetTrustedClientsAlert = false

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selection {
                    case .dashboard:
                        dashboardPane
                    case .services:
                        servicesPane
                    case .security:
                        securityPane
                    case .cloudflare:
                        cloudflarePane
                    case .clients:
                        clientsPane
                    case .server:
                        serverPane
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .navigationTitle("Apple Core Settings")
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 560, idealHeight: 680)
        .task {
            model.reloadConfigFromDisk()
            await model.refreshCloudflareStatus()
        }
        .onChange(of: selection) { _, _ in
            model.reloadConfigFromDisk()
            Task { await model.refreshCloudflareStatus() }
        }
    }

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    // MARK: - Dashboard

    private var dashboardPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductHeader(
                title: "Apple Core",
                subtitle: "Personal MCP server for Apple system services, served over HTTP/SSE."
            )

            SettingsGroup(title: "Status") {
                LabeledContent("Server") {
                    StatusValue(
                        text: serverController.serverStatus,
                        systemImage: serverController.serverStatus == "Running"
                            ? "checkmark.circle.fill" : "stop.circle",
                        tint: serverController.serverStatus == "Running" ? .green : .secondary
                    )
                }
                Divider()
                LabeledContent("Enabled Services") {
                    Text("\(serviceConfigs.filter { $0.binding.wrappedValue }.count) of \(serviceConfigs.count)")
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Remote Services") {
                    Text("\(model.publiclyExposedServiceCount(from: serviceConfigs))")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(title: "Endpoints") {
                LabeledContent("Local") {
                    Text("\(model.localBaseURL)/mcp")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Remote") {
                    Text(model.publicBaseURL.isEmpty ? "Not configured" : "\(model.clientBaseURL)/mcp")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.publicBaseURL.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(model.lastStatusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(title: "Service") {
                ActionGrid(minimumItemWidth: 180) {
                    Button {
                        Task {
                            await serverController.stopServer()
                            await serverController.startServer()
                        }
                    } label: {
                        Label("Restart Server", systemImage: "arrow.clockwise.circle")
                    }

                    CopyButton(title: "Copy Local URL", systemImage: "link") {
                        "\(model.localBaseURL)/mcp"
                    }

                    CopyButton(title: "Copy Remote URL", systemImage: "globe") {
                        "\(model.clientBaseURL)/mcp"
                    }
                    .disabled(model.publicBaseURL.isEmpty)
                }
            }
        }
    }

    // MARK: - Services

    private var servicesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(
                title: "Services",
                subtitle:
                    "Enable Apple system service surfaces and choose which allow remote access through the tunnel "
                    + "hostname. Remote access always requires authentication (bearer token or OAuth)."
            )

            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(serviceConfigs) { config in
                    ServiceRow(serverController: serverController, model: model, config: config)
                }
            }
        }
    }

    // MARK: - Security

    private var securityPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(
                title: "Security",
                subtitle: "Apple Core uses bearer-token authentication for tunneled MCP traffic."
            )

            SettingsGroup(title: "API Token") {
                LabeledContent("Token") {
                    HStack(spacing: 8) {
                        Text(model.isShowingToken ? model.token : String(repeating: "•", count: 28))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(model.isShowingToken ? "Hide" : "Show") {
                            model.isShowingToken.toggle()
                        }

                        CopyButton(title: "Copy", systemImage: "doc.on.doc") {
                            model.token
                        }
                    }
                }
                Divider()
                Button {
                    model.rotateToken()
                } label: {
                    Label("Rotate Token", systemImage: "key.horizontal")
                }
            }

            SettingsGroup(title: "Authentication") {
                Toggle(
                    isOn: Binding(
                        get: { model.allowQueryTokenAuth },
                        set: { newValue in
                            model.allowQueryTokenAuth = newValue
                            model.save()
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Query-String Token Fallback")
                        Text("Legacy clients can pass the token in the URL instead of a Bearer header.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: "Allowed Origins") {
                TextEditor(text: $model.allowedOriginsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Button {
                    model.save()
                } label: {
                    Label("Apply Origins", systemImage: "checkmark.circle")
                }
            }

            trustedClientsGroup
        }
    }

    private var trustedClientsGroup: some View {
        SettingsGroup(title: "Trusted Clients") {
            Text("Clients that automatically connect without approval.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let trustedClients = serverController.getTrustedClients()
            if trustedClients.isEmpty {
                Text("No trusted clients")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(trustedClients, id: \.self) { client in
                    HStack {
                        Text(client)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            serverController.removeTrustedClient(client)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Divider()

                Button(role: .destructive) {
                    showingResetTrustedClientsAlert = true
                } label: {
                    Label("Remove All", systemImage: "trash")
                }
                .alert("Remove All Trusted Clients", isPresented: $showingResetTrustedClientsAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove All", role: .destructive) {
                        serverController.resetTrustedClients()
                    }
                } message: {
                    Text("They will need to be approved again when connecting.")
                }
            }
        }
    }

    // MARK: - Cloudflare

    private var cloudflarePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(
                title: "Cloudflare",
                subtitle:
                    "Create and run a named Cloudflare Tunnel owned by Apple Core, with explicit per-service remote access."
            )

            SettingsGroup(title: "Status") {
                LabeledContent("Tunnel") {
                    StatusValue(
                        text: cloudflareStatusText,
                        systemImage: cloudflareStatusIcon,
                        tint: cloudflareStatusTint
                    )
                }
                Divider()
                LabeledContent("Detail") {
                    Text(model.cloudflareStatus?.message ?? "Checking…")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                LabeledContent("Remote URL") {
                    let derivedURL =
                        model.publicBaseURL.isEmpty
                        ? CloudflareManager.publicBaseURL(for: model.cloudflare) : model.publicBaseURL
                    if derivedURL.isEmpty {
                        Text("Not configured")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(derivedURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            SettingsGroup(title: "Configuration") {
                Toggle(
                    isOn: Binding(
                        get: { model.cloudflare.enabled },
                        set: { newValue in
                            Task { await model.setCloudflareEnabled(newValue) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Cloudflare Tunnel")
                        Text(
                            "Apple Core will manage a local cloudflared LaunchAgent, but services allow remote access only when their Remote Access toggle is on."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                SettingsField(label: "Profile") {
                    cloudflareTextField("Personal tunnel", keyPath: \.profileName)
                }
                SettingsField(label: "Domain") {
                    cloudflareTextField("example.com", keyPath: \.domain)
                }
                SettingsField(label: "Hostname") {
                    cloudflareTextField("mcp.example.com", keyPath: \.hostname)
                }
                SettingsField(label: "Tunnel Name") {
                    cloudflareTextField("apple-core", keyPath: \.tunnelName)
                }

                DisclosureGroup(isExpanded: $isCloudflareAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsField(label: "Tunnel ID") {
                            cloudflareTextField("Created or discovered by Apple Core", keyPath: \.tunnelId)
                        }
                        SettingsField(label: "Account ID") {
                            cloudflareTextField("Optional Cloudflare account ID", keyPath: \.accountId)
                        }
                        SettingsField(label: "Zone ID") {
                            cloudflareTextField("Optional Cloudflare zone ID", keyPath: \.zoneId)
                        }
                        SettingsField(label: "cloudflared") {
                            cloudflareTextField("/opt/homebrew/bin/cloudflared", keyPath: \.cloudflaredPath)
                        }
                        SettingsField(label: "Config File") {
                            cloudflareTextField(
                                "~/.config/apple-core/cloudflared/config.yml",
                                keyPath: \.configFilePath
                            )
                        }
                        SettingsField(label: "Credentials File") {
                            cloudflareTextField("Created by cloudflared tunnel create", keyPath: \.credentialsFilePath)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Advanced Cloudflare Settings", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Spacer()

                    Menu {
                        Button("Prepare Local Config") {
                            Task { await model.prepareCloudflareConfiguration() }
                        }
                        .disabled(!model.cloudflare.enabled)

                        Button("Create or Repair Tunnel") {
                            Task { await model.bootstrapCloudflareTunnel() }
                        }
                        .disabled(
                            !model.cloudflare.enabled || !(model.cloudflareStatus?.cloudflaredInstalled ?? false)
                        )

                        Button("Restart Tunnel") {
                            Task { await model.restartCloudflareTunnel() }
                        }
                        .disabled(!model.cloudflare.enabled || model.cloudflareStatus?.state == .needsTunnel)
                    } label: {
                        Label("Tunnel Actions", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()

                    if model.cloudflareStatus?.state == .running {
                        Button {
                            Task { await model.stopCloudflareTunnel() }
                        } label: {
                            Label("Stop Tunnel", systemImage: "stop.circle")
                                .frame(width: 130)
                        }
                    } else {
                        Button {
                            Task { await model.startCloudflareTunnel() }
                        } label: {
                            Label("Start Tunnel", systemImage: "play.circle")
                                .frame(width: 130)
                        }
                        .disabled(!model.cloudflare.enabled)
                    }
                }
            }

            SettingsGroup(title: "Routing") {
                Text(
                    "One Cloudflare hostname forwards to \(model.localBaseURL); only services with Remote Access enabled are reachable, and every remote request must authenticate."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                LabeledContent("Route Mode") {
                    Text(humanizedRouteMode)
                        .foregroundStyle(.secondary)
                        .help("Configured route mode: \(model.cloudflare.routeMode)")
                }

                Label(
                    model.cloudflare.createdByAppleCore
                        ? "Apple Core created this tunnel." : "Apple Core did not create this tunnel.",
                    systemImage: model.cloudflare.createdByAppleCore ? "checkmark.circle" : "info.circle"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func cloudflareTextField(
        _ placeholder: String,
        keyPath: WritableKeyPath<CloudflareSettings, String>
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { model.cloudflare[keyPath: keyPath] },
                set: { model.cloudflare[keyPath: keyPath] = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 340, alignment: .leading)
        .onSubmit { model.save(restartServer: false) }
    }

    private var humanizedRouteMode: String {
        switch model.cloudflare.routeMode {
        case "single-hostname-path-routing": "Single hostname, path-based routing"
        default: model.cloudflare.routeMode
        }
    }

    private var cloudflareStatusText: String {
        guard let status = model.cloudflareStatus else { return "Checking…" }
        switch status.state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .disabled: return "Disabled"
        case .needsTunnel: return "Needs Tunnel"
        case .needsConfig: return "Needs Config"
        case .missingCloudflared: return "cloudflared Missing"
        case .error: return "Error"
        }
    }

    private var cloudflareStatusTint: Color {
        switch model.cloudflareStatus?.state {
        case .running: .green
        case .error, .missingCloudflared: .red
        case .needsTunnel, .needsConfig: .orange
        case .disabled, .stopped, .none: .secondary
        }
    }

    private var cloudflareStatusIcon: String {
        switch model.cloudflareStatus?.state {
        case .running: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .missingCloudflared: "questionmark.circle"
        case .needsTunnel, .needsConfig: "wrench.and.screwdriver"
        case .stopped: "stop.circle"
        case .disabled, .none: "pause.circle"
        }
    }

    // MARK: - Cloud Clients

    private var clientsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(
                title: "Cloud Clients",
                subtitle:
                    "Copy the remote Apple Core endpoint into Claude custom connectors and other cloud MCP clients; OAuth clients register here automatically."
            )

            SettingsGroup(title: "Endpoint") {
                LabeledContent("MCP URL") {
                    Text(model.publicBaseURL.isEmpty ? "Remote base URL not configured" : "\(model.clientBaseURL)/mcp")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.publicBaseURL.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }

                ActionGrid(minimumItemWidth: 180) {
                    CopyButton(title: "Copy MCP URL", systemImage: "link") {
                        "\(model.clientBaseURL)/mcp"
                    }
                    .disabled(model.publicBaseURL.isEmpty)

                    CopyButton(title: "Copy Token", systemImage: "key") {
                        model.token
                    }

                    Button {
                        ClaudeDesktop.showConfigurationPanel()
                    } label: {
                        Label("Configure Claude Desktop…", systemImage: "desktopcomputer")
                    }
                }
            }

            SettingsGroup(title: "Registered OAuth Clients") {
                Button {
                    model.reloadOAuthClients()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if model.registeredOAuthClients.isEmpty {
                    Text("No OAuth clients registered yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registeredOAuthClients, id: \.clientID) { client in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.clientName)
                                .font(.headline)
                            Text(client.clientID)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(
                                Date(timeIntervalSince1970: TimeInterval(client.issuedAt)),
                                format: .dateTime
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear {
            model.reloadOAuthClients()
        }
    }

    // MARK: - Server

    private var serverPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(
                title: "Server",
                subtitle: "Local HTTP/SSE listener and LaunchAgent lifecycle."
            )

            SettingsGroup(title: "Listener") {
                LabeledContent("Port") {
                    TextField("8756", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onSubmit { model.save() }
                }
                Divider()
                LabeledContent("Bind Host") {
                    TextField("127.0.0.1", text: $model.bindHost)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 200)
                        .onSubmit { model.save() }
                }
                Divider()
                HStack {
                    Spacer()
                    Button {
                        model.save()
                    } label: {
                        Label("Apply and Restart Server", systemImage: "checkmark.circle")
                    }
                }
            }

            SettingsGroup(title: "General") {
                Toggle(
                    isOn: Binding(
                        get: { model.isOpenAtLoginEnabled },
                        set: { newValue in
                            model.setOpenAtLogin(newValue)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                        Text("Standard login item: opens Apple Core and its menu bar icon when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Toggle(
                    isOn: Binding(
                        get: { model.showDockIcon },
                        set: { newValue in
                            model.showDockIcon = newValue
                            if let delegate = NSApp.delegate as? AppDelegate {
                                delegate.setShowDockIcon(newValue)
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Dock Icon")
                        Text("Display the Apple Core icon in the Dock while the app is running. When off, Apple Core lives entirely in the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: "LaunchAgent") {
                Toggle(
                    isOn: Binding(
                        get: { model.runAsLaunchAgent },
                        set: { newValue in
                            model.runAsLaunchAgent = newValue
                            if newValue {
                                model.installAppLaunchAgent()
                            } else {
                                model.removeAppLaunchAgent()
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run as LaunchAgent")
                        Text(
                            "Background keep-alive: launchd relaunches Apple Core if it quits (and also starts it at "
                                + "login, so Open at Login above is redundant while this is on)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                LabeledContent("Status") {
                    StatusValue(
                        text: model.isAppLaunchAgentLoaded ? "Loaded" : "Not Loaded",
                        systemImage: model.isAppLaunchAgentLoaded ? "checkmark.circle.fill" : "circle",
                        tint: model.isAppLaunchAgentLoaded ? .green : .secondary
                    )
                }

                Divider()

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        model.installAppLaunchAgent()
                    } label: {
                        Label("Install or Repair", systemImage: "wrench.and.screwdriver")
                            .frame(width: 150)
                    }

                    Button {
                        model.refreshAppLaunchAgentStatus()
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                            .frame(width: 150)
                    }
                }
            }
        }
        .onAppear {
            model.refreshAppLaunchAgentStatus()
            model.refreshOpenAtLoginStatus()
        }
    }
}

// MARK: - Rows

/// One service surface: local enable toggle (same @AppStorage binding the
/// menu bar uses) plus the ported ServingConfig "Public" exposure toggle.
private struct ServiceRow: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel
    let config: ServiceConfig

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(config.binding.wrappedValue ? config.color : Color(NSColor.controlColor))
                .overlay(
                    Image(systemName: config.iconName)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(config.binding.wrappedValue ? .white : .primary.opacity(0.7))
                        .padding(6)
                )
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.headline)
                Text(config.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Remote", isOn: model.exposePubliclyBinding(forServiceID: config.id))
                .disabled(!config.binding.wrappedValue)
                .accessibilityLabel("Allow remote access to \(config.name)")
                .help(
                    "Allow this service through the remote tunnel hostname. "
                        + "Remote requests still require authentication (bearer token or OAuth)."
                )

            Toggle(
                isOn: Binding(
                    get: { config.binding.wrappedValue },
                    set: { newValue in
                        config.binding.wrappedValue = newValue
                        if newValue {
                            // Front the app so TCC shows the permission prompt.
                            NSApp.activate(ignoringOtherApps: true)
                            Task {
                                do {
                                    try await config.service.activate()
                                } catch {
                                    config.binding.wrappedValue = false
                                }
                            }
                        }
                        Task {
                            await serverController.updateServiceBindings(
                                Dictionary(
                                    uniqueKeysWithValues: serverController.computedServiceConfigs.map {
                                        ($0.id, $0.binding)
                                    }
                                )
                            )
                        }
                    }
                )
            ) {
                Text("Enable \(config.name)")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(config.name)")
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shared Components (adapted from Bridgeport's SettingsView.swift)

/// Copy-to-pasteboard button with transient confirmation: the label flips to
/// "Copied" briefly so the user knows it worked.
private struct CopyButton: View {
    let title: String
    let systemImage: String
    let value: () -> String?

    @State private var isConfirmingCopy = false

    var body: some View {
        Button {
            guard let value = value(), !value.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
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

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProductHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct StatusValue: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(tint)
    }
}

private struct ActionGrid<Content: View>: View {
    let minimumItemWidth: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 10, alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
