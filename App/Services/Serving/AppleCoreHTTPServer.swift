// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported and adapted from Bridgeport's SSEServer.swift. Bridgeport
// multiplexes many named connector subprocesses behind `/:connector/mcp`
// style routes; Apple Core exposes exactly one MCP tool surface (the
// ServiceRegistry), so the connector-keyed routing, connector icon
// artwork, and webhook fan-out are dropped and the routes collapse to a
// single `/sse`, `/message`, `/mcp` set. OAuth 2.1 + PKCE, bearer-token
// auth, origin allowlisting, and the legacy-SSE / Streamable-HTTP dual
// transport are preserved.
//
// Session creation is delegated to a factory closure supplied by
// ServerNetworkManager (see ServerController.swift), which is what wires a
// new session to `MCP.Server` + `registerHandlers(for:connectionID:)` --
// this file only owns HTTP/SSE plumbing, never MCP dispatch.

import FlyingFox
import FlyingSocks
import Foundation

public struct AppleCoreRuntimeStatus: Codable, Sendable {
    public let activeSessions: Int
    public let localURL: String
    public let publicURL: String
    public let publicBaseURLConfigured: Bool
}

public actor AppleCoreHTTPServer {
    /// Builds and starts a new MCP session for a freshly accepted HTTP
    /// connection. The returned `MCPSSESession` is what this HTTP layer uses
    /// to plumb SSE bytes in and out; everything upstream of it (the
    /// `MCP.Server` instance, approval flow, `registerHandlers`) is owned by
    /// ServerNetworkManager.
    public typealias SessionFactory = @Sendable (_ id: String, _ surface: MCPAccessSurface) async -> MCPSSESession

    private let config: AppleCoreServingConfig
    private let oauthStore: OAuthTokenStore
    private var server: HTTPServer?
    private var sessions: [String: MCPSSESession] = [:]
    private var sessionSurfaces: [String: MCPAccessSurface] = [:]
    private var sessionFactory: SessionFactory?
    private var sessionCloseHandler: (@Sendable (String) -> Void)?

    public init(config: AppleCoreServingConfig, oauthStore: OAuthTokenStore? = nil) {
        self.config = config
        self.oauthStore =
            oauthStore
            ?? OAuthTokenStore(
                clientRegistryURL: AppleCoreServingPaths.oauthClientRegistryURL(),
                accessTokenStoreURL: AppleCoreServingPaths.oauthAccessTokenStoreURL()
            )
    }

    /// Set once, before `start()`, by ServerNetworkManager.
    public func setSessionFactory(_ factory: @escaping SessionFactory) {
        self.sessionFactory = factory
    }

    /// Notified whenever this layer drops a session (idle reap or explicit
    /// DELETE), so ServerNetworkManager can retire the matching
    /// `MCPConnectionManager` too.
    public func setSessionCloseHandler(_ handler: @escaping @Sendable (String) -> Void) {
        self.sessionCloseHandler = handler
    }

    public func activeSessionCount() -> Int {
        sessions.count
    }

    public func start() async throws {
        let port = config.port ?? 8756
        let bindHost = config.bindHost ?? "127.0.0.1"
        let server = try makeHTTPServer(bindHost: bindHost, port: port)
        self.server = server

        var handler = RoutedHTTPHandler()

        handler.appendRoute("GET /.well-known/oauth-protected-resource") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-authorization-server") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthAuthorizationServerMetadataResponse(for: request)
        }

        handler.appendRoute("OPTIONS /oauth/register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("POST /oauth/register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthRegisterClient(request)
        }

        handler.appendRoute("OPTIONS /oauth/token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("POST /oauth/token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthToken(request)
        }

        handler.appendRoute("GET /oauth/authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthAuthorizeForm(request)
        }

        handler.appendRoute("POST /oauth/authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthApproveAuthorization(request)
        }

        handler.appendRoute("GET /status") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.statusResponse()
        }

        handler.appendRoute("GET /sse") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.openLegacySSE(request)
        }

        handler.appendRoute("POST /message") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.postLegacyMessage(request)
        }

        handler.appendRoute("GET /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.openStreamableHTTP(request)
        }

        handler.appendRoute("POST /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.postStreamableHTTP(request)
        }

        handler.appendRoute("DELETE /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.deleteStreamableHTTPSession(request)
        }

        handler.appendRoute("*") { _ in
            Self.textResponse(.notFound, "Not Found\n")
        }

        await server.appendRoute("*", to: handler)
        logMessage("Apple Core HTTP/SSE server starting on \(bindHost):\(port)")

        // Reap sessions whose clients disconnected or went silent.
        let reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.reapIdleSessions()
            }
        }
        defer { reaper.cancel() }

        try await server.run()
    }

    public func stop() async {
        await server?.stop()
        server = nil
        for (id, session) in sessions {
            await session.close(callOnClose: false)
            sessionCloseHandler?(id)
        }
        sessions.removeAll()
        sessionSurfaces.removeAll()
    }

    private func reapIdleSessions() async {
        for (id, session) in sessions {
            guard await session.isIdle(olderThan: Self.sessionIdleTimeout) else { continue }
            logMessage("AppleCoreHTTPServer: Closing idle session \(id)")
            sessions.removeValue(forKey: id)
            sessionSurfaces.removeValue(forKey: id)
            await session.close(callOnClose: false)
            sessionCloseHandler?(id)
        }
    }

    private func makeHTTPServer(bindHost: String, port: UInt16) throws -> HTTPServer {
        if bindHost == "127.0.0.1" || bindHost == "localhost" {
            return HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: port))
        }
        if bindHost == "::1" {
            return HTTPServer(address: sockaddr_in6.loopback(port: port))
        }
        if bindHost == "0.0.0.0" {
            return HTTPServer(address: sockaddr_in.inet(port: port))
        }
        if bindHost.contains(":") {
            return HTTPServer(address: try sockaddr_in6.inet6(ip6: bindHost, port: port))
        }
        return HTTPServer(address: try sockaddr_in.inet(ip4: bindHost, port: port))
    }

    // MARK: - OAuth

    private func oauthProtectedResourceMetadataResponse(for request: HTTPRequest) -> HTTPResponse {
        let resource = oauthResourceURL(for: request)
        return Self.jsonResponse(
            .ok,
            [
                "resource": resource,
                "resource_name": "Apple Core MCP",
                "authorization_servers": [oauthIssuer],
                "bearer_methods_supported": ["header"],
                "scopes_supported": ["mcp"],
            ],
            request: request
        )
    }

    private func oauthAuthorizationServerMetadataResponse(for request: HTTPRequest) -> HTTPResponse {
        Self.jsonResponse(
            .ok,
            [
                "issuer": oauthIssuer,
                "authorization_endpoint": "\(oauthIssuer)/oauth/authorize",
                "token_endpoint": "\(oauthIssuer)/oauth/token",
                "registration_endpoint": "\(oauthIssuer)/oauth/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": ["mcp"],
            ],
            request: request
        )
    }

    private func oauthPreflightResponse(for request: HTTPRequest) -> HTTPResponse {
        HTTPResponse(statusCode: .noContent, headers: Self.oauthCORSHeaders(for: request))
    }

    private func oauthRegisterClient(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }

            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Expected a JSON dynamic client registration request.",
                    request: request
                )
            }

            let redirectURIs = object["redirect_uris"] as? [String] ?? []
            guard !redirectURIs.isEmpty,
                redirectURIs.allSatisfy(OAuthSupport.isAllowedRedirectURI)
            else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_redirect_uri",
                    "Redirect URIs must be https URLs or localhost callback URLs.",
                    request: request
                )
            }

            let clientName = (object["client_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = await oauthStore.registerClient(
                clientName: clientName?.isEmpty == false ? clientName! : "Claude",
                redirectURIs: redirectURIs
            )

            return Self.jsonResponse(
                .created,
                [
                    "client_id": client.clientID,
                    "client_id_issued_at": client.issuedAt,
                    "client_name": client.clientName,
                    "redirect_uris": client.redirectURIs,
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none",
                ],
                request: request,
                noStore: true
            )
        } catch {
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_request",
                "Could not read dynamic client registration request.",
                request: request
            )
        }
    }

    private func oauthAuthorizeForm(_ request: HTTPRequest) async -> HTTPResponse {
        let query = OAuthSupport.queryDictionary(request.query.map { URLQueryItem(name: $0.name, value: $0.value) })
        guard let validation = await validatedAuthorizationRequest(query) else {
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_request",
                "Invalid OAuth authorization request.",
                request: request
            )
        }

        return Self.htmlResponse(.ok, authorizationFormHTML(validation: validation, error: nil))
    }

    private func oauthApproveAuthorization(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard let validation = await validatedAuthorizationRequest(form) else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Invalid OAuth authorization request.",
                    request: request
                )
            }

            let approvalToken = form["apple_core_token"] ?? ""
            guard Self.constantTimeEquals(approvalToken, config.token ?? "") else {
                // Slow down online guessing against the approval form; the
                // master token is high-entropy but this endpoint is public.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return Self.htmlResponse(
                    .forbidden,
                    authorizationFormHTML(validation: validation, error: "Apple Core token did not match.")
                )
            }

            guard
                let code = await oauthStore.issueAuthorizationCode(
                    clientID: validation.clientID,
                    redirectURI: validation.redirectURI,
                    codeChallenge: validation.codeChallenge,
                    resource: validation.resource
                )
            else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Could not issue authorization code.",
                    request: request
                )
            }

            guard var components = URLComponents(string: validation.redirectURI) else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_redirect_uri",
                    "Invalid redirect URI.",
                    request: request
                )
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "code", value: code))
            if let state = validation.state, !state.isEmpty {
                queryItems.append(URLQueryItem(name: "state", value: state))
            }
            components.queryItems = queryItems

            var headers = HTTPHeaders()
            headers[HTTPHeader("Location")] = components.url?.absoluteString ?? validation.redirectURI
            return HTTPResponse(statusCode: .seeOther, headers: headers)
        } catch {
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_request",
                "Could not read OAuth authorization approval.",
                request: request
            )
        }
    }

    private func oauthToken(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }
            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            let grantType = form["grant_type"]
            let tokenPair: OAuthTokenPair?

            if grantType == "authorization_code",
                let code = form["code"],
                let clientID = form["client_id"],
                let redirectURI = form["redirect_uri"],
                let verifier = form["code_verifier"]
            {
                tokenPair = await oauthStore.redeemAuthorizationCode(
                    code: code,
                    clientID: clientID,
                    redirectURI: redirectURI,
                    codeVerifier: verifier
                )
            } else if grantType == "refresh_token",
                let refreshToken = form["refresh_token"],
                let clientID = form["client_id"]
            {
                tokenPair = await oauthStore.redeemRefreshToken(
                    refreshToken,
                    clientID: clientID,
                    resource: form["resource"]
                )
            } else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Expected authorization_code with PKCE or refresh_token grant.",
                    request: request
                )
            }

            guard let tokenPair else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_grant",
                    "Authorization code could not be redeemed.",
                    request: request
                )
            }

            return Self.jsonResponse(
                .ok,
                [
                    "access_token": tokenPair.accessToken,
                    "refresh_token": tokenPair.refreshToken,
                    "token_type": "Bearer",
                    "expires_in": Int(OAuthTokenStore.accessTokenLifetime),
                    "scope": "mcp",
                ],
                request: request,
                noStore: true
            )
        } catch {
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_request",
                "Could not read OAuth token request.",
                request: request
            )
        }
    }

    // MARK: - Legacy SSE

    private func openLegacySSE(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let (session, surface) = try await makeSession(for: request)
            let endpointEvent = "event: endpoint\ndata: /message?sessionId=\(session.id)\n\n"
            let (_, stream) = await session.addPersistentStream(initialEvents: [endpointEvent])
            registerSession(session, surface: surface)
            return sseResponse(stream: stream, sessionId: session.id)
        } catch AppleCoreHTTPServerError.tooManySessions {
            return Self.sessionCapacityResponse()
        } catch {
            logMessage("AppleCoreHTTPServer: Failed to open legacy SSE: \(error)")
            return Self.textResponse(.internalServerError, "Failed to start MCP session\n")
        }
    }

    private func postLegacyMessage(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.query.first(where: { $0.name == "sessionId" })?.value,
            !sessionId.isEmpty
        else {
            return Self.textResponse(.badRequest, "Missing sessionId parameter\n")
        }

        guard let session = sessions[sessionId] else {
            return Self.textResponse(.notFound, "Session not found\n")
        }
        guard sessionSurfaces[sessionId] == requestSurface(for: request) else {
            return Self.textResponse(.forbidden, "Session access surface changed\n")
        }

        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let bodyData = try await request.bodyData
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                return Self.textResponse(.badRequest, "Invalid UTF-8 body\n")
            }
            await session.writeToServer(bodyString)
            return HTTPResponse(statusCode: .accepted)
        } catch {
            return Self.textResponse(.internalServerError, "Failed to read request body\n")
        }
    }

    // MARK: - Streamable HTTP

    private func openStreamableHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let session: MCPSSESession
            let surface: MCPAccessSurface
            switch resolveSession(request) {
            case .notFound:
                return Self.textResponse(.notFound, "Session not found\n")
            case .scopeMismatch:
                return Self.textResponse(.forbidden, "Session access surface changed\n")
            case .existing(let existing, let existingSurface):
                session = existing
                surface = existingSurface
            case .new(let newSurface):
                (session, surface) = try await makeSession(surface: newSurface)
            }
            registerSession(session, surface: surface)
            let (_, stream) = await session.addPersistentStream()
            return sseResponse(stream: stream, sessionId: session.id)
        } catch AppleCoreHTTPServerError.tooManySessions {
            return Self.sessionCapacityResponse()
        } catch {
            logMessage("AppleCoreHTTPServer: Failed to open streamable HTTP: \(error)")
            return Self.textResponse(.internalServerError, "Failed to start MCP session\n")
        }
    }

    private func postStreamableHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let bodyData = try await request.bodyData
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                return Self.textResponse(.badRequest, "Invalid UTF-8 body\n")
            }

            let session: MCPSSESession
            let surface: MCPAccessSurface
            switch resolveSession(request) {
            case .notFound:
                return Self.textResponse(.notFound, "Session not found\n")
            case .scopeMismatch:
                return Self.textResponse(.forbidden, "Session access surface changed\n")
            case .existing(let existing, let existingSurface):
                session = existing
                surface = existingSurface
            case .new(let newSurface):
                (session, surface) = try await makeSession(surface: newSurface)
            }
            registerSession(session, surface: surface)

            guard let requestId = MCPSSESession.jsonRPCID(from: bodyString) else {
                await session.writeToServer(bodyString)
                var headers = HTTPHeaders()
                headers[Self.sessionHeader] = session.id
                return HTTPResponse(statusCode: .accepted, headers: headers)
            }

            let responseStream = await session.responseStream(for: requestId)
            await session.writeToServer(bodyString)
            return sseResponse(stream: responseStream, sessionId: session.id)
        } catch AppleCoreHTTPServerError.tooManySessions {
            return Self.sessionCapacityResponse()
        } catch {
            logMessage("AppleCoreHTTPServer: Streamable HTTP POST failed: \(error)")
            return Self.textResponse(.internalServerError, "Failed to process message\n")
        }
    }

    private func deleteStreamableHTTPSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.headers[Self.sessionHeader],
            let session = sessions[sessionId]
        else {
            return Self.textResponse(.notFound, "Session not found\n")
        }
        guard sessionSurfaces[sessionId] == requestSurface(for: request) else {
            return Self.textResponse(.forbidden, "Session access surface changed\n")
        }
        sessions.removeValue(forKey: sessionId)
        sessionSurfaces.removeValue(forKey: sessionId)
        await session.close(callOnClose: false)
        sessionCloseHandler?(sessionId)
        return HTTPResponse(statusCode: .accepted)
    }

    private func statusResponse() async -> HTTPResponse {
        let port = config.port ?? 8756
        let baseURL = ServingConfigManager.clientEndpointBaseURL(port: port, publicBaseURL: config.publicBaseURL)
        let hasPublicBaseURL = config.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let status = AppleCoreRuntimeStatus(
            activeSessions: sessions.count,
            localURL: "http://localhost:\(port)/mcp",
            publicURL: hasPublicBaseURL ? "\(baseURL)/mcp" : "",
            publicBaseURLConfigured: hasPublicBaseURL
        )

        do {
            let data = try JSONEncoder().encode(status)
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: data)
        } catch {
            return Self.textResponse(.internalServerError, "Failed to encode status\n")
        }
    }

    private static func sessionCapacityResponse() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        headers[HTTPHeader("Retry-After")] = "30"
        return HTTPResponse(
            statusCode: .serviceUnavailable,
            headers: headers,
            body: Data("Too many active sessions\n".utf8)
        )
    }

    private func registerSession(_ session: MCPSSESession, surface: MCPAccessSurface) {
        sessions[session.id] = session
        sessionSurfaces[session.id] = surface
    }

    private func makeSession(for request: HTTPRequest) async throws -> (MCPSSESession, MCPAccessSurface) {
        try await makeSession(surface: requestSurface(for: request))
    }

    private func makeSession(surface: MCPAccessSurface) async throws -> (MCPSSESession, MCPAccessSurface) {
        guard let sessionFactory else {
            throw AppleCoreHTTPServerError.sessionFactoryNotConfigured
        }
        guard sessions.count < Self.maxSessions else {
            throw AppleCoreHTTPServerError.tooManySessions
        }

        let id = UUID().uuidString.lowercased()
        let session = await sessionFactory(id, surface)
        return (session, surface)
    }

    private enum SessionResolution {
        case new(MCPAccessSurface)
        case existing(MCPSSESession, MCPAccessSurface)
        case scopeMismatch
        case notFound
    }

    /// A request without an Mcp-Session-Id header starts a new session. A
    /// request with one must reference a live session; otherwise the client
    /// gets 404 and re-initializes per the Streamable HTTP spec.
    private func resolveSession(_ request: HTTPRequest) -> SessionResolution {
        let surface = requestSurface(for: request)
        guard let sessionId = request.headers[Self.sessionHeader], !sessionId.isEmpty else {
            return .new(surface)
        }
        guard let session = sessions[sessionId], let originalSurface = sessionSurfaces[sessionId] else {
            return .notFound
        }
        guard originalSurface == surface else {
            return .scopeMismatch
        }
        return .existing(session, originalSurface)
    }

    private func requestSurface(for request: HTTPRequest) -> MCPAccessSurface {
        RequestAccessClassifier.surface(
            hostHeader: request.headers[Self.hostHeader],
            forwardedForHeader: request.headers[Self.forwardedForHeader],
            connectingIPHeader: request.headers[Self.connectingIPHeader]
        )
    }

    // MARK: - Shared helpers

    private var oauthIssuer: String {
        ServingConfigManager.clientEndpointBaseURL(port: config.port ?? 8756, publicBaseURL: config.publicBaseURL)
    }

    private func oauthResourceURL(for request: HTTPRequest) -> String {
        let metadataPrefix = "/.well-known/oauth-protected-resource"
        if request.path.hasPrefix(metadataPrefix) {
            let suffix = String(request.path.dropFirst(metadataPrefix.count))
            return suffix.isEmpty ? oauthIssuer : "\(oauthIssuer)\(suffix)"
        }
        return "\(oauthIssuer)\(request.path)"
    }

    private func oauthProtectedResourceMetadataURL(for request: HTTPRequest) -> String {
        "\(oauthIssuer)/.well-known/oauth-protected-resource\(request.path)"
    }

    private func isAllowedOAuthResource(_ resource: String) -> Bool {
        guard let resourceComponents = URLComponents(string: resource),
            let issuerComponents = URLComponents(string: oauthIssuer),
            resourceComponents.scheme?.lowercased() == issuerComponents.scheme?.lowercased(),
            resourceComponents.host?.lowercased() == issuerComponents.host?.lowercased(),
            resourceComponents.port == issuerComponents.port
        else {
            return false
        }

        let pathComponents = resourceComponents.path.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init
        )
        return pathComponents == ["mcp"]
    }

    private func validatedAuthorizationRequest(_ values: [String: String]) async -> OAuthAuthorizationValidation? {
        guard values["response_type"] == "code",
            values["code_challenge_method"] == "S256",
            let clientID = values["client_id"],
            let redirectURI = values["redirect_uri"],
            let codeChallenge = values["code_challenge"],
            !codeChallenge.isEmpty,
            let resource = values["resource"],
            isAllowedOAuthResource(resource)
        else {
            return nil
        }

        var client = await oauthStore.client(id: clientID)
        if client == nil {
            client = await oauthStore.adoptClientIfNeeded(
                clientID: clientID,
                clientName: Self.oauthClientName(from: redirectURI),
                redirectURI: redirectURI
            )
        }
        guard let client, client.redirectURIs.contains(redirectURI) else {
            return nil
        }

        return OAuthAuthorizationValidation(
            clientID: clientID,
            clientName: client.clientName,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: values["state"],
            resource: resource
        )
    }

    private static func oauthClientName(from redirectURI: String) -> String {
        guard let host = URLComponents(string: redirectURI)?.host, !host.isEmpty else {
            return "OAuth client"
        }
        return host
    }

    private func authorizationFormHTML(validation: OAuthAuthorizationValidation, error: String?) -> String {
        let escapedClientName = OAuthSupport.htmlEscaped(validation.clientName)
        let escapedRedirectURI = OAuthSupport.htmlEscaped(validation.redirectURI)
        let escapedClientID = OAuthSupport.htmlEscaped(validation.clientID)
        let escapedCodeChallenge = OAuthSupport.htmlEscaped(validation.codeChallenge)
        let escapedState = OAuthSupport.htmlEscaped(validation.state ?? "")
        let escapedResource = OAuthSupport.htmlEscaped(validation.resource)
        let errorHTML = error.map { "<p class=\"error\">\(OAuthSupport.htmlEscaped($0))</p>" } ?? ""

        return """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Authorize Apple Core</title>
              <style>
                :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
                body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: Canvas; color: CanvasText; }
                main { width: min(440px, calc(100vw - 32px)); border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 14px; padding: 24px; box-shadow: 0 16px 48px color-mix(in srgb, black 16%, transparent); }
                h1 { font-size: 22px; margin: 0 0 10px; }
                p { color: color-mix(in srgb, CanvasText 72%, transparent); line-height: 1.4; }
                label { display: grid; gap: 8px; font-weight: 600; margin-top: 18px; }
                input { font: inherit; border-radius: 9px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 10px 12px; background: Canvas; color: CanvasText; }
                button { font: inherit; font-weight: 700; border: 0; border-radius: 9px; margin-top: 18px; padding: 10px 14px; color: white; background: #0a84ff; }
                .meta { font-size: 13px; }
                .error { color: #b42318; font-weight: 700; }
              </style>
            </head>
            <body>
              <main>
                <h1>Authorize Apple Core</h1>
                <p>Allow <strong>\(escapedClientName)</strong> to use Apple Core's MCP tools from this Mac.</p>
                <p class="meta">Redirect URI: \(escapedRedirectURI)</p>
                \(errorHTML)
                <form method="post" action="/oauth/authorize">
                  <input type="hidden" name="response_type" value="code">
                  <input type="hidden" name="client_id" value="\(escapedClientID)">
                  <input type="hidden" name="redirect_uri" value="\(escapedRedirectURI)">
                  <input type="hidden" name="code_challenge" value="\(escapedCodeChallenge)">
                  <input type="hidden" name="code_challenge_method" value="S256">
                  <input type="hidden" name="state" value="\(escapedState)">
                  <input type="hidden" name="resource" value="\(escapedResource)">
                  <label>
                    Apple Core token
                    <input name="apple_core_token" type="password" autocomplete="off" required>
                  </label>
                  <button type="submit">Authorize</button>
                </form>
              </main>
            </body>
            </html>
            """
    }

    private func sseResponse(stream: AsyncStream<[UInt8]>, sessionId: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [
                .contentType: "text/event-stream",
                HTTPHeader("Cache-Control"): "no-cache",
                HTTPHeader("Connection"): "keep-alive",
                HTTPHeader("Access-Control-Expose-Headers"): "Mcp-Session-Id",
                Self.sessionHeader: sessionId,
            ],
            body: HTTPBodySequence(from: SSEByteSequence(stream: stream))
        )
    }

    private func isRequestAllowed(_ request: HTTPRequest) -> Bool {
        guard let origin = request.headers[Self.originHeader], !origin.isEmpty else {
            return true
        }
        let allowedOrigins = Set(config.allowedOrigins ?? [])
        return allowedOrigins.contains(origin)
    }

    private func isAuthorized(_ request: HTTPRequest) async -> Bool {
        let token = config.token ?? ""
        guard !token.isEmpty else { return false }

        if let authHeader = request.headers[.authorization] {
            if Self.constantTimeEquals(authHeader, "Bearer \(token)") {
                return true
            }

            if authHeader.lowercased().hasPrefix("bearer ") {
                let accessToken = String(authHeader.dropFirst("Bearer ".count))
                if await oauthStore.isValidAccessToken(accessToken, resource: oauthResourceURL(for: request)) {
                    return true
                }
            }
        }

        if config.allowQueryTokenAuth == true,
            let queryToken = request.query.first(where: { $0.name == "token" })?.value,
            Self.constantTimeEquals(queryToken, token)
        {
            return true
        }

        return false
    }

    private static func textResponse(_ statusCode: HTTPStatusCode, _ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/plain"], body: Data(text.utf8))
    }

    private static func htmlResponse(_ statusCode: HTTPStatusCode, _ html: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private static func jsonResponse(
        _ statusCode: HTTPStatusCode,
        _ object: [String: Any],
        request: HTTPRequest,
        noStore: Bool = false
    ) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = oauthCORSHeaders(for: request)
        headers[.contentType] = "application/json"
        if noStore {
            // RFC 6749 requires token responses to be uncacheable.
            headers[HTTPHeader("Cache-Control")] = "no-store"
            headers[HTTPHeader("Pragma")] = "no-cache"
        }
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    private static func oauthErrorResponse(
        _ statusCode: HTTPStatusCode,
        _ error: String,
        _ description: String,
        request: HTTPRequest
    ) -> HTTPResponse {
        jsonResponse(
            statusCode,
            [
                "error": error,
                "error_description": description,
            ],
            request: request
        )
    }

    private static func oauthCORSHeaders(for request: HTTPRequest) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers[HTTPHeader("Access-Control-Allow-Origin")] = request.headers[originHeader] ?? "*"
        headers[HTTPHeader("Access-Control-Allow-Methods")] = "GET, POST, OPTIONS"
        headers[HTTPHeader("Access-Control-Allow-Headers")] = "authorization, content-type, mcp-session-id"
        headers[HTTPHeader("Access-Control-Max-Age")] = "86400"
        return headers
    }

    private func unauthorizedResponse(for request: HTTPRequest) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        let metadataURL = Self.wwwAuthenticateQuotedValue(oauthProtectedResourceMetadataURL(for: request))
        headers[HTTPHeader("WWW-Authenticate")] = "Bearer realm=\"Apple Core\", resource_metadata=\"\(metadataURL)\""
        return HTTPResponse(statusCode: .unauthorized, headers: headers, body: Data("Unauthorized\n".utf8))
    }

    public static func wwwAuthenticateQuotedValue(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\r", "\n":
                continue
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0 ..< maxCount {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(left ^ right)
        }

        return difference == 0
    }

    private static func isContentLengthAllowed(_ request: HTTPRequest) -> Bool {
        guard let rawLength = request.headers[.contentLength],
            let length = Int(rawLength.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return true
        }
        return length <= maxRequestBodyBytes
    }

    private static let sessionHeader = HTTPHeader("Mcp-Session-Id")
    private static let hostHeader = HTTPHeader("Host")
    private static let forwardedForHeader = HTTPHeader("X-Forwarded-For")
    private static let connectingIPHeader = HTTPHeader("CF-Connecting-IP")
    private static let originHeader = HTTPHeader("Origin")
    private static let maxSessions = 64
    private static let maxRequestBodyBytes = 1_048_576
    private static let sessionIdleTimeout: TimeInterval = 600
}

public enum AppleCoreHTTPServerError: Swift.Error {
    case sessionFactoryNotConfigured
    case tooManySessions
}

private struct OAuthAuthorizationValidation: Sendable {
    let clientID: String
    let clientName: String
    let redirectURI: String
    let codeChallenge: String
    let state: String?
    let resource: String
}
