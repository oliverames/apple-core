// SPDX-License-Identifier: GPL-3.0-or-later
//
// This file is new: it does not exist in Bridgeport. Bridgeport's
// BridgeSession (SSEServer.swift) bridges an HTTP/SSE client to a *child
// process* speaking MCP over stdio (ProcessBridge). Apple Core has no child
// process -- ServerController's `registerHandlers(for:connectionID:)`
// dispatches directly against an in-process `MCP.Server`, exactly as it did
// over the old NWConnection/NetworkTransport transport. So instead of
// porting BridgeSession as-is, this adapts its session/stream bookkeeping to
// bridge HTTP/SSE to an `MCP.Transport` conformance (`SSETransport`) that
// `MCP.Server.start(transport:)` can drive directly, in place of the
// swift-sdk's own `NetworkTransport`.

import FlyingSocks
import Foundation
import Logging
import MCP

/// An `MCP.Transport` conformance backed by HTTP request/response bodies and
/// Server-Sent Events, instead of a raw `NWConnection`. One instance is
/// created per MCP session (one per SSE/streamable-HTTP client connection).
///
/// - `receive()` yields the JSON-RPC messages the HTTP layer feeds in via
///   `feedInbound(_:)` (the bodies of client POSTs).
/// - `send(_:)` hands outbound JSON-RPC messages to whatever SSE writer the
///   HTTP layer has wired up via `setOutboundWriter(_:)`.
public actor SSETransport: Transport {
    public nonisolated let logger: Logger

    private let inboundStream: AsyncThrowingStream<Data, Swift.Error>
    private var inboundContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var outboundWriter: (@Sendable (Data) -> Void)?
    private var connected = false

    public init(logger: Logger = Logger(label: "com.oliverames.applecore.sse-transport")) {
        self.logger = logger
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        connected = false
        inboundContinuation?.finish()
        inboundContinuation = nil
    }

    public func send(_ data: Data) async throws {
        outboundWriter?(data)
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        inboundStream
    }

    public var isConnected: Bool {
        connected
    }

    /// Called by the HTTP layer when a client POSTs a JSON-RPC message body.
    public func feedInbound(_ data: Data) {
        inboundContinuation?.yield(data)
    }

    /// Called once by the owning `MCPSSESession` so outbound server messages
    /// reach the HTTP/SSE byte streams.
    public func setOutboundWriter(_ writer: @escaping @Sendable (Data) -> Void) {
        outboundWriter = writer
    }
}

