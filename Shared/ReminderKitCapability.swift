// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether the private ReminderKit path may be used on this Mac, and for what.
//
// EventKit cannot express reminder hierarchy: `EKReminder` has no public
// `parent` or `subTasks`, and Reminders' AppleScript dictionary offers no
// route (verified 2026-07-21, restated 2026-09-11 against macOS 27.0). The
// hierarchy lives in the private ReminderKit framework, whose use Oliver
// authorized on 2026-09-11.
//
// A private framework can change shape or vanish in any macOS release, so
// nothing here assumes it is present. The gate below takes plain facts that
// the caller establishes at runtime -- the OS version, whether the framework
// loaded, which classes actually resolved -- and returns a decision plus a
// reason a client can read. It performs no lookups of its own, which is what
// makes it testable without a live store.
//
// The deliberate conservatism: above the verified macOS ceiling reads are
// still allowed but writes are refused. A read that misreports a changed
// private schema is wrong; a write that misreports one corrupts a syncing
// database. Those are not the same risk, so they do not get the same gate.

import Foundation

/// An operation that only the private path can perform.
public enum ReminderKitOperation: String, Sendable, CaseIterable, Codable {
    /// Reading a reminder's parent and its subtasks.
    case hierarchyRead
    /// Reparenting a reminder, or detaching it from its parent.
    case hierarchyWrite

    /// Whether the operation changes the store.
    public var isWrite: Bool {
        switch self {
        case .hierarchyRead: return false
        case .hierarchyWrite: return true
        }
    }

    public var describedName: String {
        switch self {
        case .hierarchyRead: return "reading reminder hierarchy"
        case .hierarchyWrite: return "changing reminder hierarchy"
        }
    }
}

/// Why the private path is not usable, in terms a client can act on.
public enum ReminderKitUnavailableReason: Sendable, Equatable, Codable {
    /// The OS predates the oldest release this path was ever verified against.
    case osTooOld(found: Int, minimum: Int)
    /// The framework is not on disk, or would not load.
    case frameworkMissing
    /// The framework loaded but expected classes did not resolve, which is
    /// what a renamed or removed private API looks like from outside.
    case symbolsMissing(missing: [String])
    /// The OS is newer than anything this path was verified against, and the
    /// operation asked for is a write.
    case unverifiedOSForWrite(found: Int, verifiedThrough: Int)

    public var explanation: String {
        switch self {
        case let .osTooOld(found, minimum):
            return
                "This Mac runs macOS \(found), and reminder hierarchy needs macOS \(minimum) or later."
        case .frameworkMissing:
            return
                "The private framework that stores reminder hierarchy is not available on this Mac."
        case let .symbolsMissing(missing):
            let list = missing.sorted().joined(separator: ", ")
            return
                "This version of macOS structures reminder hierarchy differently than expected "
                + "(\(list) could not be found), so it cannot be read or changed safely."
        case let .unverifiedOSForWrite(found, verifiedThrough):
            return
                "Reminder hierarchy can be read on this Mac but not changed: macOS \(found) is newer "
                + "than macOS \(verifiedThrough), the most recent release this was verified against, "
                + "and an unverified write to the Reminders database is not worth the risk."
        }
    }
}

/// Refusal to perform an operation the private path cannot support.
public struct ReminderKitUnavailableError: LocalizedError, Equatable {
    public let operation: ReminderKitOperation
    public let reason: ReminderKitUnavailableReason

