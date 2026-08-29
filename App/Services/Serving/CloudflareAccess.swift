// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cloudflare Access in front of the one page a human actually looks at.
//
// The OAuth authorization page is where somebody types the Apple Core token
// into a browser, and it is the only endpoint on this host that a person
// visits. Everything else is machine-to-machine: `/mcp` carries a bearer or
// OAuth token, and `/oauth/register` and `/oauth/token` are called by the
// client itself, with no browser and no human to satisfy a login. Putting
// Access over the whole hostname therefore breaks every MCP client before it
// reaches the server, which is why this file scopes protection to a path and
// refuses to do anything else.
//
// The refusal is not advisory. `AccessProtectionSpec` cannot be constructed
// with an empty path, and `protectedDomain` always carries one, so there is no
// route through this code that produces an Access application covering `/mcp`.

import Foundation

/// What Access should protect, and who it should let through.
public struct AccessProtectionSpec: Sendable, Equatable {
    public let hostname: String
    /// Always non-empty. See the file comment: a pathless Access application
    /// would cover the MCP endpoint too.
    public let path: String
    public let applicationName: String
    public let allowedEmails: [String]
    public let sessionDuration: String

    public enum SpecError: LocalizedError, Equatable {
        case emptyHostname
        case emptyPath
        case noAllowedEmails

        public var errorDescription: String? {
            switch self {
            case .emptyHostname:
                return "Cloudflare Access needs the public hostname Apple Core is served on."
            case .emptyPath:
                return
                    "Cloudflare Access here only ever protects a single page. Protecting the whole host would block every MCP client."
            case .noAllowedEmails:
                return
                    "Add at least one email address, otherwise the Access policy would lock everyone out of the authorization page, including you."
            }
        }
    }

    public init(
        hostname: String,
        path: String = AccessProtectionSpec.authorizePath,
        applicationName: String = "Apple Core authorization page",
        allowedEmails: [String],
        sessionDuration: String = "24h"
    ) throws {
        let cleanedHost = AccessProtectionSpec.normalizedHostname(hostname)
        guard !cleanedHost.isEmpty else { throw SpecError.emptyHostname }

        let cleanedPath = AccessProtectionSpec.normalizedPath(path)
        guard !cleanedPath.isEmpty else { throw SpecError.emptyPath }

        let emails =
            allowedEmails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !emails.isEmpty else { throw SpecError.noAllowedEmails }

        self.hostname = cleanedHost
        self.path = cleanedPath
        self.applicationName = applicationName
        self.allowedEmails = emails
        self.sessionDuration = sessionDuration
    }

    /// The only page on this host a person opens in a browser.
    public static let authorizePath = "oauth/authorize"

    /// Endpoints that must never sit behind Access, kept here so the reason
    /// travels with the code rather than living in a commit message.
    ///
    /// - `mcp`: every MCP client authenticates with its own bearer token and
    ///   speaks no Access login.
    /// - `oauth/register`: dynamic client registration, called by the client
    ///   process, not a browser.
    /// - `oauth/token`: the code-for-token exchange, likewise machine-to-machine.
    public static let mustStayOpen = ["mcp", "oauth/register", "oauth/token"]

    public static func normalizedHostname(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex ..< slash])
        }
        return value
    }

    public static func normalizedPath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// What Cloudflare calls the application's domain: host plus path.
    public var protectedDomain: String {
        "\(hostname)/\(path)"
    }

    /// True when this spec would shadow an endpoint that has to stay reachable
    /// without a login. Belt and braces against a future caller passing a path
    /// like "" or "oauth" that swallows the machine endpoints beneath it.
    public var wouldBlockMachineEndpoints: Bool {
        AccessProtectionSpec.mustStayOpen.contains { open in
            open == path || open.hasPrefix(path + "/")
        }
    }
}

public enum CloudflareAccessError: LocalizedError, Equatable {
    case missingAPIToken
    case missingAccountID
    case notPermitted
    case requestFailed(status: Int, detail: String)
    case wouldBlockMachineEndpoints(path: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIToken:
            return
                "Add a Cloudflare API token with Access permissions first. The tunnel login cannot do this on its own."
        case .missingAccountID:
            return "Apple Core does not know which Cloudflare account to use. Finish the tunnel setup first."
        case .notPermitted:
            return
                "Cloudflare refused this with the tunnel login's credentials. That certificate is scoped to tunnel and DNS work, so protecting a page needs an API token with Access permissions."
        case let .requestFailed(status, detail):
            return "Cloudflare returned \(status): \(detail)"
        case let .wouldBlockMachineEndpoints(path):
            return
                "Refusing to protect “\(path)”, because it covers an endpoint that MCP clients call without a browser. They would stop connecting."
        }
    }
}

