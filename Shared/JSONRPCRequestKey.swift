// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

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

        if let string = identifier as? String {
            return "string:\(string)"
        }
        if identifier is NSNull {
            return "null"
        }
        if let number = identifier as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            return "number:\(number)"
        }
        return nil
    }
}
