// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keeping EventKit identifiers and ReminderKit identifiers apart.
//
// The two paths name the same reminder differently. EventKit hands out a
// `calendarItemIdentifier` string; ReminderKit addresses reminders by a
// `REMObjectID` built from an `NSUUID`. On macOS 27.0 those happen to carry
// the same UUID -- measured 2026-09-11 across 154 reminders, where every
// EventKit identifier equalled the matching ReminderKit object's UUID string.
//
// That agreement is a convenience, not a contract. It is undocumented, it is
// a private framework's business, and it could stop holding in any release.
// So this file never passes a raw string between the two worlds. Each side
// gets its own type, translation is an explicit call that can fail, and a
// string that is not a well-formed UUID is refused rather than handed to
// ReminderKit to interpret. A wrong identifier reaching a private write path
// is how the wrong reminder gets reparented.

import Foundation

/// A reminder as EventKit names it.
public struct EventKitItemIdentifier: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// A reminder as ReminderKit names it: the UUID behind a `REMObjectID`.
public struct ReminderKitObjectIdentifier: Sendable, Hashable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// The canonical uppercase form both Apple frameworks emit.
    public var uuidString: String { uuid.uuidString }

    public var description: String { uuidString }
}

/// Why an identifier could not be carried across.
public enum ReminderIdentifierTranslationError: LocalizedError, Equatable {
    /// The EventKit identifier is not a UUID, so there is no safe reading of
    /// it as a ReminderKit object ID.
    case notAUUID(String)
    /// The identifier was empty.
    case empty

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "No reminder identifier was given."
        case let .notAUUID(value):
            return
                "The reminder identifier \"\(value)\" is not in the form reminder hierarchy needs, so "
                + "hierarchy cannot be read or changed for it. The other Reminders tools still work."
        }
    }
}

/// Translates between the two, and refuses rather than guessing.
public enum ReminderIdentifierTranslator {
    /// EventKit identifier to ReminderKit object identifier.
    ///
    /// Accepts either case and surrounding whitespace, since identifiers reach
    /// us through JSON written by clients, and normalises to the canonical
    /// form. Anything that is not a UUID is refused.
    public static func reminderKitIdentifier(
        for eventKitIdentifier: EventKitItemIdentifier
    ) throws -> ReminderKitObjectIdentifier {
        let trimmed = eventKitIdentifier.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReminderIdentifierTranslationError.empty }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw ReminderIdentifierTranslationError.notAUUID(eventKitIdentifier.rawValue)
        }
        return ReminderKitObjectIdentifier(uuid)
    }

    /// ReminderKit object identifier back to the EventKit identifier that
    /// names the same reminder.
    public static func eventKitIdentifier(
        for reminderKitIdentifier: ReminderKitObjectIdentifier
    ) -> EventKitItemIdentifier {
        EventKitItemIdentifier(reminderKitIdentifier.uuidString)
    }
}

/// A reminder's place in the hierarchy, as reported back to a client.
///
/// Identifiers here are always EventKit identifiers, because that is the only
/// kind the rest of the surface accepts. Translating on the way out is what
/// keeps a ReminderKit UUID from reaching a tool that would feed it to
/// EventKit.
public struct ReminderHierarchy: Sendable, Equatable {
    public let identifier: EventKitItemIdentifier
    public let parent: EventKitItemIdentifier?
    public let subtasks: [EventKitItemIdentifier]

    public init(
        identifier: EventKitItemIdentifier,
        parent: EventKitItemIdentifier?,
        subtasks: [EventKitItemIdentifier]
    ) {
        self.identifier = identifier
        self.parent = parent
        self.subtasks = subtasks
    }

    public var isSubtask: Bool { parent != nil }
}

/// Checks a reparent is coherent before any private write is attempted.
///
/// Reminders' own model forbids a reminder being its own parent, and a cycle
/// would strand both reminders somewhere Reminders.app cannot draw. Catching
/// that here, on plain identifiers, means the private path is only ever
/// reached by a request already known to be well formed.
public enum ReminderReparentValidator {
    public enum Rejection: LocalizedError, Equatable {
        case selfParent(EventKitItemIdentifier)
        case cycle(child: EventKitItemIdentifier, parent: EventKitItemIdentifier)

        public var errorDescription: String? {
            switch self {
            case let .selfParent(id):
                return "A reminder cannot be its own subtask (\(id.rawValue))."
            case let .cycle(child, parent):
                return
                    "Making \(child.rawValue) a subtask of \(parent.rawValue) would form a loop, "
                    + "because \(parent.rawValue) is already somewhere beneath it."
            }
        }
    }

    /// - Parameter ancestors: the prospective parent's own chain of parents,
    ///   nearest first, as EventKit identifiers.
    public static func validate(
        child: EventKitItemIdentifier,
        newParent: EventKitItemIdentifier,
        ancestorsOfNewParent ancestors: [EventKitItemIdentifier]
    ) throws {
        guard child != newParent else { throw Rejection.selfParent(child) }
        guard !ancestors.contains(child) else {
            throw Rejection.cycle(child: child, parent: newParent)
        }
    }
}
