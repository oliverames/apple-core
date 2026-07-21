import AppKit
import JSONSchema
import MCP
import OSLog
import Ontology
import SwiftUI
import UserNotifications

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let log = Logger.server

/// `Tool.inputSchema` (our app's model) is typed `JSONSchema`, but
/// `MCP.Tool.init(inputSchema:)` expects `Value`. Round-trips through JSON,
/// mirroring the same encode/decode pattern `App/Models/Tool.swift` already
/// uses to turn tool results into `Value`.
private func encodeSchemaAsValue(_ schema: JSONSchema) throws -> Value {
    let data = try JSONEncoder().encode(schema)
    return try JSONDecoder().decode(Value.self, from: data)
}

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            CalendarService.shared,
            CaptureService.shared,
            ContactsService.shared,
            LocationService.shared,
            MailService.shared,
            MapsService.shared,
            NotesService.shared,
            MessageService.shared,
            RemindersService.shared,
            ShortcutsService.shared,
            UtilitiesService.shared,
        ]
        #if WEATHERKIT_AVAILABLE
            services.append(WeatherService.shared)
        #endif
        return services
    }()

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        captureEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mailEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        notesEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        shortcutsEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        var configs: [ServiceConfig] = [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Capture",
                iconName: "camera.on.rectangle.fill",
                color: .gray.mix(with: .black, by: 0.7),
                service: CaptureService.shared,
                binding: captureEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Mail",
                iconName: "envelope.fill",
                color: .blue,
                service: MailService.shared,
                binding: mailEnabled
            ),
            ServiceConfig(
                name: "Maps",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Notes",
                iconName: "note.text",
                color: .yellow,
                service: NotesService.shared,
                binding: notesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Shortcuts",
                iconName: "square.2.layers.3d",
                color: .indigo,
                service: ShortcutsService.shared,
                binding: shortcutsEnabled
            ),
            ServiceConfig(
                name: "Utilities",
                iconName: "waveform",
                color: .secondary,
                service: UtilitiesService.shared,
                binding: utilitiesEnabled
            ),
        ]
        #if WEATHERKIT_AVAILABLE
            configs.append(
                ServiceConfig(
                    name: "Weather",
                    iconName: "cloud.sun.fill",
                    color: .cyan,
                    service: WeatherService.shared,
                    binding: weatherEnabled
                )
            )
        #endif
        return configs
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?
    @Published var pendingClientName: String = ""

    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []
    private var currentApprovalHandlers: (approve: () -> Void, deny: () -> Void)?
    private let approvalWindowController = ConnectionApprovalWindowController()

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("mailEnabled") private var mailEnabled = false
    @AppStorage("mapsEnabled") private var mapsEnabled = true  // Default enabled
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("notesEnabled") private var notesEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("shortcutsEnabled") private var shortcutsEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default enabled
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    // MARK: - AppStorage for Trusted Clients
    @AppStorage("trustedClients") private var trustedClientsData = Data()

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            captureEnabled: $captureEnabled,
            contactsEnabled: $contactsEnabled,
            locationEnabled: $locationEnabled,
            mailEnabled: $mailEnabled,
            mapsEnabled: $mapsEnabled,
            messagesEnabled: $messagesEnabled,
            notesEnabled: $notesEnabled,
            remindersEnabled: $remindersEnabled,
            shortcutsEnabled: $shortcutsEnabled,
            utilitiesEnabled: $utilitiesEnabled,
            weatherEnabled: $weatherEnabled
        )
    }

    private var currentServiceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    // MARK: - Trusted Clients Management
    private var trustedClients: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: trustedClientsData)) ?? []
        }
        set {
            trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isClientTrusted(_ clientName: String) -> Bool {
        trustedClients.contains(clientName)
    }

    private func addTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.insert(clientName)
        trustedClients = clients
    }

    func removeTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.remove(clientName)
        trustedClients = clients
    }

    func getTrustedClients() -> [String] {
        Array(trustedClients).sorted()
    }

    func resetTrustedClients() {
        trustedClients = Set<String>()
    }

    // MARK: - Connection Approval Methods
    private func cleanupApprovalState() {
        pendingClientName = ""
        currentApprovalHandlers = nil

        if let clientID = pendingConnectionID {
            activeApprovalDialogs.remove(clientID)
            pendingConnectionID = nil
        }
    }

    private func handlePendingApprovals(for clientID: String, approved: Bool) {
        while let pendingIndex = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
            let (_, pendingApprove, pendingDeny) = pendingApprovals.remove(at: pendingIndex)
            if approved {
                log.notice("Approving pending connection for client: \(clientID)")
                pendingApprove()
            } else {
                log.notice("Denying pending connection for client: \(clientID)")
                pendingDeny()
            }
        }
    }

    init() {
        Task { [weak self] in
            guard let self else { return }

            // Initialize bindings from AppStorage before the server starts.
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await self.networkManager.start()
            self.updateServerStatus("Running")

            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo in
                guard let self = self else {
                    return false
                }

                log.debug("ServerManager: Approval handler called for client \(clientInfo.name)")

                // Bridge approval UI actions back into the async handler.
                return await withCheckedContinuation { continuation in
                    let resumeGate = ResumeGate()
                    let resumeOnce: (Bool) async -> Void = { value in
                        guard await resumeGate.shouldResume() else { return }
                        continuation.resume(returning: value)
                    }

                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            clientID: clientInfo.name,
                            approve: {
                                Task { await resumeOnce(true) }
                            },
                            deny: {
                                Task { await resumeOnce(false) }
                            }
                        )
                    }
                }
            }
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        // Called by the UI when service toggles change.
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        await networkManager.start()
        updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        updateServerStatus("Stopped")
    }

    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    private func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

    private func sendClientConnectionNotification(clientName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Client Connected"
        content.body = "Client '\(clientName)' has connected to Apple Core"
        content.threadIdentifier = "client-connection-\(clientName)"

        let request = UNNotificationRequest(
            identifier: "client-connection-\(clientName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log.error("Failed to send notification: \(error.localizedDescription)")
            } else {
                log.info("Sent notification for client connection: \(clientName)")
            }
        }
    }

    private func showConnectionApprovalAlert(
        clientID: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")

        // Trusted clients auto-approve without showing the dialog.
        if isClientTrusted(clientID) {
            log.notice("Client \(clientID) is already trusted, auto-approving")
            approve()

            // Notify the user on auto-approved connections.
            sendClientConnectionNotification(clientName: clientID)

            return
        }

        self.pendingConnectionID = clientID

        // Coalesce concurrent approvals for the same client.
        guard !activeApprovalDialogs.contains(clientID) else {
            log.info("Adding to pending approvals for client: \(clientID)")
            pendingApprovals.append((clientID, approve, deny))
            return
        }

        activeApprovalDialogs.insert(clientID)

        // Present the approval window and wire callbacks.
        pendingClientName = clientID
        currentApprovalHandlers = (approve: approve, deny: deny)

        approvalWindowController.showApprovalWindow(
            clientName: clientID,
            onApprove: { alwaysTrust in
                if alwaysTrust {
                    self.addTrustedClient(clientID)

                    // Ask for notification permission to alert on future trusted connections.
                    UNUserNotificationCenter.current().requestAuthorization(options: [
                        .alert, .sound, .badge,
                    ]) { granted, error in
                        if let error = error {
                            log.error(
                                "Failed to request notification permissions: \(error.localizedDescription)"
                            )
                        } else {
                            log.info("Notification permissions granted: \(granted)")
                        }
                    }
                }

                approve()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: true)
            },
            onDeny: {
                deny()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: false)
            }
        )

        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Connection Management Components
