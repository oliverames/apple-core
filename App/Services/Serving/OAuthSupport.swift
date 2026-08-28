// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from Bridgeport's OAuthSupport.swift. This implements OAuth 2.1 +
// PKCE dynamic client registration for cloud MCP clients (Claude custom
// connectors, ChatGPT apps, etc.) connecting to Apple Core over the public
// Cloudflare tunnel URL. The logic is generic OAuth machinery, not tied to
// Bridgeport's connector model, so only naming changed: BridgeportPaths ->
// AppleCoreServingPaths, ConfigManager -> ServingConfigManager, SSEServer ->
// AppleCoreHTTPServer.

import CryptoKit
import Foundation
import Security

public struct OAuthRegisteredClient: Codable, Sendable {
    public let clientID: String
    public let clientName: String
    public let redirectURIs: [String]
    public let issuedAt: Int
}

/// Server-derived identity for one authenticated HTTP client. MCP's
/// `clientInfo` is display metadata supplied by the client and must never be
/// used as an authorization or durable-trust key.
public enum AuthenticatedPrincipal: Sendable, Hashable {
    case sharedBearer
    case oauth(clientID: String, registeredName: String)

    public var trustedClientID: String? {
        guard case let .oauth(clientID, _) = self else { return nil }
        return clientID
    }

    public var registeredName: String? {
        guard case let .oauth(_, registeredName) = self else { return nil }
        return registeredName
    }

    public var canBeTrusted: Bool {
        trustedClientID != nil
    }
}

private struct PersistedOAuthClientRegistry: Codable {
    let clients: [OAuthRegisteredClient]
}

private struct PersistedOAuthAccessTokens: Codable {
    let tokens: [PersistedOAuthAccessToken]
    let refreshTokens: [PersistedOAuthRefreshToken]

    private enum CodingKeys: String, CodingKey {
        case tokens
        case refreshTokens
    }

    init(tokens: [PersistedOAuthAccessToken], refreshTokens: [PersistedOAuthRefreshToken]) {
        self.tokens = tokens
        self.refreshTokens = refreshTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decode([PersistedOAuthAccessToken].self, forKey: .tokens)
        refreshTokens = try container.decodeIfPresent([PersistedOAuthRefreshToken].self, forKey: .refreshTokens) ?? []
    }
}

private struct PersistedOAuthAccessToken: Codable {
    let token: String
    let clientID: String?
    let grantID: String?
    let resource: String
    let expiresAt: Date
}

private struct PersistedOAuthRefreshToken: Codable {
    let token: String
    let clientID: String
    let grantID: String?
    let resource: String
    let expiresAt: Date
}

private struct OAuthAuthorizationCode: Sendable {
    let code: String
    let clientID: String
    let redirectURI: String
    let codeChallenge: String
    let resource: String
    let expiresAt: Date
}

private struct OAuthAccessToken: Sendable {
    let token: String
    let clientID: String
    let grantID: String
    let resource: String
    let expiresAt: Date
}

private struct OAuthRefreshToken: Sendable {
    let token: String
    let clientID: String
    let grantID: String
    let resource: String
    let expiresAt: Date
}

public struct OAuthTokenPair: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
}

public enum OAuthTokenStoreError: LocalizedError, Equatable, Sendable {
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .persistenceFailed(detail):
            return "Apple Core could not save the OAuth client state: \(detail)"
        }
    }
}

/// Coordinates administrative disconnects with actor-reentrant token and
/// session creation. A monotonically increasing generation prevents work
/// that began before a disconnect from becoming valid after a later OAuth
/// exchange reconnects the same client ID.
struct OAuthClientOperationGate: Sendable {
    struct TokenIssuanceSnapshot: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let beganDuringDisconnect: Bool
    }

    private struct ClientState: Sendable {
        var generation: UInt64 = 0
        var activeDisconnects = 0
        var isBlocked = false
    }

    private var states: [String: ClientState] = [:]

    mutating func beginDisconnect(for clientID: String) {
        var state = states[clientID] ?? ClientState()
        state.generation &+= 1
        state.activeDisconnects += 1
        state.isBlocked = true
        states[clientID] = state
    }

    mutating func finishDisconnect(for clientID: String) {
        guard var state = states[clientID], state.activeDisconnects > 0 else {
            assertionFailure("OAuth disconnect finished without a matching start")
            return
        }
        state.activeDisconnects -= 1
        states[clientID] = state
    }

    func isBlocked(_ clientID: String) -> Bool {
        states[clientID]?.isBlocked ?? false
    }

    func sessionGeneration(for clientID: String) -> UInt64? {
        let state = states[clientID] ?? ClientState()
        return state.isBlocked ? nil : state.generation
    }

    func permitsSession(for clientID: String, generation: UInt64) -> Bool {
        let state = states[clientID] ?? ClientState()
        return !state.isBlocked && state.generation == generation
    }

    func tokenIssuanceSnapshot(for clientID: String) -> TokenIssuanceSnapshot {
        let state = states[clientID] ?? ClientState()
        return TokenIssuanceSnapshot(
            generation: state.generation,
            beganDuringDisconnect: state.activeDisconnects > 0
        )
    }

    mutating func acceptTokenIssuance(
        for clientID: String,
        snapshot: TokenIssuanceSnapshot
    ) -> Bool {
        var state = states[clientID] ?? ClientState()
        guard state.generation == snapshot.generation,
            state.activeDisconnects == 0,
            !snapshot.beganDuringDisconnect
        else {
            return false
        }
        state.isBlocked = false
        states[clientID] = state
        return true
    }
}

