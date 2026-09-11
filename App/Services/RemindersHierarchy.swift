// SPDX-License-Identifier: GPL-3.0-or-later
//
// The private ReminderKit path, used only for what EventKit cannot express.
//
// Everything else in the Reminders surface runs on public EventKit and stays
// there. This file exists for one thing EventKit has no vocabulary for:
// reminder hierarchy. `EKReminder` exposes no `parent` and no `subTasks`
// (verified 2026-07-21, restated 2026-09-11 against macOS 27.0), and the
// Reminders scripting dictionary offers no route either. Oliver authorized
// private API use on 2026-09-11; issue #40 is the work.
//
// Three deliberate choices, each in service of not breaking the app:
//
//  1. The framework is loaded with `dlopen` at first use, never linked at
//     build time. A link-time dependency on a private framework means the
//     whole app fails to launch the day Apple removes it. Here, it means one
//     surface reports itself unavailable and everything else carries on.
//
//  2. Every class and selector is resolved by name and checked. Missing
//     classes become a typed, explained refusal, not a crash.
//
//  3. Writes go through `REMSaveRequest`, which is how Reminders.app itself
//     saves. Nothing here opens the SQLite store, let alone writes to it.
//     `Shared/RemindersStoreReader.swift` reads that database and is likewise
//     read-only. A direct write to a live, syncing store risks corrupting it.
//
// Verified reachable on macOS 27.0 (build 26A428) on 2026-09-11: the framework
// loads, all five required classes resolve, `REMObjectID` round-trips through
// `objectIDWithUUID:`, and the full reparent change-item graph constructs.

import Foundation
import OSLog

private let log = Logger.service("reminders-hierarchy")

// MARK: - Private framework interfaces
//
// Declared as @objc protocols and bound with `unsafeBitCast` after the class
// has been resolved and checked. Swift maps the trailing `NSError **` of each
// selector below onto `throws`.

@objc private protocol REMObjectIDShim {
    var uuid: UUID { get }
}

@objc private protocol REMReminderShim {
    @objc(objectID) var objectID: AnyObject { get }
    @objc(parentReminder) var parentReminder: AnyObject? { get }
    @objc(subtaskContext) var subtaskContext: AnyObject? { get }
}

@objc private protocol REMSubtaskContextShim {
    @objc(fetchRemindersWithError:) func fetchReminders() throws -> [AnyObject]
}

@objc private protocol REMStoreShim {
    @objc(fetchReminderWithObjectID:error:) func fetchReminder(objectID: AnyObject) throws
        -> AnyObject
}

@objc private protocol REMSaveRequestShim {
    @objc(updateReminder:) func updateReminder(_ reminder: AnyObject) -> AnyObject
    @objc(saveSynchronouslyWithError:) func saveSynchronously() throws
}

@objc private protocol REMReminderChangeItemShim {
    @objc(removeFromParentReminder) func removeFromParentReminder()
}

@objc private protocol REMSubtaskContextChangeItemShim {
    @objc(addReminderChangeItem:) func addReminderChangeItem(_ item: AnyObject)
}

// MARK: - Framework loading

/// Loads ReminderKit once and reports what actually resolved.
private enum ReminderKitRuntime {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit"

    /// Resolved once per process. A private framework does not appear or
    /// disappear while the app runs, so re-probing would only add noise.
    static let probe: ReminderKitProbe = {
        let loaded = dlopen(frameworkPath, RTLD_LAZY) != nil
        var resolved: Set<String> = []
        if loaded {
            for name in ReminderKitGate.requiredClasses where NSClassFromString(name) != nil {
                resolved.insert(name)
            }
        } else {
            log.notice("ReminderKit did not load; reminder hierarchy is unavailable")
        }
        return ReminderKitProbe(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            frameworkLoaded: loaded,
            resolvedClasses: resolved
        )
    }()

    static let capability: ReminderKitCapability = ReminderKitGate.evaluate(probe)

    static func requireClass(_ name: String) throws -> AnyClass {
        guard let resolved = NSClassFromString(name) else {
            throw ReminderKitUnavailableError(
                operation: .hierarchyRead,
                reason: .symbolsMissing(missing: [name])
            )
        }
        return resolved
    }

