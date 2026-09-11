// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether the Mac on the other end of the connector is about to run out of
// battery.
//
// `utilities_storage_summary` reports disk, memory, thermal state and low
// power mode. It says nothing about power, which for a laptop serving a
// connector is the single fact that decides whether the next long job is worth
// starting. Nothing in the surveyed servers reports it at all.
//
// The mapping from IOKit's power-source dictionary lives here, away from
// IOKit, because every interesting case in it is a quirk worth a test: a
// desktop has no battery, a percentage is two numbers rather than one, and the
// time estimates are -1 for a good ten minutes after a charger is plugged in
// while the system works out a new estimate.

import Foundation

public struct PowerSummary: Equatable, Sendable {
    /// Where the Mac is drawing power from right now.
    public enum Source: String, Equatable, Sendable {
        case ac
        case battery
        case ups
        case unknown
    }

    public let hasBattery: Bool
    public let source: Source
    /// 0-100, or nil on a Mac with no battery.
    public let percentRemaining: Int?
    public let isCharging: Bool
    public let isFullyCharged: Bool
    /// Minutes of use left on the current charge. Nil while the system is
    /// still working the estimate out, which is a different fact from zero.
    public let minutesRemaining: Int?
    public let minutesToFullCharge: Int?
    /// True when macOS has not settled on a time estimate yet.
    public let timeEstimateIsCalculating: Bool
    /// IOKit's battery condition, such as "Normal" or "Service Recommended".
    public let condition: String?

    public init(
        hasBattery: Bool,
        source: Source,
        percentRemaining: Int?,
        isCharging: Bool,
        isFullyCharged: Bool,
        minutesRemaining: Int?,
        minutesToFullCharge: Int?,
        timeEstimateIsCalculating: Bool,
        condition: String?
    ) {
        self.hasBattery = hasBattery
        self.source = source
        self.percentRemaining = percentRemaining
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.minutesRemaining = minutesRemaining
        self.minutesToFullCharge = minutesToFullCharge
        self.timeEstimateIsCalculating = timeEstimateIsCalculating
        self.condition = condition
    }

    /// A Mac with no battery at all: a desktop, or a laptop whose battery
    /// IOKit cannot see.
    public static let noBattery = PowerSummary(
        hasBattery: false,
        source: .ac,
        percentRemaining: nil,
        isCharging: false,
        isFullyCharged: false,
        minutesRemaining: nil,
        minutesToFullCharge: nil,
        timeEstimateIsCalculating: false,
        condition: nil
    )

    /// Keys as IOKit spells them. Named here so the mapping can be tested
    /// without linking IOKit into the test target.
    public enum Key {
        public static let currentCapacity = "Current Capacity"
        public static let maxCapacity = "Max Capacity"
        public static let isCharging = "Is Charging"
        public static let isCharged = "Is Charged"
        public static let isPresent = "Is Present"
        public static let powerSourceState = "Power Source State"
        public static let timeToEmpty = "Time to Empty"
        public static let timeToFullCharge = "Time to Full Charge"
        public static let condition = "BatteryHealth"
        public static let type = "Type"
    }

    /// Maps one power-source description.
    ///
    /// The percentage is computed from both capacities rather than read from
    /// `Current Capacity` directly. On most Macs `Max Capacity` is 100 and the
    /// two agree, but on a Mac reporting raw milliamp-hours they do not, and
    /// reading the raw number would report a full battery as 4381 per cent.
    public static func from(description: [String: Any]) -> PowerSummary {
        let isPresent = description[Key.isPresent] as? Bool ?? true
        guard isPresent else { return .noBattery }

        let current = numeric(description[Key.currentCapacity])
        let maximum = numeric(description[Key.maxCapacity])
        var percent: Int?
        if let current, let maximum, maximum > 0 {
            percent = min(100, max(0, Int((current / maximum * 100).rounded())))
        } else if let current, current <= 100 {
            percent = Int(current.rounded())
        }

        let state = (description[Key.powerSourceState] as? String)?.lowercased() ?? ""
        let type = (description[Key.type] as? String)?.lowercased() ?? ""
        let source: Source
        if type.contains("ups") {
            source = .ups
        } else if state.contains("ac") {
            source = .ac
        } else if state.contains("battery") {
            source = .battery
        } else {
            source = .unknown
        }

        // -1 is IOKit's "still calculating". Anything negative is treated the
        // same way: a negative number of minutes is never an answer, and
        // reporting it as one would have a caller believe the battery ran out
        // some time ago.
        let rawToEmpty = numeric(description[Key.timeToEmpty]).map { Int($0) }
        let rawToFull = numeric(description[Key.timeToFullCharge]).map { Int($0) }
        let isCharging = description[Key.isCharging] as? Bool ?? false
        let relevantEstimate = isCharging ? rawToFull : rawToEmpty

        // On mains power IOKit reports zero minutes to empty, which is not an
        // estimate of anything: checked on a Mac plugged in and fully charged,
        // where reporting it would say the battery has no time left. Time
        // remaining is only an answer while the Mac is running on the battery.
        let onBattery = source == .battery
        let minutesRemaining = onBattery && (rawToEmpty ?? -1) >= 0 ? rawToEmpty : nil
        let minutesToFull = isCharging && (rawToFull ?? -1) >= 0 ? rawToFull : nil

        return PowerSummary(
            hasBattery: true,
            source: source,
            percentRemaining: percent,
            isCharging: isCharging,
            isFullyCharged: description[Key.isCharged] as? Bool ?? false,
            minutesRemaining: minutesRemaining,
            minutesToFullCharge: minutesToFull,
            timeEstimateIsCalculating: (onBattery || isCharging)
                && (relevantEstimate ?? -1) <= 0,
            condition: description[Key.condition] as? String
        )
    }

    /// IOKit hands these back as `Int`, `Double` or `NSNumber` depending on
    /// the machine, so every read goes through one coercion.
    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    /// A one-line description for a caller that wants to say it out loud.
    public func summaryLine() -> String {
        guard hasBattery else { return "This Mac has no battery; it runs on mains power." }
        let percentText = percentRemaining.map { "\($0)%" } ?? "an unknown charge"
        if isFullyCharged { return "Fully charged at \(percentText), on mains power." }
        if isCharging {
            if let minutes = minutesToFullCharge {
                return "Charging: \(percentText), about \(minutes) minutes to full."
            }
            return "Charging: \(percentText), time to full still being estimated."
        }
        if let minutes = minutesRemaining {
            return "On battery: \(percentText), about \(minutes) minutes left."
        }
        return "On battery: \(percentText), time remaining still being estimated."
    }
}