public actor OAuthTokenStore {
    private static let maxPersistedClients = 256
    public static let accessTokenLifetime: TimeInterval = 12 * 60 * 60
    private static let refreshTokenLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let clientRegistryURL: URL?
    private let accessTokenStoreURL: URL?
    private let persistenceWriter: (@Sendable (Data, URL) throws -> Void)?
    private var clients: [String: OAuthRegisteredClient]
    private var authorizationCodes: [String: OAuthAuthorizationCode] = [:]
    private var accessTokens: [String: OAuthAccessToken]
    private var refreshTokens: [String: OAuthRefreshToken]

    public init(
        clientRegistryURL: URL? = nil,
        accessTokenStoreURL: URL? = nil,
        persistenceWriter: (@Sendable (Data, URL) throws -> Void)? = nil
    ) {
        self.clientRegistryURL = clientRegistryURL
        self.accessTokenStoreURL = accessTokenStoreURL
        self.persistenceWriter = persistenceWriter
        self.clients = Self.loadClients(from: clientRegistryURL)
        let persistedTokens = Self.loadTokens(from: accessTokenStoreURL)
        self.accessTokens = persistedTokens.accessTokens
        self.refreshTokens = persistedTokens.refreshTokens
    }

    public func registerClient(clientName: String, redirectURIs: [String], now: Date = Date()) throws
        -> OAuthRegisteredClient
    {
        let previousClients = clients
        let client = OAuthRegisteredClient(
            clientID: OAuthSupport.generateSecureToken(),
            clientName: clientName,
            redirectURIs: redirectURIs,
            issuedAt: Int(now.timeIntervalSince1970)
        )
        clients[client.clientID] = client
        pruneClientsIfNeeded()
        do {
            try persistClients()
        } catch {
            clients = previousClients
            throw error
        }
        return client
    }

    public func client(id: String) -> OAuthRegisteredClient? {
        clients[id]
    }

    public func registeredClients() -> [OAuthRegisteredClient] {
        clients.values.sorted { $0.issuedAt > $1.issuedAt }
    }

    public func adoptClientIfNeeded(
        clientID: String,
        clientName: String,
        redirectURI: String,
        now: Date = Date()
    ) throws -> OAuthRegisteredClient? {
        if let client = clients[clientID] {
            return client
        }

        guard OAuthSupport.isAppleCoreGeneratedClientID(clientID),
            OAuthSupport.isAllowedRedirectURI(redirectURI)
        else {
            return nil
        }

        let previousClients = clients
        let client = OAuthRegisteredClient(
            clientID: clientID,
            clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OAuth client" : clientName,
            redirectURIs: [redirectURI],
            issuedAt: Int(now.timeIntervalSince1970)
        )
        clients[clientID] = client
        pruneClientsIfNeeded()
        do {
            try persistClients()
        } catch {
            clients = previousClients
            throw error
        }
        return client
    }

    public func issueAuthorizationCode(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        resource: String,
        now: Date = Date()
    ) -> String? {
        cleanup(now: now)
        guard let client = clients[clientID], client.redirectURIs.contains(redirectURI) else {
            return nil
        }

        let code = OAuthSupport.generateSecureToken()
        authorizationCodes[code] = OAuthAuthorizationCode(
            code: code,
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            resource: resource,
            expiresAt: now.addingTimeInterval(300)
        )
        return code
    }

    public func redeemAuthorizationCode(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String,
        resource: String,
        now: Date = Date()
    ) throws -> OAuthTokenPair? {
        cleanup(now: now)
        let previousAuthorizationCodes = authorizationCodes
        let previousAccessTokens = accessTokens
        let previousRefreshTokens = refreshTokens
        guard let pending = authorizationCodes.removeValue(forKey: code),
            pending.clientID == clientID,
            pending.redirectURI == redirectURI,
            OAuthSupport.constantTimeEquals(pending.resource, resource),
            OAuthSupport.constantTimeEquals(OAuthSupport.pkceS256Challenge(for: codeVerifier), pending.codeChallenge)
        else {
            return nil
        }

        let tokenPair = issueTokenPair(clientID: clientID, resource: pending.resource, now: now)
        do {
            try persistAccessTokens()
        } catch {
            authorizationCodes = previousAuthorizationCodes
            accessTokens = previousAccessTokens
            refreshTokens = previousRefreshTokens
            throw error
        }
        return tokenPair
    }

    public func redeemRefreshToken(
        _ token: String,
        clientID: String,
        resource: String? = nil,
        now: Date = Date()
    ) throws -> OAuthTokenPair? {
        cleanup(now: now)
        let previousAccessTokens = accessTokens
        let previousRefreshTokens = refreshTokens
        guard let pending = refreshTokens[token],
            OAuthSupport.constantTimeEquals(pending.clientID, clientID),
            resource.map({ OAuthSupport.constantTimeEquals(pending.resource, $0) }) ?? true
        else {
            return nil
        }

        refreshTokens.removeValue(forKey: token)
        let tokenPair = issueTokenPair(
            clientID: pending.clientID,
            grantID: pending.grantID,
            resource: pending.resource,
            now: now
        )
        do {
            try persistAccessTokens()
        } catch {
            accessTokens = previousAccessTokens
            refreshTokens = previousRefreshTokens
            throw error
        }
        return tokenPair
    }

    public func isValidAccessToken(_ token: String, resource: String, now: Date = Date()) -> Bool {
        authenticatedClient(forAccessToken: token, resource: resource, now: now) != nil
    }

    /// Resolves a bearer token to the registered OAuth client that owns it.
    /// Legacy access-token records without a client ID are deliberately not
    /// loaded, so they cannot become durable identities.
    public func authenticatedClient(
        forAccessToken token: String,
        resource: String,
        now: Date = Date()
    ) -> OAuthRegisteredClient? {
        cleanup(now: now)
        guard let accessToken = accessTokens[token] else {
            return nil
        }
        guard accessToken.expiresAt > now else {
            return nil
        }
        guard OAuthSupport.constantTimeEquals(accessToken.resource, resource) else {
            return nil
        }
        return clients[accessToken.clientID]
    }

    /// RFC 7009 revocation policy: revoking a refresh token invalidates its
    /// complete grant, while revoking an access token invalidates only that
    /// token. A token owned by another client is treated like an unknown token.
    @discardableResult
    public func revokeToken(
        _ token: String,
        clientID: String,
        tokenTypeHint: String? = nil,
        now: Date = Date()
    ) throws -> Bool {
        cleanup(now: now)
        let previousAccessTokens = accessTokens
        let previousRefreshTokens = refreshTokens

        let searchRefreshFirst = tokenTypeHint != "access_token"
        if searchRefreshFirst,
            let refresh = refreshTokens[token],
            OAuthSupport.constantTimeEquals(refresh.clientID, clientID)
        {
            revokeGrant(refresh.grantID)
            do {
                try persistAccessTokens()
            } catch {
                accessTokens = previousAccessTokens
                refreshTokens = previousRefreshTokens
                throw error
            }
            return true
        }

        if let access = accessTokens[token],
            OAuthSupport.constantTimeEquals(access.clientID, clientID)
        {
            accessTokens.removeValue(forKey: token)
            do {
                try persistAccessTokens()
            } catch {
                accessTokens = previousAccessTokens
                refreshTokens = previousRefreshTokens
                throw error
            }
            return true
        }

        if !searchRefreshFirst,
            let refresh = refreshTokens[token],
            OAuthSupport.constantTimeEquals(refresh.clientID, clientID)
        {
            revokeGrant(refresh.grantID)
            do {
                try persistAccessTokens()
            } catch {
                accessTokens = previousAccessTokens
                refreshTokens = previousRefreshTokens
                throw error
            }
            return true
        }

        return false
    }

    /// Removes one dynamic registration and every credential issued to it.
    /// Settings can use this as an explicit disconnect operation without
    /// parsing or rewriting the token files itself.
    @discardableResult
    public func removeClient(id clientID: String) throws -> Bool {
        guard let removedClient = clients.removeValue(forKey: clientID) else { return false }
        let previousAuthorizationCodes = authorizationCodes
        let previousAccessTokens = accessTokens
        let previousRefreshTokens = refreshTokens
        authorizationCodes = authorizationCodes.filter { $0.value.clientID != clientID }
        accessTokens = accessTokens.filter { $0.value.clientID != clientID }
        refreshTokens = refreshTokens.filter { $0.value.clientID != clientID }

        do {
            // Revoke credentials first. If the registry write then fails, the
            // client stays visible for a retry but its old credentials remain
            // unusable after a restart.
            try persistAccessTokens()
        } catch {
            clients[clientID] = removedClient
            authorizationCodes = previousAuthorizationCodes
            accessTokens = previousAccessTokens
            refreshTokens = previousRefreshTokens
            throw error
        }

        do {
            try persistClients()
        } catch {
            clients[clientID] = removedClient
            throw error
        }
        return true
    }

    private func cleanup(now: Date) {
        authorizationCodes = authorizationCodes.filter { $0.value.expiresAt > now }
        let liveTokens = accessTokens.filter { $0.value.expiresAt > now }
        let liveRefreshTokens = refreshTokens.filter { $0.value.expiresAt > now }
        if liveTokens.count != accessTokens.count || liveRefreshTokens.count != refreshTokens.count {
            accessTokens = liveTokens
            refreshTokens = liveRefreshTokens
            persistAccessTokensBestEffort()
        }
    }

    private func issueTokenPair(
        clientID: String,
        grantID: String = OAuthSupport.generateSecureToken(),
        resource: String,
        now: Date
    ) -> OAuthTokenPair {
        let accessToken = OAuthSupport.generateSecureToken()
        let refreshToken = OAuthSupport.generateSecureToken()
        accessTokens[accessToken] = OAuthAccessToken(
            token: accessToken,
            clientID: clientID,
            grantID: grantID,
            resource: resource,
            expiresAt: now.addingTimeInterval(Self.accessTokenLifetime)
        )
        refreshTokens[refreshToken] = OAuthRefreshToken(
            token: refreshToken,
            clientID: clientID,
            grantID: grantID,
            resource: resource,
            expiresAt: now.addingTimeInterval(Self.refreshTokenLifetime)
        )
        return OAuthTokenPair(accessToken: accessToken, refreshToken: refreshToken)
    }

    private func revokeGrant(_ grantID: String) {
        accessTokens = accessTokens.filter { $0.value.grantID != grantID }
        refreshTokens = refreshTokens.filter { $0.value.grantID != grantID }
    }

    private func pruneClientsIfNeeded() {
        guard clients.count > Self.maxPersistedClients else { return }
        let oldestFirst = clients.values.sorted { $0.issuedAt < $1.issuedAt }
        for stale in oldestFirst.prefix(clients.count - Self.maxPersistedClients) {
            clients.removeValue(forKey: stale.clientID)
        }
    }

    private static func loadClients(from url: URL?) -> [String: OAuthRegisteredClient] {
        guard let url,
            let data = try? Data(contentsOf: url),
            let registry = try? JSONDecoder().decode(PersistedOAuthClientRegistry.self, from: data)
        else {
            return [:]
        }

        // A hand-edited or partially recovered registry can contain the same
        // client ID more than once. Dictionary(uniqueKeysWithValues:) traps on
        // that input and used to take down the app during server startup. Keep
        // the last persisted record, matching ordinary dictionary assignment.
        var clients: [String: OAuthRegisteredClient] = [:]
        for client in registry.clients {
            clients[client.clientID] = client
        }
        return clients
    }

    private static func loadTokens(
        from url: URL?,
        now: Date = Date()
    ) -> (accessTokens: [String: OAuthAccessToken], refreshTokens: [String: OAuthRefreshToken]) {
        guard let url,
            let data = try? Data(contentsOf: url),
            let persisted = try? JSONDecoder().decode(PersistedOAuthAccessTokens.self, from: data)
        else {
            return ([:], [:])
        }

        var accessTokens: [String: OAuthAccessToken] = [:]
        for entry in persisted.tokens where entry.expiresAt > now {
            guard let clientID = entry.clientID, let grantID = entry.grantID else {
                continue
            }
            accessTokens[entry.token] = OAuthAccessToken(
                token: entry.token,
                clientID: clientID,
                grantID: grantID,
                resource: entry.resource,
                expiresAt: entry.expiresAt
            )
        }
        var refreshTokens: [String: OAuthRefreshToken] = [:]
        for entry in persisted.refreshTokens where entry.expiresAt > now {
            refreshTokens[entry.token] = OAuthRefreshToken(
                token: entry.token,
                clientID: entry.clientID,
                grantID: entry.grantID ?? OAuthSupport.legacyGrantID(for: entry.token),
                resource: entry.resource,
                expiresAt: entry.expiresAt
            )
        }
        return (accessTokens, refreshTokens)
    }

    private func persistClients() throws {
        guard let clientRegistryURL else {
            return
        }

        let registry = PersistedOAuthClientRegistry(clients: clients.values.sorted { $0.clientID < $1.clientID })
        try writePrivateJSON(registry, to: clientRegistryURL)
    }

    private func persistAccessTokens() throws {
        guard let accessTokenStoreURL else {
            return
        }

        let persisted = PersistedOAuthAccessTokens(
            tokens: accessTokens.values
                .sorted { $0.token < $1.token }
                .map {
                    PersistedOAuthAccessToken(
                        token: $0.token,
                        clientID: $0.clientID,
                        grantID: $0.grantID,
                        resource: $0.resource,
                        expiresAt: $0.expiresAt
                    )
                },
            refreshTokens: refreshTokens.values
                .sorted { $0.token < $1.token }
                .map {
                    PersistedOAuthRefreshToken(
                        token: $0.token,
                        clientID: $0.clientID,
                        grantID: $0.grantID,
                        resource: $0.resource,
                        expiresAt: $0.expiresAt
                    )
                }
        )
        try writePrivateJSON(persisted, to: accessTokenStoreURL)
    }

    private func persistClientsBestEffort() {
        do {
            try persistClients()
        } catch {
            NSLog("OAuthTokenStore: Failed to persist OAuth client registry: %@", String(describing: error))
        }
    }

    private func persistAccessTokensBestEffort() {
        do {
            try persistAccessTokens()
        } catch {
            NSLog("OAuthTokenStore: Failed to persist OAuth access tokens: %@", String(describing: error))
        }
    }

    private func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            if let persistenceWriter {
                try persistenceWriter(data, url)
                return
            }

            let directory = url.deletingLastPathComponent()
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let candidate = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            defer {
                if fileManager.fileExists(atPath: candidate.path) {
                    try? fileManager.removeItem(at: candidate)
                }
            }
            try data.write(to: candidate, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: candidate,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: candidate, to: url)
            }
        } catch let error as OAuthTokenStoreError {
            throw error
        } catch {
            throw OAuthTokenStoreError.persistenceFailed(error.localizedDescription)
        }
    }
}

