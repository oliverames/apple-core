// SPDX-License-Identifier: GPL-3.0-or-later

import MCP

extension Value {
    /// A Double whether the client sent a JSON number with or without a
    /// decimal point. The MCP SDK's decoder tries Int before Double, so
    /// `"latitude": 44` arrives as `.int(44)`, and every schema here declares
    /// plain `number`, which JSON Schema defines to include integers — the
    /// strict `case .double` / `.doubleValue` extractions rejected inputs the
    /// schemas advertise as valid.
    public var doubleCoerced: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }
}