//
// Bonjour discovery + raw NWConnection have been replaced by an HTTP/SSE
// transport ported from Bridgeport (see App/Services/Serving/). The MCP
// dispatch logic below (`registerHandlers(for:connectionID:)`) is
// unchanged: it still takes any `MCP.Server` and works regardless of the
// transport wired to it. Only the transport construction and the
// discovery/connection-acceptance plumbing around it changed.

// Manages a single MCP connection/session.
actor MCPConnectionManager {
    private let connectionID: UUID
    private let accessSurface: MCPAccessSurface
    private let transport: SSETransport
    private let server: MCP.Server
    private let parentManager: ServerNetworkManager

    /// The HTTP/SSE-facing half of this connection. AppleCoreHTTPServer
    /// plumbs request/response bytes through this; MCPConnectionManager
    /// only ever talks to `transport`.
    nonisolated let sseSession: MCPSSESession

    init(connectionID: UUID, accessSurface: MCPAccessSurface, parentManager: ServerNetworkManager) {
        self.connectionID = connectionID
        self.accessSurface = accessSurface
        self.parentManager = parentManager

        let transport = SSETransport()
        self.transport = transport
        self.sseSession = MCPSSESession(id: connectionID.uuidString.lowercased(), transport: transport)

        // MCP server instance for this connection.
        self.server = MCP.Server(
            name: Bundle.main.name ?? "Apple Core",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        do {
            await sseSession.start(onClose: { [parentManager, connectionID] in
                Task { await parentManager.removeConnection(connectionID) }
            })

            log.notice("Starting MCP server for connection: \(self.connectionID)")
            try await server.start(transport: transport) { [weak self] clientInfo, capabilities in
                guard let self = self else { throw MCPError.connectionClosed }

                log.info("Received initialize request from client: \(clientInfo.name)")

                // Request user approval for the connection.
                let approved = await approvalHandler(clientInfo)
                log.info(
                    "Approval result for connection \(connectionID): \(approved ? "Approved" : "Denied")"
                )

                if !approved {
                    await self.parentManager.removeConnection(self.connectionID)
                    throw MCPError.connectionClosed
                }
            }

            log.notice("MCP Server started successfully for connection: \(self.connectionID)")

            // Register handlers after successful approval.
            await registerHandlers()
        } catch {
            log.error("Failed to start MCP server: \(error.localizedDescription)")
            throw error
        }
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(
            for: server,
            connectionID: connectionID,
            accessSurface: accessSurface
        )
    }

    func notifyToolListChanged() async {
        do {
            log.info("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            log.error("Failed to notify client of tool list change: \(error)")
            // The SSE stream underneath is gone; let the idle reaper (or the
            // session's onClose callback) clean up the connection entry.
        }
    }

    func stop() async {
        await server.stop()
        await sseSession.close()
    }
}

actor ServerNetworkManager {
    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true
    private var httpServer: AppleCoreHTTPServer?
    private var serverTask: Task<Void, Never>?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]
    private var servingConfig = AppleCoreServingConfig()

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func start() async {
        log.info("Starting network manager")
        isRunningState = true

        let servingConfig = Self.bootstrappedServingConfig()
        self.servingConfig = servingConfig
        let httpServer = AppleCoreHTTPServer(config: servingConfig)
        self.httpServer = httpServer

        await httpServer.setSessionFactory { [weak self] sessionID, accessSurface in
            guard let self else {
                // Should not happen: the HTTP server is owned by (and only
                // ever started from) this actor. Fabricate a disconnected
                // session rather than crash.
                let orphanTransport = SSETransport()
                return MCPSSESession(id: sessionID, transport: orphanTransport)
            }
            return await self.handleNewConnection(sessionID: sessionID, accessSurface: accessSurface)
        }

        await httpServer.setSessionCloseHandler { [weak self] sessionID in
            guard let self, let connectionID = UUID(uuidString: sessionID) else { return }
            Task { await self.removeConnection(connectionID) }
        }

        serverTask = Task {
            do {
                try await httpServer.start()
            } catch {
                log.error("HTTP/SSE server failed: \(error.localizedDescription)")
            }
        }
    }

    /// Loads the persisted serving config, generating and persisting a
    /// bearer token on first run if one isn't set yet. A token is only
    /// strictly required once the user opts into public (Cloudflare tunnel)
    /// exposure; see `AppleCoreHTTPServer.isAuthorized`.
    private static func bootstrappedServingConfig() -> AppleCoreServingConfig {
        var config = ServingConfigManager.load()
        var changed = false

        if config.token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            config.token = ServingConfigManager.generateSecureToken()
            changed = true
        }
        if config.port == nil {
            config.port = 8756
            changed = true
        }
        if config.bindHost == nil {
            config.bindHost = "127.0.0.1"
            changed = true
        }
        if config.allowedOrigins == nil {
            config.allowedOrigins = ServingConfigManager.defaultAllowedOrigins(
                port: config.port ?? 8756,
                publicBaseURL: config.publicBaseURL
            )
            changed = true
        }

        if changed {
            ServingConfigManager.save(config)
        }
        return config
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunningState = false

        for (id, connectionManager) in connections {
            log.debug("Stopping connection: \(id)")
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()

        await httpServer?.stop()
        serverTask?.cancel()
        serverTask = nil
    }

    func removeConnection(_ id: UUID) async {
        log.debug("Removing connection: \(id)")

        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        if let task = connectionTasks[id] {
            task.cancel()
        }

        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
    }

    // Handle a newly opened HTTP/SSE session: build its MCP.Server +
    // transport, kick off the approval/registration flow in the
    // background, and hand the session's HTTP-facing half back to
    // AppleCoreHTTPServer so it can plumb request/response bytes.
    private func handleNewConnection(
        sessionID: String,
        accessSurface: MCPAccessSurface
    ) async -> MCPSSESession {
        let connectionID = UUID(uuidString: sessionID) ?? UUID()
        log.info("Handling new connection: \(connectionID)")

        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            accessSurface: accessSurface,
            parentManager: self
        )

        connections[connectionID] = connectionManager

        // Drive the MCP handshake and approval flow.
        let task = Task {
            // Ensure this task is removed so the timeout logic doesn't fire afterward.
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
            }

            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting connection")
                    await removeConnection(connectionID)
                    return
                }

                try await connectionManager.start { clientInfo in
                    await approvalHandler(connectionID, clientInfo)
                }

                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

            // If the setup task is still registered, treat it as timed out.
            if self.connectionTasks[connectionID] != nil,
                self.connections[connectionID] != nil
            {
                log.warning(
                    "Connection \(connectionID) setup timed out (task still in registry), closing it"
                )
                await removeConnection(connectionID)
            }
        }

        return connectionManager.sseSession
    }

    func registerHandlers(
        for server: MCP.Server,
        connectionID: UUID,
        accessSurface: MCPAccessSurface
    ) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            log.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        await server.withMethodHandler(ListResources.self) { _ in
            log.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }

            log.debug("Handling ListTools request for \(connectionID)")

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Read binding on the actor for consistency.
                    if await self.isServiceAccessible(serviceId, surface: accessSurface) {
                        for tool in service.tools {
                            log.debug("Adding tool: \(tool.name)")
                            do {
                                tools.append(
                                    .init(
                                        name: tool.name,
                                        description: tool.description,
                                        inputSchema: try encodeSchemaAsValue(tool.inputSchema),
                                        annotations: tool.annotations,
                                        outputSchema: try encodeSchemaAsValue(tool.outputSchema)
                                    )
                                )
                            } catch {
                                log.error(
                                    "Failed to encode input schema for tool \(tool.name): \(error)"
                                )
                            }
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(
                    content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            log.notice("Tool call received from \(connectionID): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: Apple Core is disabled")
                return CallTool.Result(
                    content: [
                        .text(
                            text: "Apple Core is currently disabled. Please enable it to use tools.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            for service in await self.services {
                let serviceId = String(describing: type(of: service))

                // Read binding on the actor for consistency.
                if await self.isServiceAccessible(serviceId, surface: accessSurface) {
                    do {
                        guard
                            let value = try await service.call(
                                tool: params.name,
                                with: params.arguments ?? [:]
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        switch value {
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("audio/"):
                            return CallTool.Result(
                                content: [
                                    .audio(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                structuredContent: .object(["result": value]),
                                isError: false
                            )
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("image/"):
                            return CallTool.Result(
                                content: [
                                    .image(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                structuredContent: .object(["result": value]),
                                isError: false
                            )
                        default:
                            let encoder = JSONEncoder()
                            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                                TimeZone.current
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                            let data = try encoder.encode(value)
                            let text = String(data: data, encoding: .utf8)!

                            return CallTool.Result(
                                content: [.text(text: text, annotations: nil, _meta: nil)],
                                structuredContent: .object(["result": value]),
                                isError: false
                            )
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)"
                        )
                        return CallTool.Result(
                            content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [
                    .text(
                        text: "Tool not found or service not enabled: \(params.name)",
                        annotations: nil,
                        _meta: nil
                    )
                ],
                isError: true
            )
        }
    }

    private func isServiceAccessible(_ serviceID: String, surface: MCPAccessSurface) -> Bool {
        let isLocallyEnabled = serviceBindings[serviceID]?.wrappedValue ?? false
        let isExposedRemotely = servingConfig.settings(forServiceID: serviceID).exposePublicly
        return ServiceAccessPolicy.isAccessible(
            isLocallyEnabled: isLocallyEnabled,
            surface: surface,
            isExposedRemotely: isExposedRemotely
        )
    }

    // Update the enabled state and notify clients.
    func setEnabled(_ enabled: Bool) async {
        // Only act on changes.
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.info("Apple Core enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed.
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update service bindings.
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        self.serviceBindings = newBindings

        // Notify clients that tool availability may have changed.
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }
}