/// Bridges one `SSETransport`'s outbound JSON-RPC messages to one or more
/// open HTTP responses (persistent SSE streams, or a single-shot response
/// stream keyed by JSON-RPC request id for the Streamable HTTP POST case).
///
/// Adapted from the stream-bookkeeping half of Bridgeport's `BridgeSession`;
/// the subprocess plumbing (`ProcessBridge`) has no equivalent here since
/// there is no child process, only the transport above.
public actor MCPSSESession {
    public nonisolated let id: String

    private let transport: SSETransport
    private var streams: [String: AsyncStream<[UInt8]>.Continuation] = [:]
    private var responseStreams: [String: AsyncStream<[UInt8]>.Continuation] = [:]
    private var onClose: (@Sendable () -> Void)?
    private var isClosed = false
    private var lastActivityAt = Date()

    public init(id: String, transport: SSETransport) {
        self.id = id
        self.transport = transport
    }

    /// Wires this session as the transport's outbound sink and remembers the
    /// close callback. Call once, before handing the transport to
    /// `MCP.Server.start(transport:)`.
    public func start(onClose: @escaping @Sendable () -> Void) async {
        self.onClose = onClose
        await transport.setOutboundWriter { [weak self] data in
            guard let self else { return }
            Task { await self.routeOutbound(data) }
        }
    }

    public func addPersistentStream(initialEvents: [String] = []) -> (String, AsyncStream<[UInt8]>) {
        let streamId = UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        streams[streamId] = continuation
        lastActivityAt = Date()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removePersistentStream(id: streamId)
            }
        }
        for event in initialEvents {
            write(event, to: continuation)
        }
        return (streamId, stream)
    }

    public func removePersistentStream(id: String) {
        if let continuation = streams.removeValue(forKey: id) {
            continuation.finish()
            lastActivityAt = Date()
        }
    }

    public func responseStream(for requestId: String) -> AsyncStream<[UInt8]> {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        responseStreams[requestId] = continuation
        lastActivityAt = Date()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeResponseStream(id: requestId)
            }
        }
        return stream
    }

    /// True when the session has no open client streams and has seen no
    /// traffic for longer than `interval`, so it can be reclaimed safely.
    /// Clients that reuse the session id after a reap receive 404 and
    /// re-initialize per the Streamable HTTP spec.
    public func isIdle(olderThan interval: TimeInterval, now: Date = Date()) -> Bool {
        streams.isEmpty && responseStreams.isEmpty && now.timeIntervalSince(lastActivityAt) > interval
    }

    public func sendNotification(_ message: String) {
        let event = Self.sseMessageEvent(message)
        for continuation in streams.values {
            write(event, to: continuation)
        }
    }

    /// Feeds a client-submitted JSON-RPC message body into the transport, so
    /// `MCP.Server` reads it via `Transport.receive()`.
    public func writeToServer(_ message: String) async {
        lastActivityAt = Date()
        await transport.feedInbound(Data(message.utf8))
    }

    public func close(callOnClose: Bool = true) async {
        guard !isClosed else { return }
        isClosed = true

        for continuation in streams.values {
            continuation.finish()
        }
        streams.removeAll()

        for continuation in responseStreams.values {
            continuation.finish()
        }
        responseStreams.removeAll()

        await transport.disconnect()
        if callOnClose {
            onClose?()
        }
    }

    private func removeResponseStream(id: String) {
        responseStreams.removeValue(forKey: id)
    }

    /// Routes one outbound JSON-RPC message (from `MCP.Server` via
    /// `SSETransport.send(_:)`) to the response stream matching its id, if
    /// any is waiting; otherwise broadcasts it to every open persistent
    /// stream (server-initiated notifications, tool-list-changed, etc.).
    private func routeOutbound(_ data: Data) {
        lastActivityAt = Date()
        guard let message = String(data: data, encoding: .utf8) else { return }
        let event = Self.sseMessageEvent(message)
        if let requestId = Self.jsonRPCID(from: message),
            let continuation = responseStreams.removeValue(forKey: requestId)
        {
            write(event, to: continuation)
            continuation.finish()
            return
        }

        for continuation in streams.values {
            write(event, to: continuation)
        }
    }

    private func write(_ event: String, to continuation: AsyncStream<[UInt8]>.Continuation) {
        continuation.yield(Array(event.utf8))
    }

    public static func sseMessageEvent(_ message: String) -> String {
        "event: message\ndata: \(message)\n\n"
    }

    public static func jsonRPCID(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"]
        else {
            return nil
        }
        return String(describing: id)
    }
}

/// A `FlyingSocks.AsyncBufferedSequence` view over `AsyncStream<[UInt8]>`, so
/// its byte chunks can back a FlyingFox `HTTPBodySequence`. Ported verbatim
/// from Bridgeport's `StreamSequence` (SSEServer.swift); transport-agnostic.
public struct SSEByteSequence: AsyncBufferedSequence, Sendable {
    public typealias Element = UInt8
    public typealias AsyncIterator = Iterator

    private let stream: AsyncStream<[UInt8]>

    public init(stream: AsyncStream<[UInt8]>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(iterator: stream.makeAsyncIterator())
    }

    public struct Iterator: AsyncBufferedIteratorProtocol, @unchecked Sendable {
        public typealias Element = UInt8
        public typealias Buffer = [UInt8]

        private var iterator: AsyncStream<[UInt8]>.Iterator
        private var pending: [UInt8] = []
        private var pendingIndex = 0

        public init(iterator: AsyncStream<[UInt8]>.Iterator) {
            self.iterator = iterator
        }

        public mutating func next() async -> UInt8? {
            if pendingIndex < pending.count {
                let byte = pending[pendingIndex]
                pendingIndex += 1
                return byte
            }
            while let chunk = await iterator.next() {
                guard !chunk.isEmpty else { continue }
                pending = chunk
                pendingIndex = 1
                return chunk[0]
            }
            return nil
        }

        public mutating func nextBuffer(suggested count: Int) async throws -> [UInt8]? {
            guard count > 0 else { return [] }
            if pendingIndex < pending.count {
                let chunk = Array(pending[pendingIndex...])
                pending = []
                pendingIndex = 0
                return chunk
            }
            while let chunk = await iterator.next() {
                guard !chunk.isEmpty else { continue }
                return chunk
            }
            return nil
        }
    }
}
