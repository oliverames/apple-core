// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe numeric conversions for values supplied by MCP clients. The advertised
/// JSON Schema helps clients form requests, but handlers must still tolerate a
/// caller that sends an out-of-range number.
enum NumericArgument {
    static func clampedInt(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clampedInt(_ value: Double, to range: ClosedRange<Int>) -> Int? {
        guard value.isFinite else { return nil }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return Int(value)
    }

    static func clampedDouble(_ value: Double, to range: ClosedRange<Double>) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func validatedDouble(_ value: Double, in range: ClosedRange<Double>) -> Double? {
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func uint32(_ value: Int) -> UInt32? {
        UInt32(exactly: value)
    }
}
