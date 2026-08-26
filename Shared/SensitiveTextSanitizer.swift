// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SensitiveTextSanitizer {
    static func redactAssignmentsAndValues(
        in value: String,
        keys: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var sanitized = value
        for key in keys where !key.isEmpty {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            sanitized = sanitized.replacingOccurrences(
                of: #"(?m)\b"# + escapedKey
                    + #"\s*=\s*(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\r\n]*)"#,
                with: key + "=[redacted]",
                options: .regularExpression
            )
            if let secret = environment[key], !secret.isEmpty {
                sanitized = sanitized.replacingOccurrences(of: secret, with: "[redacted]")
            }
        }
        return sanitized
    }
}