    /// `alloc` then a one-argument `init...`, for the ReminderKit classes that
    /// have no zero-argument initialiser.
    ///
    /// Both halves go through `perform`, because Swift will not import a
    /// selector in the `init` family as an ordinary protocol method. `alloc`
    /// returns +1, so its result is taken retained and held by ARC for the
    /// rest of the call; the initialiser returns the same pointer, taken
    /// unretained, and is retained again as it is returned. Balanced, and it
    /// errs towards holding a reference rather than dropping one.
    static func makeInstance(
        ofClass className: String,
        initSelector: Selector,
        argument: AnyObject,
        for operation: ReminderKitOperation
    ) throws -> AnyObject {
        let resolved: AnyClass = try requireClass(className)
        guard
            let allocated = (resolved as AnyObject).perform(NSSelectorFromString("alloc"))?
                .takeRetainedValue(),
            let initialized = allocated.perform(initSelector, with: argument)?
                .takeUnretainedValue()
        else {
            throw ReminderKitUnavailableError(
                operation: operation,
                reason: .symbolsMissing(missing: ["\(className).\(initSelector)"])
            )
        }
        return initialized
    }
}

// MARK: - The bridge

/// Reads and changes reminder hierarchy through ReminderKit.
///
/// Created per operation rather than held: `REMStore` caches a view of the
/// database, and a long-lived one would serve stale parents after the user
/// edits in Reminders.app.
struct RemindersHierarchyBridge {
    /// What this Mac can actually do, for the capability tool and for gating.
    static var capability: ReminderKitCapability { ReminderKitRuntime.capability }

    private let store: REMStoreShim
    private let storeObject: AnyObject

    /// - Throws: `ReminderKitUnavailableError` when the private path is not
    ///   usable for `operation`, so callers get an explanation rather than a
    ///   silent no-op.
    init(for operation: ReminderKitOperation) throws {
        if let refusal = ReminderKitRuntime.capability.refusal(for: operation) {
            throw refusal
        }
        let storeClass: AnyClass = try ReminderKitRuntime.requireClass("REMStore")
        guard let instance = (storeClass as? NSObject.Type)?.init() else {
            throw ReminderKitUnavailableError(
                operation: operation,
                reason: .symbolsMissing(missing: ["REMStore"])
            )
        }
        storeObject = instance
        store = unsafeBitCast(instance, to: REMStoreShim.self)
    }

    // MARK: Identifier translation

    /// Builds a `REMObjectID` for a reminder from its EventKit identifier.
    ///
    /// The translation is explicit and validated in `ReminderIdentifierTranslator`;
    /// a non-UUID identifier is refused there rather than handed to the private
    /// framework to interpret.
    private func objectID(for identifier: EventKitItemIdentifier) throws -> AnyObject {
        let translated = try ReminderIdentifierTranslator.reminderKitIdentifier(for: identifier)
        let reminderClass: AnyClass = try ReminderKitRuntime.requireClass("REMReminder")
        guard
            let objectID = (reminderClass as AnyObject).perform(
                NSSelectorFromString("objectIDWithUUID:"),
                with: translated.uuid as NSUUID
            )?.takeUnretainedValue()
        else {
            throw ReminderKitUnavailableError(
                operation: .hierarchyRead,
                reason: .symbolsMissing(missing: ["REMReminder.objectIDWithUUID:"])
            )
        }
        return objectID
    }

    /// The EventKit identifier naming a ReminderKit reminder.
    ///
    /// Goes back through the translator so a bare UUID never escapes into the
    /// rest of the surface, where every identifier is an EventKit one.
    private func eventKitIdentifier(of reminder: AnyObject) -> EventKitItemIdentifier? {
        let shim = unsafeBitCast(reminder, to: REMReminderShim.self)
        let objectIDShim = unsafeBitCast(shim.objectID, to: REMObjectIDShim.self)
        return ReminderIdentifierTranslator.eventKitIdentifier(
            for: ReminderKitObjectIdentifier(objectIDShim.uuid)
        )
    }

