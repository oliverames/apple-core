// SPDX-License-Identifier: GPL-3.0-or-later
//
// This CLI target used to be a Bonjour-discovery + NWConnection stdio proxy
// (StdioProxy) in front of the app's Bonjour-advertised MCP server. Now that
// the app serves MCP directly over local HTTP/SSE (see
// App/Services/Serving/AppleCoreHTTPServer.swift), most MCP clients (Claude
// Desktop custom connectors, browser-based clients, anything that speaks
// Streamable HTTP or SSE) can talk to the app directly and don't need this
// binary at all.
//
// It is kept, repurposed, as a thin stdio<->local-HTTP bridge for MCP
// clients that only support launching a stdio subprocess (no HTTP/SSE
// transport option). Bridgeport does not have an equivalent -- it expects
// every client to speak HTTP/SSE directly -- so this is new code, not a
// port, following the same shape a stdio-only MCP client integration
// commonly takes: read one JSON-RPC message per line from stdin, POST it to
// the app's Streamable HTTP endpoint, and write any response line to
// stdout.

import Foundation

struct CLIServingConfig: Decodable {
    var token: String?
    var port: UInt16?
    var bindHost: String?
}

func loadServingConfig() -> CLIServingConfig {
    let environment = ProcessInfo.processInfo.environment
    let configDirectory: URL
    if let override = environment["APPLECORE_CONFIG_HOME"],
        !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        configDirectory = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
    } else {
        configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/apple-core")
    }

    let configURL = configDirectory.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
        let config = try? JSONDecoder().decode(CLIServingConfig.self, from: data)
    else {
        return CLIServingConfig()
    }
    return config
}

/// Forwards JSON-RPC messages to the app's `/mcp` Streamable HTTP endpoint
/// and unwraps the SSE-framed response back into a bare JSON-RPC line.
actor StdioHTTPBridge {
    private let mcpEndpoint: URL
    private let token: String
    private var sessionID: String?

    init(baseURL: URL, token: String) {
        self.mcpEndpoint = baseURL.appendingPathComponent("mcp")
        self.token = token
    }

    /// Sends one JSON-RPC message. Returns the response line to print to
    /// stdout, or nil for notifications/errors (nothing to reply with).
    func send(_ line: String) async -> String? {
        var request = URLRequest(url: mcpEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = Data(line.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                FileHandle.standardError.write(Data("apple-core-cli: non-HTTP response\n".utf8))
                return Self.jsonRPCError(for: line, message: "Apple Core returned a non-HTTP response")
            }
            if http.statusCode == 404, sessionID != nil {
                // The server reaped this session after ten idle minutes.
                // Replay the stored header forever and every future request
                // 404s with no recovery path; drop it so the next initialize
                // starts a fresh session, and tell the client why this one
                // died instead of answering with silence.
                sessionID = nil
                FileHandle.standardError.write(
                    Data("apple-core-cli: session expired on server; will start a new one\n".utf8)
                )
                return Self.jsonRPCError(
                    for: line,
                    message: "Apple Core session expired; reconnect by re-initializing"
                )
            }
            if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = newSessionID
            }
            guard http.statusCode == 200 || http.statusCode == 202 else {
                FileHandle.standardError.write(Data("apple-core-cli: HTTP \(http.statusCode)\n".utf8))
                return Self.jsonRPCError(
                    for: line,
                    message: "Apple Core returned HTTP \(http.statusCode)"
                )
            }
            if http.statusCode == 202 {
                // Notification: accepted, no response body to relay.
                return nil
            }
            guard let body = String(data: data, encoding: .utf8),
                let payload = Self.jsonRPCPayload(fromSSEBody: body)
            else {
                return Self.jsonRPCError(for: line, message: "Apple Core returned an invalid response body")
            }
            return payload
        } catch {
            FileHandle.standardError.write(Data("apple-core-cli: request failed: \(error)\n".utf8))
            return Self.jsonRPCError(for: line, message: "Could not reach the Apple Core app")
        }
    }

    /// Builds a JSON-RPC error response matching `line`'s request id, so a
    /// stdio client sees a protocol-level failure rather than waiting forever.
    /// A notification has no id and expects no reply.
    private static func jsonRPCError(for line: String, message: String) -> String? {
        guard let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = request["id"]
        else {
            return nil
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32000,
                "message": message,
            ],
        ]
        guard
            let responseData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: responseData, encoding: .utf8)
    }

    /// The `/mcp` endpoint replies to request-carrying POSTs with a single
    /// Server-Sent Event frame (`event: message\ndata: <json>\n\n`). Pull
    /// the JSON-RPC payload out of the last `data:` line.
    private static func jsonRPCPayload(fromSSEBody body: String) -> String? {
        var payload: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("data: ") {
                payload = String(line.dropFirst("data: ".count))
            }
        }
        if let payload {
            return payload
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

let servingConfig = loadServingConfig()
guard let token = servingConfig.token, !token.isEmpty else {
    FileHandle.standardError.write(
        Data(
            "apple-core-cli: no serving token found in ~/.config/apple-core/config.json. Launch the Apple Core app once so it can generate one.\n"
                .utf8
        )
    )
    exit(1)
}

let port = servingConfig.port ?? 8756
let bindHost = servingConfig.bindHost ?? "127.0.0.1"
// IPv6 literals need brackets in a URL authority: URL(string:) rejects
// "http://::1:8756/" outright even though the app binds ::1 deliberately.
let urlHost = bindHost.contains(":") && !bindHost.hasPrefix("[") ? "[\(bindHost)]" : bindHost
guard let baseURL = URL(string: "http://\(urlHost):\(port)/") else {
    FileHandle.standardError.write(Data("apple-core-cli: invalid bind host/port\n".utf8))
    exit(1)
}

let bridge = StdioHTTPBridge(baseURL: baseURL, token: token)

// Read newline-delimited JSON-RPC messages from stdin (the framing every
// stdio-based MCP client already speaks), forward each over HTTP in order,
// and write any response back to stdout.
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }

    if let responseLine = await bridge.send(trimmed) {
        print(responseLine)
        fflush(stdout)
    }
}