/// Minimal client for the Access applications API.
public struct CloudflareAccessClient: Sendable {
    private let accountID: String
    private let apiToken: String
    private let session: URLSession

    public init(accountID: String, apiToken: String, session: URLSession = .shared) {
        self.accountID = accountID
        self.apiToken = apiToken
        self.session = session
    }

    private var base: String {
        "https://api.cloudflare.com/client/v4/accounts/\(accountID)/access/apps"
    }

    // MARK: - Payloads
    //
    // Split out and pure so the shape of what gets sent is testable without a
    // network or a Cloudflare account.

    public static func applicationPayload(for spec: AccessProtectionSpec) -> [String: Any] {
        [
            "name": spec.applicationName,
            "domain": spec.protectedDomain,
            "type": "self_hosted",
            "session_duration": spec.sessionDuration,
            // Keep it out of the launcher: this is a machine's authorization
            // page reached by redirect, not something to browse to.
            "app_launcher_visible": false,
        ]
    }

    public static func policyPayload(for spec: AccessProtectionSpec) -> [String: Any] {
        [
            "name": "Allow approved people",
            "decision": "allow",
            "include": spec.allowedEmails.map { ["email": ["email": $0]] },
        ]
    }

    // MARK: - Operations

    /// Creates the application and its allow policy, or updates them when one
    /// already covers this exact domain. Returns the application ID.
    public func ensureApplication(for spec: AccessProtectionSpec) async throws -> String {
        guard !spec.wouldBlockMachineEndpoints else {
            throw CloudflareAccessError.wouldBlockMachineEndpoints(path: spec.path)
        }

        if let existing = try await findApplication(domain: spec.protectedDomain) {
            _ = try await send(
                method: "PUT",
                url: "\(base)/\(existing)",
                body: Self.applicationPayload(for: spec)
            )
            try await replacePolicies(applicationID: existing, spec: spec)
            return existing
        }

        let created = try await send(
            method: "POST",
            url: base,
            body: Self.applicationPayload(for: spec)
        )
        guard let result = created["result"] as? [String: Any],
            let id = result["id"] as? String
        else {
            throw CloudflareAccessError.requestFailed(
                status: 200,
                detail: "Cloudflare accepted the application but returned no id."
            )
        }
        try await replacePolicies(applicationID: id, spec: spec)
        return id
    }

    public func findApplication(domain: String) async throws -> String? {
        let response = try await send(method: "GET", url: base, body: nil)
        guard let results = response["result"] as? [[String: Any]] else { return nil }
        return
            results
            .first { ($0["domain"] as? String)?.lowercased() == domain.lowercased() }?["id"]
            as? String
    }

    public func deleteApplication(id: String) async throws {
        _ = try await send(method: "DELETE", url: "\(base)/\(id)", body: nil)
    }

    private func replacePolicies(applicationID: String, spec: AccessProtectionSpec) async throws {
        let policiesURL = "\(base)/\(applicationID)/policies"
        let existing = try await send(method: "GET", url: policiesURL, body: nil)
        if let results = existing["result"] as? [[String: Any]] {
            for policy in results {
                if let id = policy["id"] as? String {
                    _ = try? await send(method: "DELETE", url: "\(policiesURL)/\(id)", body: nil)
                }
            }
        }
        _ = try await send(
            method: "POST",
            url: policiesURL,
            body: Self.policyPayload(for: spec)
        )
    }

    private func send(method: String, url: String, body: [String: Any]?) async throws -> [String:
        Any]
    {
        guard let requestURL = URL(string: url) else {
            throw CloudflareAccessError.requestFailed(status: 0, detail: "Bad URL: \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 403 is the expected answer when someone points the tunnel login's
        // certificate at this API, so name that case rather than surfacing a
        // raw status the user cannot act on.
        if status == 403 { throw CloudflareAccessError.notPermitted }
        guard (200 ..< 300).contains(status) else {
            throw CloudflareAccessError.requestFailed(
                status: status,
                detail: String(data: data, encoding: .utf8) ?? "no body"
            )
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