    public init(operation: ReminderKitOperation, reason: ReminderKitUnavailableReason) {
        self.operation = operation
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(operation.describedName.capitalizedFirst) is unavailable. \(reason.explanation)"
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

/// What the caller established about this Mac before asking the gate anything.
public struct ReminderKitProbe: Sendable, Equatable {
    /// Major version of the running macOS, e.g. 27.
    public let osMajorVersion: Int
    /// Whether the framework binary loaded.
    public let frameworkLoaded: Bool
    /// Names of the classes that actually resolved after loading.
    public let resolvedClasses: Set<String>

    public init(osMajorVersion: Int, frameworkLoaded: Bool, resolvedClasses: Set<String>) {
        self.osMajorVersion = osMajorVersion
        self.frameworkLoaded = frameworkLoaded
        self.resolvedClasses = resolvedClasses
    }
}

/// The decision, and everything a client needs to read it.
public struct ReminderKitCapability: Sendable, Equatable, Codable {
    /// Operations that will actually run on this Mac.
    public let supported: [ReminderKitOperation]
    /// Operations that will not, each with its reason.
    public let unsupported: [ReminderKitOperation: ReminderKitUnavailableReason]
    /// True when the OS is newer than the verified ceiling. Reads still work;
    /// the flag exists so a client can say so rather than implying assurance.
    public let isUnverifiedOS: Bool

    public func supports(_ operation: ReminderKitOperation) -> Bool {
        supported.contains(operation)
    }

    /// The refusal for an operation, or nil when it is supported.
    public func refusal(for operation: ReminderKitOperation) -> ReminderKitUnavailableError? {
        guard let reason = unsupported[operation] else { return nil }
        return ReminderKitUnavailableError(operation: operation, reason: reason)
    }

    private enum CodingKeys: String, CodingKey {
        case supported, unsupported, isUnverifiedOS
    }

    public init(
        supported: [ReminderKitOperation],
        unsupported: [ReminderKitOperation: ReminderKitUnavailableReason],
        isUnverifiedOS: Bool
    ) {
        self.supported = supported
        self.unsupported = unsupported
        self.isUnverifiedOS = isUnverifiedOS
    }
}

/// Decides what the private path may do, from plain facts and nothing else.
public enum ReminderKitGate {
    /// Oldest macOS this path was ever exercised against.
    public static let minimumOSMajorVersion = 26
    /// Newest macOS this path was verified against, 2026-09-11.
    public static let verifiedThroughOSMajorVersion = 27

    /// Classes every supported operation needs before anything is attempted.
    public static let requiredClasses: Set<String> = [
        "REMStore",
        "REMObjectID",
        "REMReminder",
        "REMSaveRequest",
        "REMReminderSubtaskContextChangeItem",
    ]

    public static func evaluate(_ probe: ReminderKitProbe) -> ReminderKitCapability {
        func refuseEverything(_ reason: ReminderKitUnavailableReason) -> ReminderKitCapability {
            var unsupported: [ReminderKitOperation: ReminderKitUnavailableReason] = [:]
            for operation in ReminderKitOperation.allCases { unsupported[operation] = reason }
            return ReminderKitCapability(
                supported: [],
                unsupported: unsupported,
                isUnverifiedOS: false
            )
        }

        guard probe.osMajorVersion >= minimumOSMajorVersion else {
            return refuseEverything(
                .osTooOld(found: probe.osMajorVersion, minimum: minimumOSMajorVersion)
            )
        }
        guard probe.frameworkLoaded else {
            return refuseEverything(.frameworkMissing)
        }
        let missing = requiredClasses.subtracting(probe.resolvedClasses)
        guard missing.isEmpty else {
            return refuseEverything(.symbolsMissing(missing: missing.sorted()))
        }

        let unverified = probe.osMajorVersion > verifiedThroughOSMajorVersion
        guard unverified else {
            return ReminderKitCapability(
                supported: ReminderKitOperation.allCases,
                unsupported: [:],
                isUnverifiedOS: false
            )
        }

        // Newer than anything verified: reads proceed, writes do not.
        let reason = ReminderKitUnavailableReason.unverifiedOSForWrite(
            found: probe.osMajorVersion,
            verifiedThrough: verifiedThroughOSMajorVersion
        )
        var unsupported: [ReminderKitOperation: ReminderKitUnavailableReason] = [:]
        var supported: [ReminderKitOperation] = []
        for operation in ReminderKitOperation.allCases {
            if operation.isWrite {
                unsupported[operation] = reason
            } else {
                supported.append(operation)
            }
        }
        return ReminderKitCapability(
            supported: supported,
            unsupported: unsupported,
            isUnverifiedOS: true
        )
    }
}