    private func fetchReminder(_ identifier: EventKitItemIdentifier) throws -> AnyObject {
        let objectID = try objectID(for: identifier)
        do {
            return try store.fetchReminder(objectID: objectID)
        } catch {
            throw NSError(
                domain: "RemindersHierarchyError",
                code: 40,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No reminder found with identifier \(identifier.rawValue)"
                ]
            )
        }
    }

    // MARK: Reads

    /// A reminder's parent and its immediate subtasks.
    func hierarchy(of identifier: EventKitItemIdentifier) throws -> ReminderHierarchy {
        let reminder = try fetchReminder(identifier)
        let shim = unsafeBitCast(reminder, to: REMReminderShim.self)

        let parent = shim.parentReminder.flatMap { eventKitIdentifier(of: $0) }

        var subtasks: [EventKitItemIdentifier] = []
        if let context = shim.subtaskContext {
            let contextShim = unsafeBitCast(context, to: REMSubtaskContextShim.self)
            // A store that cannot enumerate subtasks reports none rather than
            // failing the whole read; the parent is still worth returning.
            let fetched = (try? contextShim.fetchReminders()) ?? []
            subtasks = fetched.compactMap { eventKitIdentifier(of: $0) }
        }

        return ReminderHierarchy(identifier: identifier, parent: parent, subtasks: subtasks)
    }

    /// The chain of parents above a reminder, nearest first.
    ///
    /// Used to reject a reparent that would form a loop before any write is
    /// attempted. The depth bound is a guard against a store that already
    /// contains a cycle, which would otherwise spin here.
    func ancestors(of identifier: EventKitItemIdentifier, limit: Int = 64) throws
        -> [EventKitItemIdentifier]
    {
        var chain: [EventKitItemIdentifier] = []
        var current = try fetchReminder(identifier)
        while chain.count < limit {
            guard let parent = unsafeBitCast(current, to: REMReminderShim.self).parentReminder,
                let parentID = eventKitIdentifier(of: parent)
            else { break }
            if chain.contains(parentID) { break }
            chain.append(parentID)
            current = parent
        }
        return chain
    }

    // MARK: Writes

    /// Makes `child` a subtask of `newParent`, or detaches it when `newParent`
    /// is nil.
    ///
    /// Saved through `REMSaveRequest`, the same path Reminders.app uses. The
    /// coherence checks run first, on plain identifiers, so the private write
    /// is only reached by a request already known to be well formed.
    func setParent(
        of child: EventKitItemIdentifier,
        to newParent: EventKitItemIdentifier?
    ) throws {
        if let refusal = ReminderKitRuntime.capability.refusal(for: .hierarchyWrite) {
            throw refusal
        }

        if let newParent {
            try ReminderReparentValidator.validate(
                child: child,
                newParent: newParent,
                ancestorsOfNewParent: try ancestors(of: newParent)
            )
        }

        let childReminder = try fetchReminder(child)
        let saveRequestObject = try ReminderKitRuntime.makeInstance(
            ofClass: "REMSaveRequest",
            initSelector: NSSelectorFromString("initWithStore:"),
            argument: storeObject,
            for: .hierarchyWrite
        )
        let saveRequest = unsafeBitCast(saveRequestObject, to: REMSaveRequestShim.self)
        let childChangeItem = saveRequest.updateReminder(childReminder)

        if let newParent {
            let parentReminder = try fetchReminder(newParent)
            let parentChangeItem = saveRequest.updateReminder(parentReminder)
            let contextObject = try ReminderKitRuntime.makeInstance(
                ofClass: "REMReminderSubtaskContextChangeItem",
                initSelector: NSSelectorFromString("initWithReminderChangeItem:"),
                argument: parentChangeItem,
                for: .hierarchyWrite
            )
            unsafeBitCast(contextObject, to: REMSubtaskContextChangeItemShim.self)
                .addReminderChangeItem(childChangeItem)
        } else {
            unsafeBitCast(childChangeItem, to: REMReminderChangeItemShim.self)
                .removeFromParentReminder()
        }

        try saveRequest.saveSynchronously()
        log.info("Saved reminder hierarchy change through ReminderKit")
    }
}
