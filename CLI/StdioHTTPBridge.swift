// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MCP

actor StdioOutput {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A closed stdout or stderr means the parent process has gone
            // away. There is no second channel on which this can be reported.
        }
    }
}

/// Bidirectional stdio bridge backed by the pinned MCP SDK's Streamable HTTP
/// transport. Each request gets its own send task, so a cancellation
/// notification can overtake a long-running request. The transport's GET SSE
/// loop forwards unsolicited server notifications through one serialized
/// stdout writer.
actor StdioHTTPBridge {
    private struct PendingSend {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let endpoint: URL
    private let token: String
    private let transport: HTTPClientTransport
    private let standardOutput = StdioOutput(handle: .standardOutput)
    private let standardError = StdioOutput(handle: .standardError)

    private var pendingRequests: [String: PendingSend] = [:]
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var isClosing = false

    init(baseURL: URL, token: String) {
        let endpoint = baseURL.appendingPathComponent("mcp")
        self.endpoint = endpoint
        self.token = token
        self.transport = HTTPClientTransport(
            endpoint: endpoint,
            streaming: true,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
        )
    }

    func connect() async throws {
        try await transport.connect()
        let messages = await transport.receive()
        receiveTask = Task { [weak self] in
            do {
                for try await data in messages {
                    guard !Task.isCancelled else { break }
                    await self?.relayReceived(data)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.standardError.writeLine("apple-core-cli: receive stream failed: \(error)")
            }
        }
    }

    /// Starts one send without waiting for its HTTP response. Request tasks are
    /// keyed by their type-preserving JSON-RPC ID so `notifications/cancelled`
    /// can stop the matching POST while still being sent to the server itself.
    func submit(_ line: String) async {
        guard !isClosing else { return }

        if let cancelledKey = JSONRPCRequestKey.cancelledRequestKey(from: line) {
            pendingRequests[cancelledKey]?.task.cancel()
            startNotificationSend(line)
            return
        }

        let classification = JSONRPCRequestKey.classifyInbound(message: line)
        if case .invalid = classification {
            await standardError.writeLine("apple-core-cli: ignored invalid JSON-RPC input")
            return
        }

        guard let requestKey = JSONRPCRequestKey.from(message: line) else {
            startNotificationSend(line)
            return
        }
        guard pendingRequests[requestKey] == nil else {
            if let errorLine = Self.jsonRPCError(
                for: line,
                message: "A request with this JSON-RPC id is already in flight"
            ) {
                await standardOutput.writeLine(errorLine)
            }
            return
        }

        let sendToken = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sendRequest(line, requestKey: requestKey, sendToken: sendToken)
        }
        pendingRequests[requestKey] = PendingSend(token: sendToken, task: task)
    }

    func close() async {
        guard !isClosing else { return }
        isClosing = true

        let requestTasks = pendingRequests.values.map(\.task)
        let oneWayTasks = Array(notificationTasks.values)
        requestTasks.forEach { $0.cancel() }
        oneWayTasks.forEach { $0.cancel() }
        receiveTask?.cancel()

        let sessionID = await transport.sessionID
        if let sessionID {
            await deleteSession(sessionID)
        }
        await transport.disconnect()

        for task in requestTasks { await task.value }
        for task in oneWayTasks { await task.value }
        await receiveTask?.value

        pendingRequests.removeAll()
        notificationTasks.removeAll()
        receiveTask = nil
    }

    private func relayReceived(_ data: Data) async {
        guard !isClosing,
            let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty
        else {
            return
        }
        await standardOutput.writeLine(line)
    }

    private func sendRequest(_ line: String, requestKey: String, sendToken: UUID) async {
        do {
            try await transport.send(Data(line.utf8))
        } catch {
            if !Task.isCancelled,
                let errorLine = Self.jsonRPCError(for: line, message: Self.message(for: error))
            {
                await standardOutput.writeLine(errorLine)
                await standardError.writeLine("apple-core-cli: request failed: \(error)")
            }
        }
        finishRequest(requestKey: requestKey, sendToken: sendToken)
    }

    private func startNotificationSend(_ line: String) {
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(Data(line.utf8))
            } catch {
                if !Task.isCancelled {
                    await self.standardError.writeLine("apple-core-cli: notification failed: \(error)")
                }
            }
            await self.finishNotification(taskID)
        }
        notificationTasks[taskID] = task
    }

    private func finishRequest(requestKey: String, sendToken: UUID) {
        guard pendingRequests[requestKey]?.token == sendToken else { return }
        pendingRequests.removeValue(forKey: requestKey)
    }

    private func finishNotification(_ taskID: UUID) {
        notificationTasks.removeValue(forKey: taskID)
    }

    private func deleteSession(_ sessionID: String) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                [200, 202, 204, 404].contains(http.statusCode)
            else {
                await standardError.writeLine("apple-core-cli: session cleanup returned an unexpected response")
                return
            }
        } catch {
            await standardError.writeLine("apple-core-cli: session cleanup failed: \(error)")
        }
    }

    private static func message(for error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("session expired") {
            return "Apple Core session expired; reconnect by re-initializing"
        }
        return "Could not exchange a message with the Apple Core app"
    }

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
        guard let responseData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: responseData, encoding: .utf8)
    }
}
