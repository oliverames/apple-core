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

public struct OAuthRegisteredClient: Codable, Sendable {
    public let clientID: String
    public let clientName: String
    public let redirectURIs: [String]
    public let issuedAt: Int
}

private struct PersistedOAuthClientRegistry: Codable {
    let clients: [OAuthRegisteredClient]
}

private struct PersistedOAuthAccessTokens: Codable {
    let tokens: [PersistedOAuthAccessToken]
}

private struct PersistedOAuthAccessToken: Codable {
    let token: String
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
    let resource: String
    let expiresAt: Date
}

public actor OAuthTokenStore {
    private static let maxPersistedClients = 256

    private let clientRegistryURL: URL?
    private let accessTokenStoreURL: URL?
    private var clients: [String: OAuthRegisteredClient]
    private var authorizationCodes: [String: OAuthAuthorizationCode] = [:]
    private var accessTokens: [String: OAuthAccessToken]

    public init(clientRegistryURL: URL? = nil, accessTokenStoreURL: URL? = nil) {
        self.clientRegistryURL = clientRegistryURL
        self.accessTokenStoreURL = accessTokenStoreURL
        self.clients = Self.loadClients(from: clientRegistryURL)
        self.accessTokens = Self.loadAccessTokens(from: accessTokenStoreURL)
    }

    public func registerClient(clientName: String, redirectURIs: [String], now: Date = Date()) -> OAuthRegisteredClient {
        let client = OAuthRegisteredClient(
            clientID: ServingConfigManager.generateSecureToken(),
            clientName: clientName,
            redirectURIs: redirectURIs,
            issuedAt: Int(now.timeIntervalSince1970)
        )
        clients[client.clientID] = client
        pruneClientsIfNeeded()
        persistClients()
        return client
    }

    public func client(id: String) -> OAuthRegisteredClient? {
        clients[id]
    }

    public func adoptClientIfNeeded(clientID: String, clientName: String, redirectURI: String, now: Date = Date()) -> OAuthRegisteredClient? {
        if let client = clients[clientID] {
            return client
        }

        guard OAuthSupport.isAppleCoreGeneratedClientID(clientID),
            OAuthSupport.isAllowedRedirectURI(redirectURI)
        else {
            return nil
        }

        let client = OAuthRegisteredClient(
            clientID: clientID,
            clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "OAuth client" : clientName,
            redirectURIs: [redirectURI],
            issuedAt: Int(now.timeIntervalSince1970)
        )
        clients[clientID] = client
        persistClients()
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

        let code = ServingConfigManager.generateSecureToken()
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
        now: Date = Date()
    ) -> String? {
        cleanup(now: now)
        guard let pending = authorizationCodes.removeValue(forKey: code),
            pending.clientID == clientID,
            pending.redirectURI == redirectURI,
            OAuthSupport.constantTimeEquals(OAuthSupport.pkceS256Challenge(for: codeVerifier), pending.codeChallenge)
        else {
            return nil
        }

        let token = ServingConfigManager.generateSecureToken()
        accessTokens[token] = OAuthAccessToken(
            token: token,
            resource: pending.resource,
            expiresAt: now.addingTimeInterval(12 * 60 * 60)
        )
        persistAccessTokens()
        return token
    }

    public func isValidAccessToken(_ token: String, resource: String, now: Date = Date()) -> Bool {
        cleanup(now: now)
        guard let accessToken = accessTokens[token] else {
            return false
        }
        guard accessToken.expiresAt > now else {
            return false
        }
        return OAuthSupport.constantTimeEquals(accessToken.resource, resource)
    }

    private func cleanup(now: Date) {
        authorizationCodes = authorizationCodes.filter { $0.value.expiresAt > now }
        let liveTokens = accessTokens.filter { $0.value.expiresAt > now }
        if liveTokens.count != accessTokens.count {
            accessTokens = liveTokens
            persistAccessTokens()
        }
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

        return Dictionary(uniqueKeysWithValues: registry.clients.map { ($0.clientID, $0) })
    }

    private static func loadAccessTokens(from url: URL?, now: Date = Date()) -> [String: OAuthAccessToken] {
        guard let url,
            let data = try? Data(contentsOf: url),
            let persisted = try? JSONDecoder().decode(PersistedOAuthAccessTokens.self, from: data)
        else {
            return [:]
        }

        var tokens: [String: OAuthAccessToken] = [:]
        for entry in persisted.tokens where entry.expiresAt > now {
            tokens[entry.token] = OAuthAccessToken(token: entry.token, resource: entry.resource, expiresAt: entry.expiresAt)
        }
        return tokens
    }

    private func persistClients() {
        guard let clientRegistryURL else {
            return
        }

        let registry = PersistedOAuthClientRegistry(clients: clients.values.sorted { $0.clientID < $1.clientID })
        Self.writePrivateJSON(registry, to: clientRegistryURL, label: "OAuth client registry")
    }

    private func persistAccessTokens() {
        guard let accessTokenStoreURL else {
            return
        }

        let persisted = PersistedOAuthAccessTokens(
            tokens: accessTokens.values
                .sorted { $0.token < $1.token }
                .map { PersistedOAuthAccessToken(token: $0.token, resource: $0.resource, expiresAt: $0.expiresAt) })
        Self.writePrivateJSON(persisted, to: accessTokenStoreURL, label: "OAuth access tokens")
    }

    private static func writePrivateJSON<T: Encodable>(_ value: T, to url: URL, label: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            let directory = url.deletingLastPathComponent()
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logMessage("OAuthTokenStore: Failed to persist \(label): \(error)")
        }
    }
}

public enum OAuthSupport {
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
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return false
        }

        if scheme == "https" {
            return true
        }

        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        return false
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
        AppleCoreHTTPServer.constantTimeEquals(lhs, rhs)
    }
}