public enum OAuthSupport {
    public static func generateSecureToken() -> String {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status == errSecSuccess {
            return "ames_" + base64URLEncoded(Data(randomBytes))
        }
        return "ames_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    public static func pkceS256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    public static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func parseFormURLEncoded(_ data: Data) -> [String: String] {
        guard let raw = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecodedFormValue(String(parts.first ?? ""))
            let value = parts.count > 1 ? percentDecodedFormValue(String(parts[1])) : ""
            values[key] = value
        }
        return values
    }

    public static func percentDecodedFormValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? value
    }

    public static func queryDictionary(_ queryItems: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in queryItems {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    public static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func isAllowedRedirectURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased()
        else {
            return false
        }

        if scheme == "https" {
            return components.host?.isEmpty == false
        }

        if scheme == "http" {
            guard let host = components.host?.lowercased() else {
                return false
            }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        // RFC 8252 private-use redirects use a reverse-domain scheme and no
        // URI authority, for example com.example.app:/oauth2redirect. The
        // authorization request still has to match this complete registered
        // URI exactly before a code is issued.
        return scheme.contains(".")
            && components.host == nil
            && components.user == nil
            && components.password == nil
            && components.port == nil
            && components.path.hasPrefix("/")
            && components.path.count > 1
            && components.fragment == nil
    }

    public static func isAppleCoreGeneratedClientID(_ value: String) -> Bool {
        guard value.hasPrefix("ames_"), value.count >= 48 else {
            return false
        }

        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0 ..< maxCount {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }
        return difference == 0
    }

    /// Apple Core uses one exact RFC 8707 audience. Accepting textual aliases
    /// creates tokens that cannot later authenticate against that audience.
    public static func isCanonicalResource(_ value: String, canonicalResource: String) -> Bool {
        constantTimeEquals(value, canonicalResource)
    }

    fileprivate static func legacyGrantID(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return "legacy-" + base64URLEncoded(Data(digest))
    }
}
