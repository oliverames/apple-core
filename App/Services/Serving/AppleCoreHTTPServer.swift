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

import AppKit
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
    public typealias SessionFactory =
        @Sendable (
            _ id: String,
            _ surface: MCPAccessSurface,
            _ principal: AuthenticatedPrincipal
        ) async -> MCPSSESession

    private let config: AppleCoreServingConfig
    private let oauthStore: OAuthTokenStore
    private let licenseGate: LicenseGate
    private var server: HTTPServer?
    private var sessions: [String: MCPSSESession] = [:]
    private var sessionSurfaces: [String: MCPAccessSurface] = [:]
    private var sessionPrincipals: [String: AuthenticatedPrincipal] = [:]
    private var oauthClientGate = OAuthClientOperationGate()
    private var pendingSessionReservations = 0
    private var sessionFactory: SessionFactory?
    private var sessionCloseHandler: (@Sendable (String) -> Void)?

    /// Records durable trust for a principal, the same grant the connection
    /// dialog's "Always trust" makes. Set by ServerNetworkManager so the
    /// authorization page can make that grant from wherever the person is.
    public typealias TrustGrantHandler = @Sendable (AuthenticatedPrincipal) async -> Void
    private var trustGrantHandler: TrustGrantHandler?

    public init(
        config: AppleCoreServingConfig,
        oauthStore: OAuthTokenStore? = nil,
        licenseGate: LicenseGate? = nil
    ) {
        self.config = config
        self.oauthStore =
            oauthStore
            ?? OAuthTokenStore(
                clientRegistryURL: AppleCoreServingPaths.oauthClientRegistryURL(),
                accessTokenStoreURL: AppleCoreServingPaths.oauthAccessTokenStoreURL()
            )
        self.licenseGate = licenseGate ?? LicenseGate()
    }

    /// Set once, before `start()`, by ServerNetworkManager.
    public func setSessionFactory(_ factory: @escaping SessionFactory) {
        self.sessionFactory = factory
    }

    public func setTrustGrantHandler(_ handler: @escaping TrustGrantHandler) {
        self.trustGrantHandler = handler
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

    @discardableResult
    public func disconnectOAuthClient(_ clientID: String) async throws -> Bool {
        // Block synchronously before the first suspension. Requests that were
        // authenticated just before this administrative action cannot create
        // a new session while the token store write is in flight.
        oauthClientGate.beginDisconnect(for: clientID)
        defer { oauthClientGate.finishDisconnect(for: clientID) }
        let matchingSessionIDs = sessionPrincipals.compactMap { sessionID, principal in
            principal.trustedClientID == clientID ? sessionID : nil
        }
        let matchingSessions = matchingSessionIDs.compactMap { sessionID -> (String, MCPSSESession)? in
            guard let session = sessions.removeValue(forKey: sessionID) else { return nil }
            sessionSurfaces.removeValue(forKey: sessionID)
            sessionPrincipals.removeValue(forKey: sessionID)
            return (sessionID, session)
        }

        let removed: Bool
        do {
            removed = try await oauthStore.removeClient(id: clientID)
        } catch {
            for (sessionID, session) in matchingSessions {
                await session.close(callOnClose: false)
                sessionCloseHandler?(sessionID)
            }
            throw error
        }

        for (sessionID, session) in matchingSessions {
            await session.close(callOnClose: false)
            sessionCloseHandler?(sessionID)
        }
        return removed
    }

    public func start() async throws {
        let port = config.port ?? 8756
        let bindHost = config.bindHost ?? "127.0.0.1"
        let server = try makeHTTPServer(bindHost: bindHost, port: port)
        self.server = server

        var handler = RoutedHTTPHandler()

        handler.appendRoute("GET /") { _ in
            Self.connectorLandingPageResponse()
        }

        handler.appendRoute("HEAD /") { _ in
            Self.connectorLandingPageResponse(headOnly: true)
        }

        handler.appendRoute("GET /favicon-16x16.png") { _ in Self.connectorIconResponse(size: 16) }
        handler.appendRoute("HEAD /favicon-16x16.png") { _ in Self.connectorIconResponse(size: 16, headOnly: true) }
        handler.appendRoute("GET /favicon-32x32.png") { _ in Self.connectorIconResponse(size: 32) }
        handler.appendRoute("HEAD /favicon-32x32.png") { _ in Self.connectorIconResponse(size: 32, headOnly: true) }
        handler.appendRoute("GET /favicon-48x48.png") { _ in Self.connectorIconResponse(size: 48) }
        handler.appendRoute("HEAD /favicon-48x48.png") { _ in Self.connectorIconResponse(size: 48, headOnly: true) }
        handler.appendRoute("GET /favicon-64x64.png") { _ in Self.connectorIconResponse(size: 64) }
        handler.appendRoute("HEAD /favicon-64x64.png") { _ in Self.connectorIconResponse(size: 64, headOnly: true) }
        handler.appendRoute("GET /favicon-96x96.png") { _ in Self.connectorIconResponse(size: 96) }
        handler.appendRoute("HEAD /favicon-96x96.png") { _ in Self.connectorIconResponse(size: 96, headOnly: true) }
        handler.appendRoute("GET /favicon-128x128.png") { _ in Self.connectorIconResponse(size: 128) }
        handler.appendRoute("HEAD /favicon-128x128.png") { _ in Self.connectorIconResponse(size: 128, headOnly: true) }
        handler.appendRoute("GET /favicon-256x256.png") { _ in Self.connectorIconResponse(size: 256) }
        handler.appendRoute("HEAD /favicon-256x256.png") { _ in Self.connectorIconResponse(size: 256, headOnly: true) }

        handler.appendRoute("GET /favicon.ico") { _ in
            Self.connectorIconICOResponse()
        }

        handler.appendRoute("HEAD /favicon.ico") { _ in
            Self.connectorIconICOResponse(headOnly: true)
        }

        handler.appendRoute("GET /apple-touch-icon.png") { _ in
            Self.connectorIconResponse(size: 180)
        }

        handler.appendRoute("HEAD /apple-touch-icon.png") { _ in
            Self.connectorIconResponse(size: 180, headOnly: true)
        }

        handler.appendRoute("GET /assets/apple-core-icon-v1.png") { _ in
            Self.connectorIconResponse(size: 256)
        }

        handler.appendRoute("HEAD /assets/apple-core-icon-v1.png") { _ in
            Self.connectorIconResponse(size: 256, headOnly: true)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        // Some clients build the metadata URL by appending whatever resource
        // path they hold to the well-known prefix. The canonical pointer now
        // always names /mcp, but serving these siblings costs nothing and
        // keeps such discovery attempts off the 404 path.
        handler.appendRoute("GET /.well-known/oauth-protected-resource/sse") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource/message") { [weak self] request in
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

        handler.appendRoute("OPTIONS /oauth/revoke") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("POST /oauth/revoke") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthRevoke(request)
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
            guard await self.authenticate(request) != nil else { return await self.unauthorizedResponse(for: request) }
            return await self.statusResponse()
        }

        // The one activation-aware unauthenticated endpoint: a locked-out
        // client (or a support conversation) can tell "license missing"
        // from "server broken" without a bearer token.
        handler.appendRoute("GET /license-status") { [weak self] _ in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.licenseStatusResponse()
        }

        handler.appendRoute("GET /sse") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard let principal = await self.authenticate(request) else {
                return await self.unauthorizedResponse(for: request)
            }
            guard await self.isLicensed() else { return Self.licenseRequiredResponse() }
            return await self.openLegacySSE(request, principal: principal)
        }

        handler.appendRoute("POST /message") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard let principal = await self.authenticate(request) else {
                return await self.unauthorizedResponse(for: request)
            }
            guard await self.isLicensed() else { return Self.licenseRequiredResponse() }
            return await self.postLegacyMessage(request, principal: principal)
        }

        handler.appendRoute("GET /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard let principal = await self.authenticate(request) else {
                return await self.unauthorizedResponse(for: request)
            }
            guard await self.isLicensed() else { return Self.licenseRequiredResponse() }
            return await self.openStreamableHTTP(request, principal: principal)
        }

        handler.appendRoute("POST /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard let principal = await self.authenticate(request) else {
                return await self.unauthorizedResponse(for: request)
            }
            guard await self.isLicensed() else { return Self.licenseRequiredResponse() }
            return await self.postStreamableHTTP(request, principal: principal)
        }

        handler.appendRoute("DELETE /mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard let principal = await self.authenticate(request) else {
                return await self.unauthorizedResponse(for: request)
            }
            guard await self.isLicensed() else { return Self.licenseRequiredResponse() }
            return await self.deleteStreamableHTTPSession(request, principal: principal)
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
        sessionPrincipals.removeAll()
    }

    private func reapIdleSessions() async {
        for (id, session) in sessions {
            guard await session.isIdle(olderThan: Self.sessionIdleTimeout) else { continue }
            logMessage("AppleCoreHTTPServer: Closing idle session \(id)")
            sessions.removeValue(forKey: id)
            sessionSurfaces.removeValue(forKey: id)
            sessionPrincipals.removeValue(forKey: id)
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
        Self.jsonResponse(
            .ok,
            [
                "resource": oauthMCPResourceURL,
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
                "revocation_endpoint": "\(oauthIssuer)/oauth/revoke",
                "registration_endpoint": "\(oauthIssuer)/oauth/register",
                // Section 6. Without this a client has no way to know it can
                // use its own metadata URL and falls back to registering,
                // which is what fills the client list with duplicates.
                "client_id_metadata_document_supported": true,
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

            guard let data = try await boundedRequestBody(request) else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
                    "Redirect URIs must use HTTPS, a localhost callback, or a reverse-domain native app scheme.",
                    request: request
                )
            }

            let clientName = (object["client_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = try await oauthStore.registerClient(
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
        } catch let error as OAuthTokenStoreError {
            logMessage("AppleCoreHTTPServer: OAuth registration persistence failed: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .internalServerError,
                "server_error",
                "Apple Core could not save the OAuth client registration.",
                request: request
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
        do {
            guard let validation = try await validatedAuthorizationRequest(query) else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Invalid OAuth authorization request.",
                    request: request
                )
            }
            return Self.htmlResponse(.ok, authorizationFormHTML(validation: validation, error: nil))
        } catch let error as ClientIDMetadataError {
            // The client's own identifier or document is at fault, so this is
            // a 400 with the actual reason. It used to fall into the catch
            // below and be reported as the server failing to save something,
            // which named the wrong party and the wrong problem.
            logMessage("AppleCoreHTTPServer: client metadata rejected: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_client",
                error.localizedDescription,
                request: request
            )
        } catch {
            logMessage("AppleCoreHTTPServer: OAuth client adoption persistence failed: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .internalServerError,
                "server_error",
                "Apple Core could not save the OAuth client registration.",
                request: request
            )
        }
    }

    private func oauthApproveAuthorization(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let data = try await boundedRequestBody(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard let validation = try await validatedAuthorizationRequest(form) else {
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

            // The person typing the master token here is the same person the
            // connection dialog would ask on the Mac's screen, so the choice
            // can be made now. A Mac nobody is sitting at has no other way to
            // answer that dialog, and a first connection from a new client
            // used to hang there with no error anywhere the person could see.
            if form["apple_core_trust"] == "on" {
                await trustGrantHandler?(
                    .oauth(clientID: validation.clientID, registeredName: validation.clientName)
                )
                logMessage(
                    "AppleCoreHTTPServer: trusted OAuth client from the authorization page: \(validation.clientID)"
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
        } catch let error as ClientIDMetadataError {
            logMessage("AppleCoreHTTPServer: client metadata rejected: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_client",
                error.localizedDescription,
                request: request
            )
        } catch let error as OAuthTokenStoreError {
            logMessage("AppleCoreHTTPServer: OAuth approval persistence failed: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .internalServerError,
                "server_error",
                "Apple Core could not save the OAuth client registration.",
                request: request
            )
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
            guard let data = try await boundedRequestBody(request) else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard let resource = form["resource"], isAllowedOAuthResource(resource) else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_target",
                    "The resource must exactly match the advertised Apple Core MCP resource.",
                    request: request
                )
            }
            let grantType = form["grant_type"]
            let tokenPair: OAuthTokenPair?
            let clientID: String
            let issuanceSnapshot: OAuthClientOperationGate.TokenIssuanceSnapshot

            if grantType == "authorization_code",
                let code = form["code"],
                let formClientID = form["client_id"],
                let redirectURI = form["redirect_uri"],
                let verifier = form["code_verifier"]
            {
                clientID = formClientID
                issuanceSnapshot = oauthClientGate.tokenIssuanceSnapshot(for: formClientID)
                tokenPair = try await oauthStore.redeemAuthorizationCode(
                    code: code,
                    clientID: formClientID,
                    redirectURI: redirectURI,
                    codeVerifier: verifier,
                    resource: resource
                )
            } else if grantType == "refresh_token",
                let refreshToken = form["refresh_token"],
                let formClientID = form["client_id"]
            {
                clientID = formClientID
                issuanceSnapshot = oauthClientGate.tokenIssuanceSnapshot(for: formClientID)
                tokenPair = try await oauthStore.redeemRefreshToken(
                    refreshToken,
                    clientID: formClientID,
                    resource: resource
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
            guard oauthClientGate.acceptTokenIssuance(for: clientID, snapshot: issuanceSnapshot) else {
                do {
                    _ = try await oauthStore.revokeToken(
                        tokenPair.refreshToken,
                        clientID: clientID,
                        tokenTypeHint: "refresh_token"
                    )
                } catch {
                    logMessage(
                        "AppleCoreHTTPServer: Failed to discard token issued across a client disconnect: "
                            + error.localizedDescription
                    )
                }
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_grant",
                    "The OAuth client was disconnected during this token exchange.",
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
        } catch let error as OAuthTokenStoreError {
            logMessage("AppleCoreHTTPServer: OAuth token persistence failed: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .internalServerError,
                "server_error",
                "Apple Core could not save the OAuth token exchange.",
                request: request
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

    private func oauthRevoke(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request),
                let data = try await boundedRequestBody(request)
            else {
                return Self.oauthErrorResponse(
                    .payloadTooLarge,
                    "invalid_request",
                    "Request body too large.",
                    request: request
                )
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard let token = form["token"], !token.isEmpty,
                let clientID = form["client_id"], !clientID.isEmpty
            else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_request",
                    "Expected token and client_id.",
                    request: request
                )
            }
            guard await oauthStore.client(id: clientID) != nil else {
                return Self.oauthErrorResponse(
                    .badRequest,
                    "invalid_client",
                    "The OAuth client is not registered.",
                    request: request
                )
            }

            _ = try await oauthStore.revokeToken(
                token,
                clientID: clientID,
                tokenTypeHint: form["token_type_hint"]
            )
            return HTTPResponse(
                statusCode: .ok,
                headers: Self.oauthCORSHeaders(for: request)
            )
        } catch let error as OAuthTokenStoreError {
            logMessage("AppleCoreHTTPServer: OAuth revocation persistence failed: \(error.localizedDescription)")
            return Self.oauthErrorResponse(
                .internalServerError,
                "server_error",
                "Apple Core could not persist token revocation.",
                request: request
            )
        } catch {
            return Self.oauthErrorResponse(
                .badRequest,
                "invalid_request",
                "Could not read OAuth revocation request.",
                request: request
            )
        }
    }

    // MARK: - Legacy SSE

    private func openLegacySSE(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async -> HTTPResponse {
        do {
            let (session, _) = try await makeSession(for: request, principal: principal)
            let endpointEvent = "event: endpoint\ndata: /message?sessionId=\(session.id)\n\n"
            let (_, stream) = await session.addPersistentStream(initialEvents: [endpointEvent])
            return sseResponse(stream: stream, sessionId: session.id)
        } catch AppleCoreHTTPServerError.tooManySessions {
            return Self.sessionCapacityResponse()
        } catch {
            logMessage("AppleCoreHTTPServer: Failed to open legacy SSE: \(error)")
            return Self.textResponse(.internalServerError, "Failed to start MCP session\n")
        }
    }

    private func postLegacyMessage(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async -> HTTPResponse {
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
        guard sessionPrincipals[sessionId] == principal else {
            return Self.textResponse(.forbidden, "Session authenticated client changed\n")
        }

        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let bodyData = try await boundedRequestBody(request) else {
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

    private func openStreamableHTTP(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async -> HTTPResponse {
        // A standalone GET stream belongs to an initialized session. Creating
        // a fresh session here let authenticated clients occupy all 64 slots
        // with streams that could never initialize and never became idle.
        guard let sessionId = request.headers[Self.sessionHeader],
            !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.textResponse(.badRequest, "Missing Mcp-Session-Id header\n")
        }
        let session: MCPSSESession
        switch resolveSession(request, principal: principal) {
        case .notFound:
            return Self.textResponse(.notFound, "Session not found\n")
        case .scopeMismatch:
            return Self.textResponse(.forbidden, "Session access scope changed\n")
        case .existing(let existing, _):
            session = existing
        case .new:
            return Self.textResponse(.badRequest, "Missing Mcp-Session-Id header\n")
        }
        let (_, stream) = await session.addPersistentStream()
        return sseResponse(stream: stream, sessionId: session.id)
    }

    private func postStreamableHTTP(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let bodyData = try await boundedRequestBody(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                return Self.textResponse(.badRequest, "Invalid UTF-8 body\n")
            }

            let message = JSONRPCRequestKey.classifyInbound(message: bodyString)
            if case .invalid = message {
                return Self.textResponse(.badRequest, "Invalid JSON-RPC message\n")
            }

            let session: MCPSSESession
            switch resolveSession(request, principal: principal) {
            case .notFound:
                return Self.textResponse(.notFound, "Session not found\n")
            case .scopeMismatch:
                return Self.textResponse(.forbidden, "Session access scope changed\n")
            case .existing(let existing, _):
                session = existing
            case .new(let newSurface):
                guard message.canStartSession else {
                    return Self.textResponse(
                        .badRequest,
                        "Only initialize requests can start an MCP session\n"
                    )
                }
                (session, _) = try await makeSession(surface: newSurface, principal: principal)
            }

            guard case .request(let requestId, _) = message else {
                await session.writeToServer(bodyString)
                if let cancelledRequestID = JSONRPCRequestKey.cancelledRequestKey(from: bodyString) {
                    await session.finishResponseStream(for: cancelledRequestID)
                }
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

    private func deleteStreamableHTTPSession(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async -> HTTPResponse {
        guard let sessionId = request.headers[Self.sessionHeader],
            let session = sessions[sessionId]
        else {
            return Self.textResponse(.notFound, "Session not found\n")
        }
        guard sessionSurfaces[sessionId] == requestSurface(for: request) else {
            return Self.textResponse(.forbidden, "Session access surface changed\n")
        }
        guard sessionPrincipals[sessionId] == principal else {
            return Self.textResponse(.forbidden, "Session authenticated client changed\n")
        }
        sessions.removeValue(forKey: sessionId)
        sessionSurfaces.removeValue(forKey: sessionId)
        sessionPrincipals.removeValue(forKey: sessionId)
        await session.close(callOnClose: false)
        sessionCloseHandler?(sessionId)
        return HTTPResponse(statusCode: .accepted)
    }

    /// Loopback binds report as localhost; anything else reports its own
    /// literal, bracketed when IPv6, so the URL stays copy-pasteable.
    private static func displayHost(_ bindHost: String) -> String {
        switch bindHost {
        case "127.0.0.1", "localhost", "0.0.0.0":
            return "localhost"
        default:
            return bindHost.contains(":") ? "[\(bindHost)]" : bindHost
        }
    }

    private func statusResponse() async -> HTTPResponse {
        let port = config.port ?? 8756
        let bindHost = config.bindHost ?? "127.0.0.1"
        let baseURL = ServingConfigManager.clientEndpointBaseURL(
            port: port,
            publicBaseURL: config.effectivePublicBaseURL
        )
        let hasPublicBaseURL = config.effectivePublicBaseURL != nil

        let status = AppleCoreRuntimeStatus(
            activeSessions: sessions.count,
            localURL: "http://\(Self.displayHost(bindHost)):\(port)/mcp",
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

    // MARK: - Licensing

    /// The EULA activation gate. Every MCP transport funnels through here
    /// after authentication. Localhost is deliberately not exempt: the
    /// keyed binary's activation term covers setting up any MCP session,
    /// wherever the request originates (see EULA.md and docs/licensing.md).
    private func isLicensed() async -> Bool {
        await licenseGate.validatedDocument() != nil
    }

    private func licenseStatusResponse() async -> HTTPResponse {
        let state = await licenseGate.activationState()
        let object: [String: Any]
        switch state {
        case .notActivated:
            object = ["activated": false, "reason": "not_activated"]
        case .active(let document):
            object = [
                "activated": true,
                "plan": document.plan,
                "licensed_to": document.licensedTo ?? "",
            ]
        case .rejected(let reason):
            object = ["activated": false, "reason": reason]
        }
        return Self.jsonResponse(.ok, object, request: nil)
    }

    /// HTTP 402 for MCP requests without a valid license. The body names
    /// the activation step so a person hitting this in a terminal or a
    /// client log sees the way out rather than a bare status code.
    private static func licenseRequiredResponse() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        return HTTPResponse(
            statusCode: .paymentRequired,
            headers: headers,
            body: Data(
                "License required: activate Apple Core in Settings › License to serve MCP.\n".utf8
            )
        )
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

    private func makeSession(
        for request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) async throws -> (MCPSSESession, MCPAccessSurface) {
        try await makeSession(surface: requestSurface(for: request), principal: principal)
    }

    private func makeSession(
        surface: MCPAccessSurface,
        principal: AuthenticatedPrincipal
    ) async throws -> (MCPSSESession, MCPAccessSurface) {
        let clientID = principal.trustedClientID
        let sessionGeneration: UInt64?
        if let clientID {
            guard let generation = oauthClientGate.sessionGeneration(for: clientID) else {
                throw AppleCoreHTTPServerError.clientDisconnected
            }
            sessionGeneration = generation
        } else {
            sessionGeneration = nil
        }
        guard let sessionFactory else {
            throw AppleCoreHTTPServerError.sessionFactoryNotConfigured
        }
        // Reserve synchronously. Checking sessions.count alone across the
        // factory's suspension let concurrent accepts all pass the guard and
        // overshoot maxSessions.
        guard sessions.count + pendingSessionReservations < Self.maxSessions else {
            throw AppleCoreHTTPServerError.tooManySessions
        }
        pendingSessionReservations += 1
        defer { pendingSessionReservations -= 1 }

        let id = UUID().uuidString.lowercased()
        let session = await sessionFactory(id, surface, principal)
        if let clientID,
            let sessionGeneration,
            !oauthClientGate.permitsSession(for: clientID, generation: sessionGeneration)
        {
            // The factory owns upstream MCP state, so retire both halves when
            // a disconnect crossed this suspension point.
            await session.close(callOnClose: false)
            sessionCloseHandler?(id)
            throw AppleCoreHTTPServerError.clientDisconnected
        }
        // Register here rather than at the call sites: callers await more
        // work before they would have registered, which would release the
        // reservation while the session is still invisible to the counters.
        sessions[id] = session
        sessionSurfaces[id] = surface
        sessionPrincipals[id] = principal
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
    private func resolveSession(
        _ request: HTTPRequest,
        principal: AuthenticatedPrincipal
    ) -> SessionResolution {
        let surface = requestSurface(for: request)
        guard let sessionId = request.headers[Self.sessionHeader], !sessionId.isEmpty else {
            return .new(surface)
        }
        guard let session = sessions[sessionId], let originalSurface = sessionSurfaces[sessionId] else {
            return .notFound
        }
        guard originalSurface == surface, sessionPrincipals[sessionId] == principal else {
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
        ServingConfigManager.clientEndpointBaseURL(
            port: config.port ?? 8756,
            publicBaseURL: config.effectivePublicBaseURL
        )
    }

    /// Every MCP transport this server exposes -- `/mcp`, plus the legacy
    /// `/sse` and `/message` pair -- is a single RFC 8707 resource. Tokens
    /// are issued bound to `<issuer>/mcp` only, so validation must expect
    /// exactly that regardless of which route carried the request; deriving
    /// the expected resource from request.path made OAuth tokens impossible
    /// to use on the legacy transports.
    private var oauthMCPResourceURL: String {
        "\(oauthIssuer)/mcp"
    }

    private var oauthProtectedResourceMetadataURL: String {
        "\(oauthIssuer)/.well-known/oauth-protected-resource/mcp"
    }

    private func isAllowedOAuthResource(_ resource: String) -> Bool {
        OAuthSupport.isCanonicalResource(resource, canonicalResource: oauthMCPResourceURL)
    }

    private func validatedAuthorizationRequest(_ values: [String: String]) async throws
        -> OAuthAuthorizationValidation?
    {
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

        // A client identifier that is an https URL is a Client ID Metadata
        // Document: the client describes itself at that address instead of
        // registering first, so there is nothing stored to look up yet.
        if ClientIDMetadataURL.looksLikeClientIDMetadataURL(clientID) {
            let identifier = try ClientIDMetadataURL(validating: clientID)
            let metadata = try await ClientIDMetadataFetcher.shared.metadata(for: identifier)
            guard
                ClientIDMetadataRedirect.matches(
                    requested: redirectURI,
                    registered: metadata.redirectURIs
                )
            else {
                return nil
            }
            try await oauthStore.registerClientIDMetadataClient(metadata)
            return OAuthAuthorizationValidation(
                clientID: clientID,
                clientName: metadata.clientName,
                redirectURI: redirectURI,
                codeChallenge: codeChallenge,
                state: values["state"],
                resource: resource
            )
        }

        var client = await oauthStore.client(id: clientID)
        if client == nil {
            client = try await oauthStore.adoptClientIfNeeded(
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
        let macName = OAuthSupport.htmlEscaped(MachineIdentity.currentName())
        // Without trust, the first connection waits on a dialog on this
        // Mac's screen. Say so, and say when that screen has nobody at it.
        let trustDetail =
            GUISession.isActive
            ? "Otherwise the first connection waits for approval in a dialog on \(macName)."
            : "Nobody is signed in at \(macName)'s screen right now, so an approval dialog there could not be answered. Leave this on."

        // Section 8.6: show where the client identifier actually comes from.
        // The client supplies its own display name, so the name alone is
        // exactly what a page impersonating another client would get right.
        // The hostname is the part it cannot forge.
        let identityHTML: String
        if ClientIDMetadataURL.looksLikeClientIDMetadataURL(validation.clientID),
            let host = URLComponents(string: validation.clientID)?.host
        {
            identityHTML =
                "<p class=\"meta\">Identified by <strong>\(OAuthSupport.htmlEscaped(host))</strong></p>"
        } else {
            identityHTML = ""
        }

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
                .check { grid-template-columns: auto 1fr; align-items: start; font-weight: 400; font-size: 14px; }
                .check input { margin-top: 3px; }
                .error { color: #b42318; font-weight: 700; }
              </style>
            </head>
            <body>
              <main>
                <h1>Authorize Apple Core</h1>
                <p>Allow <strong>\(escapedClientName)</strong> to use Apple Core's MCP tools from this Mac.</p>
                \(identityHTML)
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
                  <label class="check">
                    <input name="apple_core_trust" type="checkbox" checked>
                    <span>Trust <strong>\(escapedClientName)</strong> on \(macName), so it connects without a prompt. \(trustDetail) You can withdraw this in Settings.</span>
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

    private func authenticate(_ request: HTTPRequest) async -> AuthenticatedPrincipal? {
        let token = config.token ?? ""
        guard !token.isEmpty else { return nil }

        if let authHeader = request.headers[.authorization] {
            if Self.constantTimeEquals(authHeader, "Bearer \(token)") {
                return .sharedBearer(tokenFingerprint: OAuthSupport.tokenFingerprint(token))
            }

            if authHeader.lowercased().hasPrefix("bearer ") {
                let accessToken = String(authHeader.dropFirst("Bearer ".count))
                if let client = await oauthStore.authenticatedClient(
                    forAccessToken: accessToken,
                    resource: oauthMCPResourceURL
                ) {
                    guard !oauthClientGate.isBlocked(client.clientID) else { return nil }
                    return .oauth(clientID: client.clientID, registeredName: client.clientName)
                }
            }
        }

        // Query-string token auth used to be available behind a setting. It
        // is gone: a bearer token in a URL leaks into server logs, proxy logs,
        // browser history and Referer headers, which is exactly what the
        // Authorization header exists to avoid. It was described as a fallback
        // for legacy clients, and no MCP client needs it.
        return nil
    }

    private static func textResponse(_ statusCode: HTTPStatusCode, _ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/plain"], body: Data(text.utf8))
    }

    private static func connectorLandingPageResponse(headOnly: Bool = false) -> HTTPResponse {
        // Advertise only the small variants. Icon resolvers take the first
        // usable declaration, and listing all seven sizes put a 256x256 PNG
        // ahead of anything cheap. Every size stays served for other consumers.
        let iconLinks = [16, 32].map { size in
            "<link rel=\"icon\" type=\"image/png\" sizes=\"\(size)x\(size)\" href=\"/favicon-\(size)x\(size).png\">"
        }.joined(separator: "\n")
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Apple Core MCP</title>
              <link rel="icon" href="/favicon.ico" sizes="32x32">
              \(iconLinks)
              <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
            </head>
            <body><h1>Apple Core MCP</h1></body>
            </html>
            """
        var headers = connectorIconCacheHeaders
        headers[.contentType] = "text/html; charset=utf-8"
        return HTTPResponse(
            statusCode: .ok,
            headers: headers,
            body: headOnly ? Data() : Data(html.utf8)
        )
    }

    private static func connectorIconResponse(size: Int, headOnly: Bool = false) -> HTTPResponse {
        guard let data = connectorIconPNG(size: size) else {
            return textResponse(.internalServerError, "Icon unavailable\n")
        }
        var headers = connectorIconCacheHeaders
        headers[.contentType] = "image/png"
        headers[HTTPHeader("Content-Length")] = String(data.count)
        headers[HTTPHeader("Cross-Origin-Resource-Policy")] = "cross-origin"
        return HTTPResponse(statusCode: .ok, headers: headers, body: headOnly ? Data() : data)
    }

    /// `/favicon.ico` used to answer with a bare PNG body typed `image/png`.
    /// Strict icon resolvers reject that: the path claims an ICO container and
    /// the content type disagrees with both the path and the bytes. Wrap the
    /// PNG in a real single-entry ICO instead. PNG-compressed ICO entries are
    /// supported everywhere that matters and keep the file near 4 KB, matching
    /// sosumi.ai, whose connector icon does render in Claude.
    private static func connectorIconICO(size: Int = 32) -> Data? {
        guard let png = connectorIconPNG(size: size) else { return nil }

        var data = Data()
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // ICONDIR: reserved, type (1 = icon), image count.
        appendUInt16(0)
        appendUInt16(1)
        appendUInt16(1)

        // ICONDIRENTRY. A dimension of 256 is encoded as 0.
        data.append(UInt8(size == 256 ? 0 : size))
        data.append(UInt8(size == 256 ? 0 : size))
        data.append(0)  // palette colour count, 0 for truecolour
        data.append(0)  // reserved
        appendUInt16(1)  // colour planes
        appendUInt16(32)  // bits per pixel
        appendUInt32(UInt32(png.count))
        appendUInt32(22)  // byte offset of the image data: 6 + 16

        data.append(png)
        return data
    }

    private static func connectorIconICOResponse(headOnly: Bool = false) -> HTTPResponse {
        guard let data = connectorIconICO() else {
            return textResponse(.internalServerError, "Icon unavailable\n")
        }
        var headers = connectorIconCacheHeaders
        headers[.contentType] = "image/x-icon"
        headers[HTTPHeader("Content-Length")] = String(data.count)
        headers[HTTPHeader("Cross-Origin-Resource-Policy")] = "cross-origin"
        return HTTPResponse(statusCode: .ok, headers: headers, body: headOnly ? Data() : data)
    }

    private static func connectorIconPNG(size: Int) -> Data? {
        guard let source = NSImage(named: "AppIcon"),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size,
                pixelsHigh: size,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return nil
        }

        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        source.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func htmlResponse(_ statusCode: HTTPStatusCode, _ html: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private static func jsonResponse(
        _ statusCode: HTTPStatusCode,
        _ object: [String: Any],
        request: HTTPRequest?,
        noStore: Bool = false
    ) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = request.map(oauthCORSHeaders) ?? HTTPHeaders()
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

    /// CORS policy for the public OAuth surface (register, token, authorize,
    /// well-known metadata). These endpoints are deliberately open to any
    /// origin: browser-based public MCP clients need cross-origin access for
    /// dynamic registration and code exchange, and none of them uses
    /// ambient credentials — there are no cookies, and the authorize form's
    /// token travels in the POST body of the page itself — so a reflected
    /// origin hands an attacker's page nothing it could not get directly.
    /// This is standard OAuth authorization-server behavior. The MCP routes,
    /// which do expose user data, enforce config.allowedOrigins instead
    /// (isRequestAllowed) and emit no ACAO at all.
    ///
    /// Whatever the reflection decides, `Vary: Origin` must ride along:
    /// without it a shared cache may answer a second origin with the first
    /// origin's Allow-Origin header.
    private static func oauthCORSHeaders(for request: HTTPRequest) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers[HTTPHeader("Access-Control-Allow-Origin")] = request.headers[originHeader] ?? "*"
        headers[HTTPHeader("Vary")] = "Origin"
        headers[HTTPHeader("Access-Control-Allow-Methods")] = "GET, POST, OPTIONS"
        headers[HTTPHeader("Access-Control-Allow-Headers")] = "authorization, content-type, mcp-session-id"
        headers[HTTPHeader("Access-Control-Max-Age")] = "86400"
        return headers
    }

    private func unauthorizedResponse(for request: HTTPRequest) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        let metadataURL = Self.wwwAuthenticateQuotedValue(oauthProtectedResourceMetadataURL)
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

    /// Drains the request body with the size cap enforced during
    /// accumulation. `HTTPRequest.bodyData` buffers without bound: FlyingFox
    /// applies no cap of its own and a chunked body carries no declared
    /// length, so reading it wholesale let a single unauthenticated request
    /// materialize gigabytes before the old post-hoc count check ran.
    /// Returns nil when the body exceeds `maxRequestBodyBytes`.
    private func boundedRequestBody(_ request: HTTPRequest) async throws -> Data? {
        var data = Data()
        for try await chunk in request.bodySequence {
            guard data.count + chunk.count <= Self.maxRequestBodyBytes else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private static let sessionHeader = HTTPHeader("Mcp-Session-Id")
    private static let connectorIconSizes = [16, 32, 48, 64, 96, 128, 256]
    private static let connectorIconCacheHeaders: HTTPHeaders = {
        var headers = HTTPHeaders()
        headers[HTTPHeader("Cache-Control")] = "public, max-age=86400"
        return headers
    }()
    private static let hostHeader = HTTPHeader("Host")
    private static let forwardedForHeader = HTTPHeader("X-Forwarded-For")
    private static let connectingIPHeader = HTTPHeader("CF-Connecting-IP")
    private static let originHeader = HTTPHeader("Origin")
    private static let maxSessions = 64
    private static let maxRequestBodyBytes = 1_048_576
    private static let sessionIdleTimeout: TimeInterval = 600
}

public enum AppleCoreHTTPServerError: Swift.Error {
    case clientDisconnected
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
