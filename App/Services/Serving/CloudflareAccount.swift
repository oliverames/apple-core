// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads what `cloudflared tunnel login` already learned, so the Cloudflare
// pane can stop asking for it.
//
// The origin certificate cloudflared writes to ~/.cloudflared/cert.pem is a
// PEM-framed base64 JSON object carrying three fields: accountID, zoneID and
// a scoped apiToken. The Settings window used to make people type the domain,
// the zone ID and the account ID by hand even though the browser sign-in had
// just established all three. This resolves them instead: the two IDs come
// straight out of the certificate, and the zone's human-readable name comes
// from one Cloudflare API call made with the certificate's own token.
//
// The token is a live credential. It is never logged, never surfaced in the
// UI, and never written into Apple Core's own config.

import Foundation

/// What Apple Core could determine about the signed-in Cloudflare account.
public struct CloudflareAccountInfo: Sendable, Equatable {
    public var accountID: String
    public var zoneID: String
    /// The apex domain of the zone chosen during login, e.g. "example.com".
    /// Nil when the certificate was readable but the zone name could not be
    /// resolved — the IDs are still usable, so setup continues with the domain
    /// typed by hand.
    public var domain: String?

    public init(accountID: String, zoneID: String, domain: String? = nil) {
        self.accountID = accountID
        self.zoneID = zoneID
        self.domain = domain
    }

    /// The hostname to offer when the user has not chosen one.
    public var suggestedHostname: String? {
        guard let domain, !domain.isEmpty else { return nil }
        return "mcp.\(domain)"
    }
}

public enum CloudflareAccountError: LocalizedError, Equatable {
    case certificateMissing(path: String)
    case certificateUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .certificateMissing(path):
            return "No Cloudflare login found at \(path). Log in to Cloudflare first."
        case let .certificateUnreadable(detail):
            return "The Cloudflare login certificate could not be read: \(detail)"
        }
    }
}

public enum CloudflareAccount {
    /// The credential embedded in cert.pem. Deliberately not `Codable` beyond
    /// decoding, and deliberately never stored: it lives only long enough to
    /// make the zone-name request.
    private struct OriginCertificate: Decodable {
        let accountID: String
        let zoneID: String
        let apiToken: String
    }

    /// Reads the certificate and resolves the zone name from Cloudflare.
    ///
    /// Resolving the name is best-effort by design. The certificate's token is
    /// scoped to tunnel and DNS work on that one zone, and Apple Core does not
    /// depend on it also permitting a zone read: when the call is refused or
    /// the machine is offline, the IDs are still returned and the pane falls
    /// back to asking for the domain.
    public static func resolve(
        certificatePath: String = CloudflareManager.originCertificatePath(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) async throws -> CloudflareAccountInfo {
        let certificate = try readCertificate(at: certificatePath, fileManager: fileManager)
        let domain = await zoneName(
            zoneID: certificate.zoneID,
            apiToken: certificate.apiToken,
            session: session
        )
        return CloudflareAccountInfo(
            accountID: certificate.accountID,
            zoneID: certificate.zoneID,
            domain: domain
        )
    }

    /// True when a login certificate exists and parses. Used to tell "signed
    /// in" from "a stale or hand-made file is sitting there".
    public static func isSignedIn(
        certificatePath: String = CloudflareManager.originCertificatePath(),
        fileManager: FileManager = .default
    ) -> Bool {
        (try? readCertificate(at: certificatePath, fileManager: fileManager)) != nil
    }

    // MARK: - Certificate

    private static func readCertificate(
        at path: String,
        fileManager: FileManager
    ) throws -> OriginCertificate {
        guard fileManager.fileExists(atPath: path) else {
            throw CloudflareAccountError.certificateMissing(path: path)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CloudflareAccountError.certificateUnreadable(error.localizedDescription)
        }

        guard let payload = base64Payload(in: contents) else {
            throw CloudflareAccountError.certificateUnreadable("no Argo Tunnel token block was found")
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            throw CloudflareAccountError.certificateUnreadable("the token block was not valid base64")
        }
        do {
            return try JSONDecoder().decode(OriginCertificate.self, from: data)
        } catch {
            throw CloudflareAccountError.certificateUnreadable("the token did not contain the expected fields")
        }
    }

    /// Pulls the base64 body out of the PEM framing.
    ///
    /// Older certificates carry a private key and an X.509 certificate ahead of
    /// the token, so the whole file cannot simply be stripped of its dashes;
    /// only the ARGO TUNNEL TOKEN block is wanted. Files that contain nothing
    /// but the token block are handled by the same path.
    static func base64Payload(in contents: String) -> String? {
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
        var payload: [String] = []
        var insideTokenBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN") {
                insideTokenBlock = trimmed.uppercased().contains("ARGO TUNNEL TOKEN")
                continue
            }
            if trimmed.hasPrefix("-----END") {
                if insideTokenBlock { break }
                continue
            }
            if insideTokenBlock {
                payload.append(trimmed)
            }
        }

        let joined = payload.joined()
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Zone name

    private static func zoneName(zoneID: String, apiToken: String, session: URLSession) async -> String? {
        guard !zoneID.isEmpty, !apiToken.isEmpty,
            let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                // Includes the refused-scope case. Not an error worth showing:
                // the caller degrades to asking for the domain.
                logMessage("CloudflareAccount: zone lookup did not succeed; domain will be requested instead.")
                return nil
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let result = root["result"] as? [String: Any],
                let name = result["name"] as? String,
                !name.isEmpty
            else {
                return nil
            }
            return name
        } catch {
            // Offline, or the API is unreachable. Same fallback.
            return nil
        }
    }
}
