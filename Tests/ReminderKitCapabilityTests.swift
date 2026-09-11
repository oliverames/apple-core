import Foundation
import Testing

/// The gate that decides whether the private ReminderKit path may run, and the
/// translation that keeps its identifiers apart from EventKit's. Both are pure
/// functions over plain inputs, so all of this runs against fixtures and never
/// loads the framework or touches the Reminders store.
@Suite("ReminderKit capability gate")
struct ReminderKitCapabilityTests {
    private static func probe(
        os: Int = 27,
        loaded: Bool = true,
        classes: Set<String> = ReminderKitGate.requiredClasses
    ) -> ReminderKitProbe {
        ReminderKitProbe(osMajorVersion: os, frameworkLoaded: loaded, resolvedClasses: classes)
    }

    @Test("A verified macOS with every class present supports reads and writes")
    func verifiedOSSupportsEverything() {
        let capability = ReminderKitGate.evaluate(Self.probe(os: 27))
        #expect(capability.supports(.hierarchyRead))
        #expect(capability.supports(.hierarchyWrite))
        #expect(capability.isUnverifiedOS == false)
        #expect(capability.refusal(for: .hierarchyWrite) == nil)
    }

    @Test("An OS older than anything verified refuses both operations")
    func tooOldRefusesEverything() {
        let capability = ReminderKitGate.evaluate(Self.probe(os: 25))
        #expect(capability.supported.isEmpty)
        #expect(capability.supports(.hierarchyRead) == false)
        let refusal = capability.refusal(for: .hierarchyRead)
        #expect(refusal?.reason == .osTooOld(found: 25, minimum: 26))
    }

    @Test("A framework that will not load refuses rather than reporting nothing found")
    func frameworkMissingRefuses() {
        let capability = ReminderKitGate.evaluate(Self.probe(loaded: false, classes: []))
        #expect(capability.supported.isEmpty)
        #expect(capability.refusal(for: .hierarchyRead)?.reason == .frameworkMissing)
    }

    /// A renamed private class is indistinguishable from a removed one from
    /// outside, and both must read as unavailable rather than as "no subtasks".
    @Test("A missing class refuses and names what was missing")
    func missingClassRefusesAndNames() {
        var classes = ReminderKitGate.requiredClasses
        classes.remove("REMSaveRequest")
        let capability = ReminderKitGate.evaluate(Self.probe(classes: classes))
        #expect(capability.supported.isEmpty)
        #expect(
            capability.refusal(for: .hierarchyWrite)?.reason
                == .symbolsMissing(missing: ["REMSaveRequest"])
        )
        let message = capability.refusal(for: .hierarchyWrite)?.errorDescription ?? ""
        #expect(message.contains("REMSaveRequest"))
    }

    /// The deliberate asymmetry: a misread on an unverified OS is wrong, a
    /// miswrite corrupts a syncing database, so they do not get the same gate.
    @Test("An OS past the verified ceiling reads but refuses to write")
    func unverifiedOSReadsButDoesNotWrite() {
        let capability = ReminderKitGate.evaluate(Self.probe(os: 28))
        #expect(capability.supports(.hierarchyRead))
        #expect(capability.supports(.hierarchyWrite) == false)
        #expect(capability.isUnverifiedOS)
        #expect(
            capability.refusal(for: .hierarchyWrite)?.reason
                == .unverifiedOSForWrite(found: 28, verifiedThrough: 27)
        )
    }

    @Test("Every refusal explains itself in terms a client can act on")
    func refusalsAreExplained() {
        let cases: [ReminderKitProbe] = [
            Self.probe(os: 25),
            Self.probe(loaded: false, classes: []),
            Self.probe(classes: []),
            Self.probe(os: 99),
        ]
        for probe in cases {
            let capability = ReminderKitGate.evaluate(probe)
            for operation in ReminderKitOperation.allCases where !capability.supports(operation) {
                let message = capability.refusal(for: operation)?.errorDescription ?? ""
                #expect(message.isEmpty == false)
                #expect(message.contains("hierarchy") || message.contains("macOS"))
            }
        }
    }

    @Test("Only the write operation is classified as a write")
    func writeClassification() {
        #expect(ReminderKitOperation.hierarchyWrite.isWrite)
        #expect(ReminderKitOperation.hierarchyRead.isWrite == false)
    }
}

@Suite("Reminder identifier translation")
struct ReminderIdentifierTranslationTests {
    private static let sample = "688DF940-7393-4B25-B11D-43A15CA09BF0"

