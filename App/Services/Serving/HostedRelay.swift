// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct HostedSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var tenantID: String
    public var relayCredential: String
    public var ownerMachineID: String
    public static let origin = "https://mcp.applecore.app"

    public var belongsToThisMac: Bool { ownerMachineID == MachineIdentity.currentID() }
}

/// An outbound connection, never a general-purpose proxy to the user's LAN.
actor HostedRelay {
    static let shared = HostedRelay()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var requests: [String: Task<Void, Never>] = [:]
    private(set) var status = "Hosted access is off"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 95
        return URLSession(configuration: config, delegate: NoRelayRedirects(), delegateQueue: nil)
    }()

    func start(config: AppleCoreServingConfig) {
        stop()
        guard let hosted = config.hosted, hosted.enabled else { return }
        guard hosted.belongsToThisMac else { status = "Hosted access belongs to another Mac"; return }
        guard hosted.tenantID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
            !hosted.relayCredential.isEmpty
        else { status = "Hosted setup is incomplete"; return }
        let generation = self.generation
        task = Task { await connect(hosted: hosted, port: config.port ?? 8756, generation: generation) }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for request in requests.values { request.cancel() }
        requests.removeAll()
        status = "Hosted access is off"
    }

    private func connect(hosted: HostedSettings, port: UInt16, generation: UUID) async {
        var delay = 2
        while !Task.isCancelled && self.generation == generation {
            status = "Connecting to Apple Core hosting…"
            var request = URLRequest(url: URL(string: "wss://mcp.applecore.app/bridge/\(hosted.tenantID)")!)
            request.setValue("Bearer \(hosted.relayCredential)", forHTTPHeaderField: "Authorization")
            let ws = session.webSocketTask(with: request)
            ws.maximumMessageSize = 1_500_000
            socket = ws
            ws.resume()
            let heartbeat = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(20))
                    try await ws.send(.string("ping"))
                }
            }
            do {
                // Ping completion confirms the WebSocket upgrade, unlike resume().
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    ws.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                guard !Task.isCancelled && self.generation == generation else {
                    heartbeat.cancel()
                    ws.cancel(with: .goingAway, reason: nil)
                    break
                }
                status = "Hosted access is connected"
                delay = 2
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard case .string(let value) = message, value != "pong" else { continue }
                    guard let data = value.data(using: .utf8),
                        let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw URLError(.cannotParseResponse) }
                    if let cancel = frame["cancel"] as? String {
                        requests.removeValue(forKey: cancel)?.cancel(); continue
                    }
                    let decoded = try JSONDecoder().decode(RelayRequest.self, from: data)
                    guard requests.count < 4, requests[decoded.id] == nil else { throw URLError(.resourceUnavailable) }
                    requests[decoded.id] = Task {
                        await self.forward(decoded, port: port, socket: ws)
                        self.requests.removeValue(forKey: decoded.id)
                    }
                }
            } catch {
                if !Task.isCancelled && self.generation == generation {
                    status = "Hosted connection interrupted; reconnecting…"
                }
            }
            heartbeat.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            guard self.generation == generation else { break }
            for request in requests.values { request.cancel() }
            requests.removeAll()
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
    }

    private func forward(_ message: RelayRequest, port: UInt16, socket: URLSessionWebSocketTask) async {
        do {
            guard message.isAllowed, let body = Data(base64Encoded: message.body), body.count <= 1_048_576 else {
                throw URLError(.badURL)
            }
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = Int(port)
            components.path = message.path
            components.percentEncodedQuery = message.query.isEmpty ? nil : message.query
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = message.method
            if message.method == "POST" { request.httpBody = body }
            for name in ["authorization", "content-type", "accept", "mcp-session-id", "mcp-protocol-version"] {
                if let value = message.headers[name] { request.setValue(value, forHTTPHeaderField: name) }
            }
            // Classify this as remote even though transport ends at loopback.
            request.setValue("mcp.applecore.app", forHTTPHeaderField: "Host")
            request.setValue("198.51.100.1", forHTTPHeaderField: "X-Forwarded-For")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var headers: [String: String] = [:]
            for name in ["content-type", "mcp-session-id", "www-authenticate", "location", "allow"] {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            try await send(["id": message.id, "status": response.statusCode, "headers": headers], socket: socket)
            var chunk = Data()
            var total = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                total += 1
                guard total <= 8_388_608 else { throw URLError(.dataLengthExceedsMaximum) }
                chunk.append(byte)
                if chunk.count >= 32_768 {
                    try await send(["id": message.id, "chunk": chunk.base64EncodedString()], socket: socket)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try await send(["id": message.id, "chunk": chunk.base64EncodedString()], socket: socket)
            }
            try await send(["id": message.id, "done": true], socket: socket)
        } catch {
            // Never send a partially successful body as a completed response.
            socket.cancel(with: .internalServerError, reason: nil)
        }
    }

    private func send(_ frame: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let value = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        try await socket.send(.string(value))
    }
}

private struct RelayRequest: Decodable, Sendable {
    let id: String
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: String

    var isAllowed: Bool {
        guard UUID(uuidString: id) != nil, query.count <= 16_384 else { return false }
        switch path {
        case "/mcp": return ["POST", "DELETE"].contains(method) && query.isEmpty
        case "/oauth/authorize": return ["GET", "POST"].contains(method)
        case "/oauth/token", "/oauth/revoke": return method == "POST" && query.isEmpty
        default: return false
        }
    }
}

private final class NoRelayRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
