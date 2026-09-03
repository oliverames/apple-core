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
    let permissionRequirements: [ServicePermissionRequirement]
    let binding: Binding<Bool>

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        let serviceTypeName = String(describing: type(of: service))
        guard
            let permissionRequirements = ServicePermissionInventory.requirements(
                forServiceTypeName: serviceTypeName
            )
        else {
            preconditionFailure("Missing permission inventory for \(serviceTypeName)")
        }
        self.id = serviceTypeName
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.permissionRequirements = permissionRequirements
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            CalendarService.shared,
            CaptureService.shared,
            ContactsService.shared,
            FilesystemService.shared,
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
        filesystemEnabled: Binding<Bool>,
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
                name: "Filesystem",
                iconName: "folder.fill",
                color: .teal,
                service: FilesystemService.shared,
                binding: filesystemEnabled
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

struct TrustedOAuthClient: Codable, Hashable, Identifiable {
    let clientID: String
    let displayName: String

    var id: String { clientID }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?
    @Published var pendingClientName: String = ""

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("filesystemEnabled") private var filesystemEnabled = false
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
    // The previous `trustedClients` value contained only self-reported MCP
    // names. It is deliberately not migrated into active trust.
    @AppStorage("trustedOAuthClientsV2") private var trustedClientsData = Data()

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            captureEnabled: $captureEnabled,
            contactsEnabled: $contactsEnabled,
            filesystemEnabled: $filesystemEnabled,
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
    private var trustedClients: Set<TrustedOAuthClient> {
        get {
            (try? JSONDecoder().decode(Set<TrustedOAuthClient>.self, from: trustedClientsData)) ?? []
        }
        set {
            trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isClientTrusted(_ principal: AuthenticatedPrincipal) -> Bool {
        let key = principal.trustKey
        return trustedClients.contains { $0.clientID == key }
    }

    private func addTrustedClient(_ principal: AuthenticatedPrincipal) {
        // Keyed on `trustKey`, not `trustedClientID`: the latter is nil for
        // the shared token, which used to make "always trust" impossible to
        // honour. Approving then silently forgetting is worse than not
        // offering the choice, and it is what sent people back to the dialog
        // on every reconnect.
        let key = principal.trustKey
        let displayName = principal.trustDisplayName
        var clients = trustedClients
        clients = Set(clients.filter { $0.clientID != key })
        clients.insert(TrustedOAuthClient(clientID: key, displayName: displayName))
        trustedClients = clients
    }

    func removeTrustedClient(_ clientID: String) {
        var clients = trustedClients
        clients = Set(clients.filter { $0.clientID != clientID })
        trustedClients = clients
    }

    func getTrustedClients() -> [TrustedOAuthClient] {
        Array(trustedClients).sorted {
            if $0.displayName == $1.displayName { return $0.clientID < $1.clientID }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// The shared token's trust entry, when it has one.
    ///
    /// Surfaced on its own because it is not a registered OAuth client and so
    /// never appears in that list. Trust you cannot see is trust you cannot
    /// withdraw, and this grant covers anything holding the token.
    func sharedTokenTrust() -> TrustedOAuthClient? {
        trustedClients.first { $0.clientID.hasPrefix("shared-token:") }
    }

    func revokeSharedTokenTrust() {
        trustedClients = Set(trustedClients.filter { !$0.clientID.hasPrefix("shared-token:") })
    }

    func resetTrustedClients() {
        trustedClients = Set<TrustedOAuthClient>()
    }

    func disconnectOAuthClient(_ clientID: String) async throws {
        _ = try await networkManager.disconnectOAuthClient(clientID)
        removeTrustedClient(clientID)
    }

    func registeredOAuthClients() async -> [OAuthRegisteredClient] {
        await networkManager.registeredOAuthClients()
    }

    func signedInOAuthClientIDs() async -> Set<String> {
        await networkManager.signedInOAuthClientIDs()
    }

    func disconnectAllOAuthClients() async throws {
        let clients = await networkManager.registeredOAuthClients()
        var failures: [String] = []
        for client in clients {
            do {
                _ = try await networkManager.disconnectOAuthClient(client.clientID)
                removeTrustedClient(client.clientID)
            } catch {
                failures.append(client.clientName)
            }
        }
        if !failures.isEmpty {
            throw OAuthTokenStoreError.persistenceFailed(
                "Could not disconnect \(failures.joined(separator: ", ")). Other OAuth clients were disconnected."
            )
        }
    }

    // MARK: - Connection Approval Methods

    /// One queued approval request. The window controller is shared, so
    /// dialogs are presented strictly one at a time; concurrent requests
    /// wait here instead of overwriting each other's callbacks.
    private struct ApprovalRequest {
        let connectionID: UUID
        let subjectID: String
        let displayName: String
        let authenticationDetail: String
        let principal: AuthenticatedPrincipal
        let approve: () -> Void
        let deny: () -> Void
    }

    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []
    private var approvalDialogQueue: [ApprovalRequest] = []
    private var visibleApprovalRequest: ApprovalRequest?
    private var isApprovalDialogVisible = false
    private let approvalWindowController = ConnectionApprovalWindowController()

    private func handlePendingApprovals(for subjectID: String, approved: Bool) {
        while let pendingIndex = pendingApprovals.firstIndex(where: { $0.0 == subjectID }) {
            let (_, pendingApprove, pendingDeny) = pendingApprovals.remove(at: pendingIndex)
            if approved {
                log.notice("Approving pending connection for authenticated subject: \(subjectID)")
                pendingApprove()
            } else {
                log.notice("Denying pending connection for authenticated subject: \(subjectID)")
                pendingDeny()
            }
        }
    }

    /// Resolves the dialog that is currently on screen, then presents the
    /// next queued one, if any.
    private func finishActiveApproval(for request: ApprovalRequest, approved: Bool) {
        isApprovalDialogVisible = false
        if visibleApprovalRequest?.connectionID == request.connectionID {
            visibleApprovalRequest = nil
        }
        activeApprovalDialogs.remove(request.subjectID)

        if pendingConnectionID == request.subjectID {
            pendingConnectionID = nil
            pendingClientName = ""
        }

        handlePendingApprovals(for: request.subjectID, approved: approved)
        presentNextApprovalIfNeeded()
    }

    /// A connection whose dialog was pending disappeared before anyone
    /// answered (client gave up, transport died). Deny it so its setup task
    /// finishes instead of parking forever, dismiss the window if it was on
    /// screen, and move on to whatever is queued.
    func approvalConnectionDropped(_ connectionID: UUID) {
        if let index = approvalDialogQueue.firstIndex(where: { $0.connectionID == connectionID }) {
            let request = approvalDialogQueue.remove(at: index)
            activeApprovalDialogs.remove(request.subjectID)
            log.info(
                "Connection for pending approval of \(request.subjectID) dropped; resolving as denied"
            )
            request.deny()
            // Anything that arrived while this one held the subject was
            // coalesced onto it and is waiting for its answer. Denying only
            // the dropped request would leave those continuations parked for
            // the life of the process. This became reachable for the shared
            // token once its approval subject stopped being unique per
            // connection, which is exactly when connections coalesce.
            handlePendingApprovals(for: request.subjectID, approved: false)
        }

        if let current = visibleApprovalRequest, current.connectionID == connectionID {
            // resolveVisibleDialogAsDenied runs the wired onDeny callback,
            // which itself denies the request and finishes this approval
            // slot; only fall back to finishing here if the window had
            // already moved on to a different request.
            visibleApprovalRequest = nil
            if !approvalWindowController.resolveVisibleDialogAsDenied(clientName: current.displayName) {
                current.deny()
                finishActiveApproval(for: current, approved: false)
            }
        }
    }

    private func presentNextApprovalIfNeeded() {
        guard !isApprovalDialogVisible, let next = approvalDialogQueue.first else {
            return
        }
        approvalDialogQueue.removeFirst()

        isApprovalDialogVisible = true
        visibleApprovalRequest = next
        pendingConnectionID = next.subjectID
        pendingClientName = next.displayName

        approvalWindowController.showApprovalWindow(
            clientName: next.displayName,
            authenticationDetail: next.authenticationDetail,
            canAlwaysTrust: next.principal.canBeTrusted,
            alwaysTrustTitle: next.principal.alwaysTrustTitle,
            alwaysTrustDetail: next.principal.alwaysTrustDetail,
            onApprove: { [weak self] alwaysTrust in
                guard let self else { return }
                if alwaysTrust {
                    self.addTrustedClient(next.principal)

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

                next.approve()
                self.finishActiveApproval(for: next, approved: true)
            },
            onDeny: { [weak self] in
                guard let self else { return }
                next.deny()
                self.finishActiveApproval(for: next, approved: false)
            }
        )

        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        Task { [weak self] in
            guard let self else { return }

            // A connection whose approval dialog is pending may vanish
            // before anyone answers; resolve that dialog instead of leaving
            // it on screen forever.
            await networkManager.setApprovalDropHandler { [weak self] connectionID in
                Task { @MainActor in
                    self?.approvalConnectionDropped(connectionID)
                }
            }

            // Initialize bindings from AppStorage before the server starts.
            await networkManager.updateServiceBindings(self.currentServiceBindings)

            // The OAuth authorization page can grant the same durable trust
            // as the dialog's "Always trust", from wherever the person is.
            await networkManager.setTrustGrantHandler { [weak self] principal in
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.addTrustedClient(principal)
                    log.notice("Trusted \(principal.trustKey) from the authorization page")
                }
            }

            // Install the approval handler before the listener opens. A
            // client arriving in the gap between listen and handler-install
            // used to be rejected outright by the nil-handler guard.
            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, principal, clientInfo in
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
                            connectionID: connectionID,
                            principal: principal,
                            reportedClientName: clientInfo.name,
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

            let started = await self.networkManager.start()
            if started {
                self.updateServerStatus("Running")
            } else if let failure = await self.networkManager.lastStartError {
                self.updateServerStatus("Failed to start: \(failure)")
            } else {
                self.updateServerStatus("Failed to start")
            }
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        // Called by the UI when service toggles change.
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        let started = await networkManager.start()
        if started {
            updateServerStatus("Running")
        } else if let failure = await networkManager.lastStartError {
            updateServerStatus("Failed to start: \(failure)")
        } else {
            updateServerStatus("Failed to start")
        }
    }

    /// Startup reconciliation can rewrite serving config after the server
    /// froze its snapshot at launch; bounce the listener so the on-disk
    /// truth wins without waiting for the next relaunch.
    func restartForConfigChange() async {
        await stopServer()
        await startServer()
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
        connectionID: UUID,
        principal: AuthenticatedPrincipal,
        reportedClientName: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) {
        let subjectID: String
        let displayName: String
        let authenticationDetail: String
        switch principal {
        case .sharedBearer:
            // Was `connection:<fresh UUID>`, which made every single
            // connection its own subject: never matching a trusted entry,
            // never coalescing with a concurrent one, and so prompting
            // forever. The token fingerprint is stable across reconnects and
            // changes when the token is rotated.
            subjectID = principal.trustKey
            displayName = reportedClientName
            authenticationDetail =
                "Authenticated with the shared Apple Core token. This name is supplied by the client, "
                + "so trusting it trusts anything that presents the same token."
        case let .oauth(clientID, registeredName):
            subjectID = "oauth:\(clientID)"
            displayName = registeredName
            authenticationDetail =
                reportedClientName == registeredName
                ? "Authenticated OAuth client \(clientID.prefix(12))…"
                : "Authenticated OAuth client \(clientID.prefix(12))…; it reports itself as “\(reportedClientName)”."
        }

        log.notice("Connection approval requested for authenticated subject: \(subjectID)")

        // Trusted clients auto-approve without showing the dialog.
        if isClientTrusted(principal) {
            log.notice("Authenticated subject \(subjectID) is already trusted, auto-approving")
            approve()

            // Notify the user on auto-approved connections.
            sendClientConnectionNotification(clientName: displayName)

            return
        }

        // Coalesce concurrent approvals for the same client: one dialog
        // resolves every queued request from that client.
        guard !activeApprovalDialogs.contains(subjectID) else {
            log.info("Adding to pending approvals for authenticated subject: \(subjectID)")
            pendingApprovals.append((subjectID, approve, deny))
            return
        }
        activeApprovalDialogs.insert(subjectID)

        // One shared window controller means dialogs must be serialized.
        // Queue the request; a second client's dialog appears as soon as the
        // first is answered instead of overwriting its callbacks.
        approvalDialogQueue.append(
            ApprovalRequest(
                connectionID: connectionID,
                subjectID: subjectID,
                displayName: displayName,
                authenticationDetail: authenticationDetail,
                principal: principal,
                approve: approve,
                deny: deny
            )
        )
        presentNextApprovalIfNeeded()
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
    private var connectionsAwaitingApproval: Set<UUID> = []
    private let oauthStore = OAuthTokenStore(
        clientRegistryURL: AppleCoreServingPaths.oauthClientRegistryURL(),
        accessTokenStoreURL: AppleCoreServingPaths.oauthAccessTokenStoreURL()
    )

    /// Set when the most recent `start()` failed to bind. The controller
    /// reads it to report the truth instead of a green "Running".
    private(set) var lastStartError: String?

    /// Thread-safe handoff from the server task (which learns of bind
    /// failures) back to `start()` (which reports status).
    private final class StartFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var message: String?

        func store(_ message: String) {
            lock.lock()
            defer { lock.unlock() }
            self.message = message
        }

        func peek() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return message
        }
    }

    typealias ConnectionApprovalHandler =
        @Sendable (
            UUID,
            AuthenticatedPrincipal,
            MCP.Client.Info
        ) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    /// Fired when a connection goes away; the controller uses it to resolve
    /// an approval dialog whose requester vanished mid-decision.
    private var approvalDropHandler: (@Sendable (UUID) -> Void)?

    func setApprovalDropHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        self.approvalDropHandler = handler
    }

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

    private var trustGrantHandler: AppleCoreHTTPServer.TrustGrantHandler?

    func setTrustGrantHandler(_ handler: @escaping AppleCoreHTTPServer.TrustGrantHandler) {
        self.trustGrantHandler = handler
    }

    /// Starts the HTTP listener. Returns false when the bind failed; the
    /// reason is in `lastStartError`.
    @discardableResult
    func start() async -> Bool {
        // Stop any previous instance first. Overlapping starts used to
        // strand the old listener holding the port while the new one died
        // of EADDRINUSE with nothing but a log line.
        await stop()
        log.info("Starting network manager")
        isRunningState = true
        lastStartError = nil

        let servingConfig = Self.bootstrappedServingConfig()
        self.servingConfig = servingConfig
        let httpServer = AppleCoreHTTPServer(config: servingConfig, oauthStore: oauthStore)
        self.httpServer = httpServer

        await httpServer.setSessionFactory { [weak self] sessionID, accessSurface, principal in
            guard let self else {
                // Should not happen: the HTTP server is owned by (and only
                // ever started from) this actor. Fabricate a disconnected
                // session rather than crash.
                let orphanTransport = SSETransport()
                return MCPSSESession(id: sessionID, transport: orphanTransport)
            }
            return await self.handleNewConnection(
                sessionID: sessionID,
                accessSurface: accessSurface,
                principal: principal
            )
        }

        await httpServer.setSessionCloseHandler { [weak self] sessionID in
            guard let self, let connectionID = UUID(uuidString: sessionID) else { return }
            Task { await self.removeConnection(connectionID) }
        }

        if let trustGrantHandler {
            await httpServer.setTrustGrantHandler(trustGrantHandler)
        }

        let failureBox = StartFailureBox()
        serverTask = Task {
            do {
                try await httpServer.start()
            } catch {
                failureBox.store(error.localizedDescription)
                log.error("HTTP/SSE server failed: \(error.localizedDescription)")
            }
        }

        // FlyingFox binds its socket inside run(): a failed bind throws
        // within moments while a successful listen stays suspended there.
        // Give the bind a brief window to fail before reporting Running;
        // the alternative was a menu bar that claimed "Running" over an
        // EADDRINUSE corpse.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let failure = failureBox.peek() {
            lastStartError = failure
            isRunningState = false
            return false
        }
        return true
    }

    func registeredOAuthClients() async -> [OAuthRegisteredClient] {
        await oauthStore.registeredClients()
    }

    func signedInOAuthClientIDs() async -> Set<String> {
        await oauthStore.signedInClientIDs()
    }

    @discardableResult
    func disconnectOAuthClient(_ clientID: String) async throws -> Bool {
        if let httpServer {
            return try await httpServer.disconnectOAuthClient(clientID)
        }
        return try await oauthStore.removeClient(id: clientID)
    }

    /// Loads the persisted serving config, generating and persisting a
    /// bearer token on first run if one isn't set yet. A token is only
    /// strictly required once the user opts into public (Cloudflare tunnel)
    /// exposure; see `AppleCoreHTTPServer.isAuthorized`.
    private static func bootstrappedServingConfig() -> AppleCoreServingConfig {
        var config = ServingConfigManager.load()
        func fillDefaults(_ config: inout AppleCoreServingConfig) -> Bool {
            let before = config
            if config.token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                config.token = ServingConfigManager.generateSecureToken()
            }
            if config.port == nil {
                config.port = 8756
            }
            if config.bindHost == nil {
                config.bindHost = "127.0.0.1"
            }
            if config.allowedOrigins == nil {
                config.allowedOrigins = ServingConfigManager.defaultAllowedOrigins(
                    port: config.port ?? 8756,
                    publicBaseURL: config.effectivePublicBaseURL
                )
            }
            return before != config
        }

        if fillDefaults(&config) {
            // A corrupt config decodes as all-nil here, which looks exactly
            // like a fresh install. Saving would overwrite the user's
            // recoverable file with generated defaults, so leave it alone.
            if ServingConfigManager.persistedConfigIsUndecodable() {
                log.error(
                    "Serving config on disk is not decodable; running with in-memory defaults and leaving the file untouched"
                )
            } else {
                config =
                    ServingConfigManager.update { latest in
                        _ = fillDefaults(&latest)
                    }?.after ?? config
            }
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

        connectionsAwaitingApproval.remove(id)

        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        approvalDropHandler?(id)

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
        accessSurface: MCPAccessSurface,
        principal: AuthenticatedPrincipal
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
                    // While the human decides, this connection must not be
                    // treated as stalled: the 10-second setup timeout used
                    // to tear down sessions mid-dialog and strand the
                    // approval continuation forever.
                    self.markApprovalPending(connectionID, true)
                    let approved = await approvalHandler(connectionID, principal, clientInfo)
                    self.markApprovalPending(connectionID, false)
                    return approved
                }

                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections. A pending
        // human decision is not a stall.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

            // If the setup task is still registered, treat it as timed out.
            if !self.connectionsAwaitingApproval.contains(connectionID),
                self.connectionTasks[connectionID] != nil,
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

    private func markApprovalPending(_ connectionID: UUID, _ pending: Bool) {
        if pending {
            connectionsAwaitingApproval.insert(connectionID)
        } else {
            connectionsAwaitingApproval.remove(connectionID)
        }
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
                        // `\(error)` prints the raw Swift value — a client
                        // asking for a file outside its allowed folders saw
                        // `outsideAllowedRoots("/etc/hosts")` rather than the
                        // sentence written for exactly that case. Every
                        // LocalizedError in the app defines errorDescription;
                        // localizedDescription is what surfaces it.
                        return CallTool.Result(
                            content: [
                                .text(text: error.localizedDescription, annotations: nil, _meta: nil)
                            ],
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
        return ServiceAccessPolicy.isAccessible(isLocallyEnabled: isLocallyEnabled, surface: surface)
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
