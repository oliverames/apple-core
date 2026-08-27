// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

enum JSONRPCInboundMessage: Equatable {
    case request(requestKey: String)
    case notificationOrResponse
    case invalid
}

/// Builds a type-preserving dictionary key for a JSON-RPC request identifier.
/// JSON string `"1"` and JSON number `1` are different identifiers even
/// though `String(describing:)` renders both as `1`.
enum JSONRPCRequestKey {
    static func from(message: String) -> String? {
        guard let data = message.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = object["id"]
        else {
            return nil
        }

        return from(identifier: identifier)
    }

    /// Classifies one client-to-server MCP body before it is allowed to
    /// allocate a session. MCP accepts one JSON-RPC object per HTTP request,
    /// not malformed JSON, scalars, or JSON-RPC batches.
    static func classifyInbound(message: String) -> JSONRPCInboundMessage {
        guard let data = message.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["jsonrpc"] as? String == "2.0"
        else {
            return .invalid
        }

        if object.keys.contains("method") {
            guard object["method"] is String else { return .invalid }
            guard object.keys.contains("id") else { return .notificationOrResponse }
            guard let identifier = object["id"], let requestKey = from(identifier: identifier) else {
                return .invalid
            }
            return .request(requestKey: requestKey)
        }

        guard let identifier = object["id"], from(identifier: identifier) != nil else {
            return .invalid
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        return hasResult != hasError ? .notificationOrResponse : .invalid
    }

    private static func from(identifier: Any) -> String? {
        if let string = identifier as? String {
            return "string:\(string)"
        }
        if identifier is NSNull { return nil }
        if let number = identifier as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            // The pinned MCP SDK decodes numeric IDs as Int. Fractional and
            // out-of-range JSON numbers otherwise pass this classifier, then
            // fail SDK decoding after the HTTP layer has opened a response
            // stream that can never receive a matching response.
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: number,
                    options: .fragmentsAllowed
                ),
                let integer = try? JSONDecoder().decode(Int.self, from: data)
            else {
                return nil
            }
            return "number:\(integer)"
        }
        return nil
    }
}
