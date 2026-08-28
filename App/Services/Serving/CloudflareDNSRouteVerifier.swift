// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum CloudflareDNSRouteStatus: Sendable, Equatable {
    case matches
    case missing
    case pointsElsewhere(String)
    case unavailable(String)
}

/// Builds and validates the Cloudflare API lookup used before Apple Core
/// adopts an existing tunnel DNS record. The API token stays in the request
/// header and is never returned in an error or log message.
public enum CloudflareDNSRouteVerifier {
    private struct ResponseEnvelope: Decodable {
        let success: Bool
        let result: [Record]?
    }

    private struct Record: Decodable {
        let type: String
        let name: String
        let content: String
    }

    public static func request(
        zoneID: String,
        hostname: String,
        apiToken: String
    ) -> URLRequest? {
        let zoneID = zoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zoneID.isEmpty, !hostname.isEmpty, !apiToken.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.cloudflare.com"
        components.path = "/client/v4/zones/\(zoneID)/dns_records"
        components.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "type", value: "CNAME"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    public static func evaluate(
        data: Data,
        response: URLResponse,
        hostname: String,
        tunnelID: String
    ) -> CloudflareDNSRouteStatus {
        guard let http = response as? HTTPURLResponse else {
            return .unavailable("Cloudflare returned a non-HTTP response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            return .unavailable("Cloudflare DNS verification returned HTTP \(http.statusCode).")
        }
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data), envelope.success,
            let records = envelope.result
        else {
            return .unavailable("Cloudflare returned an unreadable DNS response.")
        }

        let requestedName = normalizedDNSName(hostname)
        let matchingRecords = records.filter {
            $0.type.caseInsensitiveCompare("CNAME") == .orderedSame
                && normalizedDNSName($0.name) == requestedName
        }
        guard !matchingRecords.isEmpty else { return .missing }

        let expectedTarget = normalizedDNSName("\(tunnelID).cfargotunnel.com")
        if matchingRecords.count == 1,
            normalizedDNSName(matchingRecords[0].content) == expectedTarget
        {
            return .matches
        }

        return .pointsElsewhere(matchingRecords.map(\.content).joined(separator: ", "))
    }

    public static func normalizedDNSName(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }
}