    /// Measured 2026-09-11 across 154 reminders on macOS 27.0: every EventKit
    /// `calendarItemIdentifier` equalled the ReminderKit object's UUID string.
    /// The translation is still explicit, because that agreement is
    /// undocumented and could stop holding.
    @Test("An EventKit identifier round-trips through the ReminderKit form")
    func roundTrips() throws {
        let eventKit = EventKitItemIdentifier(Self.sample)
        let reminderKit = try ReminderIdentifierTranslator.reminderKitIdentifier(for: eventKit)
        #expect(reminderKit.uuidString == Self.sample)
        #expect(ReminderIdentifierTranslator.eventKitIdentifier(for: reminderKit) == eventKit)
    }

    @Test("A lowercase identifier normalises to the canonical form")
    func normalisesCase() throws {
        let lower = EventKitItemIdentifier(Self.sample.lowercased())
        let reminderKit = try ReminderIdentifierTranslator.reminderKitIdentifier(for: lower)
        #expect(reminderKit.uuidString == Self.sample)
    }

    @Test("Surrounding whitespace from a client's JSON is tolerated")
    func trimsWhitespace() throws {
        let padded = EventKitItemIdentifier("  \(Self.sample)\n")
        let reminderKit = try ReminderIdentifierTranslator.reminderKitIdentifier(for: padded)
        #expect(reminderKit.uuidString == Self.sample)
    }

    /// The leak this guards against: a non-UUID identifier reaching a private
    /// write path, where it would address the wrong reminder or nothing.
    @Test("A non-UUID identifier is refused rather than passed through")
    func refusesNonUUID() {
        let bogus = EventKitItemIdentifier("not-an-identifier")
        #expect(throws: ReminderIdentifierTranslationError.notAUUID("not-an-identifier")) {
            try ReminderIdentifierTranslator.reminderKitIdentifier(for: bogus)
        }
    }

    @Test("An empty identifier is refused")
    func refusesEmpty() {
        #expect(throws: ReminderIdentifierTranslationError.empty) {
            try ReminderIdentifierTranslator.reminderKitIdentifier(
                for: EventKitItemIdentifier("   ")
            )
        }
    }

    @Test("A refusal explains itself without blaming the whole surface")
    func refusalExplains() {
        let message = ReminderIdentifierTranslationError.notAUUID("abc").errorDescription ?? ""
        #expect(message.contains("abc"))
        #expect(message.contains("still work"))
    }

    @Test("Hierarchy reports only ever carry EventKit identifiers")
    func hierarchyCarriesEventKitIdentifiers() {
        let parent = EventKitItemIdentifier(Self.sample)
        let hierarchy = ReminderHierarchy(
            identifier: EventKitItemIdentifier("A" + Self.sample.dropFirst()),
            parent: parent,
            subtasks: []
        )
        #expect(hierarchy.isSubtask)
        #expect(hierarchy.parent == parent)

        let orphan = ReminderHierarchy(
            identifier: parent,
            parent: nil,
            subtasks: [parent]
        )
        #expect(orphan.isSubtask == false)
        #expect(orphan.subtasks.count == 1)
    }
}

@Suite("Reminder reparent validation")
struct ReminderReparentValidatorTests {
    private static let a = EventKitItemIdentifier("11111111-1111-1111-1111-111111111111")
    private static let b = EventKitItemIdentifier("22222222-2222-2222-2222-222222222222")
    private static let c = EventKitItemIdentifier("33333333-3333-3333-3333-333333333333")

    @Test("An unrelated parent is accepted")
    func acceptsUnrelated() throws {
        try ReminderReparentValidator.validate(
            child: Self.a,
            newParent: Self.b,
            ancestorsOfNewParent: [Self.c]
        )
    }

    @Test("A reminder cannot be its own subtask")
    func rejectsSelfParent() {
        #expect(throws: ReminderReparentValidator.Rejection.selfParent(Self.a)) {
            try ReminderReparentValidator.validate(
                child: Self.a,
                newParent: Self.a,
                ancestorsOfNewParent: []
            )
        }
    }

    /// Without this the pair would end up in a loop that Reminders.app cannot
    /// draw, and neither reminder would be reachable from its list.
    @Test("A reparent that would form a loop is rejected before any write")
    func rejectsCycle() {
        #expect(
            throws: ReminderReparentValidator.Rejection.cycle(child: Self.a, parent: Self.b)
        ) {
            try ReminderReparentValidator.validate(
                child: Self.a,
                newParent: Self.b,
                ancestorsOfNewParent: [Self.c, Self.a]
            )
        }
    }

    @Test("Rejections name both reminders so a client can report which")
    func rejectionsNameBoth() {
        let message =
            ReminderReparentValidator.Rejection
            .cycle(child: Self.a, parent: Self.b).errorDescription ?? ""
        #expect(message.contains(Self.a.rawValue))
        #expect(message.contains(Self.b.rawValue))
    }
}
