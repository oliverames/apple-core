import Foundation
import Testing

/// The decisions the Reminders tools make before they touch EventKit: which
/// list a name refers to, which alarms an edit is allowed to replace, what a
/// page of results contains. All of it runs against fixtures, never the live
/// Reminders store.
@Suite("Reminders tool logic")
struct RemindersToolLogicTests {
    private static let lists = [
        ReminderListCandidate(
            identifier: "icloud-work",
            title: "Work",
            sourceIdentifier: "src-icloud",
            sourceTitle: "iCloud"
        ),
        ReminderListCandidate(
            identifier: "local-work",
            title: "work",
            sourceIdentifier: "src-local",
            sourceTitle: "On My Mac"
        ),
        ReminderListCandidate(
            identifier: "icloud-groceries",
            title: "Groceries",
            sourceIdentifier: "src-icloud",
            sourceTitle: "iCloud"
        ),
        ReminderListCandidate(
            identifier: "shared-team",
            title: "Team",
            sourceIdentifier: "src-icloud",
            sourceTitle: "iCloud",
            isEditable: false,
            isSubscribed: true
        ),
    ]

    // MARK: - List targeting

    @Test("An exact identifier wins over any name matching")
    func identifierTargetsExactly() throws {
        let list = try ReminderListTarget.resolve(
            identifier: "local-work",
            name: "Groceries",
            source: "iCloud",
            in: Self.lists
        )
        #expect(list.identifier == "local-work")
    }

    @Test("An unknown identifier is reported rather than falling back to the name")
    func unknownIdentifierThrows() {
        #expect(throws: ReminderListError.unknownIdentifier("nope")) {
            try ReminderListTarget.resolve(
                identifier: "nope",
                name: "Groceries",
                source: nil,
                in: Self.lists
            )
        }
    }

    @Test("A name that exists in two accounts is refused, not guessed")
    func duplicateNameAcrossAccountsIsAmbiguous() {
        do {
            _ = try ReminderListTarget.resolve(
                identifier: nil,
                name: "Work",
                source: nil,
                in: Self.lists
            )
            Issue.record("Expected an ambiguity error")
        } catch let error as ReminderListError {
            guard case let .ambiguousName(name, candidates) = error else {
                Issue.record("Expected ambiguousName, got \(error)")
                return
            }
            #expect(name == "Work")
            #expect(candidates.count == 2)
            // The message has to carry the identifiers, or the caller cannot
            // act on it.
            #expect(candidates.contains { $0.contains("icloud-work") })
            #expect(candidates.contains { $0.contains("local-work") })
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("An account narrows an otherwise ambiguous name, by title or identifier")
    func sourceDisambiguates() throws {
        let byTitle = try ReminderListTarget.resolve(
            identifier: nil,
            name: "work",
            source: "On My Mac",
            in: Self.lists
        )
        #expect(byTitle.identifier == "local-work")

        let bySourceIdentifier = try ReminderListTarget.resolve(
            identifier: nil,
            name: "WORK",
            source: "src-icloud",
            in: Self.lists
        )
        #expect(bySourceIdentifier.identifier == "icloud-work")
    }

    @Test("A name in the wrong account is a miss, not a match elsewhere")
    func nameMissingFromNamedSource() {
        #expect(throws: ReminderListError.unknownName(name: "Groceries", source: "On My Mac")) {
            try ReminderListTarget.resolve(
                identifier: nil,
                name: "Groceries",
                source: "On My Mac",
                in: Self.lists
            )
        }
    }

    @Test("Naming no list at all is its own error")
    func noTargetThrows() {
        #expect(throws: ReminderListError.noTarget) {
            try ReminderListTarget.resolve(identifier: "", name: "", source: nil, in: Self.lists)
        }
    }

    @Test("Subscribed and non-editable lists are rejected for writes")
    func readOnlyListsRejected() throws {
        let subscribed = try ReminderListTarget.resolve(
            identifier: "shared-team",
            name: nil,
            source: nil,
            in: Self.lists
        )
        #expect(throws: ReminderListError.readOnly("Team")) {
            try ReminderListTarget.requireWritable(subscribed)
        }
        try ReminderListTarget.requireWritable(Self.lists[0])
    }

    @Test("A duplicate name inside one account is refused, across accounts allowed")
    func nameCollisionIsPerAccount() throws {
        #expect(
            throws: ReminderListError.duplicateName(name: "groceries", source: "iCloud")
        ) {
            try ReminderListTarget.requireNameIsFree(
                "groceries",
                inSource: "src-icloud",
                sourceTitle: "iCloud",
                among: Self.lists
            )
        }
        // The same name in a different account is exactly the case the
        // ambiguity error above exists to handle, so it stays legal.
        try ReminderListTarget.requireNameIsFree(
            "Groceries",
            inSource: "src-local",
            sourceTitle: "On My Mac",
            among: Self.lists
        )
        // Renaming a list to its own name is not a collision with itself.
        try ReminderListTarget.requireNameIsFree(
            "Groceries",
            inSource: "src-icloud",
            sourceTitle: "iCloud",
            among: Self.lists,
            ignoring: "icloud-groceries"
        )
    }

    @Test("Deleting a nonempty list needs explicit confirmation")
    func nonemptyListDeletionIsRefusedByDefault() throws {
        let list = Self.lists[2]
        #expect(throws: ReminderListError.notEmpty(name: "Groceries", count: 7)) {
            try ReminderListTarget.checkDeletable(
                list,
                reminderCount: 7,
                deletesContainedReminders: false
            )
        }
        // The refusal has to say what would be lost.
        let message = ReminderListError.notEmpty(name: "Groceries", count: 7).errorDescription ?? ""
        #expect(message.contains("7 reminders"))
        #expect(message.contains("delete_reminders"))

        try ReminderListTarget.checkDeletable(
            list,
            reminderCount: 0,
            deletesContainedReminders: false
        )
        try ReminderListTarget.checkDeletable(
            list,
            reminderCount: 7,
            deletesContainedReminders: true
        )
    }

    @Test("A read-only list is refused before its contents are even counted")
    func readOnlyListCannotBeDeleted() {
        #expect(throws: ReminderListError.readOnly("Team")) {
            try ReminderListTarget.checkDeletable(
                Self.lists[3],
                reminderCount: 0,
                deletesContainedReminders: true
            )
        }
    }

    // MARK: - Account targeting

    @Test("Accounts resolve by identifier or title, and duplicates are refused")
    func sourceResolution() throws {
        let sources = [
            ReminderSourceCandidate(identifier: "src-icloud", title: "iCloud"),
            ReminderSourceCandidate(identifier: "src-local", title: "On My Mac"),
            ReminderSourceCandidate(identifier: "src-other", title: "iCloud"),
        ]
        #expect(try ReminderSourceTarget.resolve("src-other", in: sources).identifier == "src-other")
        #expect(try ReminderSourceTarget.resolve("on my mac", in: sources).identifier == "src-local")

        #expect(throws: (any Error).self) {
            try ReminderSourceTarget.resolve("iCloud", in: sources)
        }
        #expect(throws: (any Error).self) {
            try ReminderSourceTarget.resolve("Exchange", in: sources)
        }
    }

    // MARK: - Alarms

    private struct FakeAlarm: Equatable {
        let name: String
        let kind: ReminderAlarmClass?
    }

    @Test("Replacing one alarm class leaves the other classes in place")
    func alarmClassesArePreserved() {
        let existing = [
            FakeAlarm(name: "10 minutes before", kind: .relative),
            FakeAlarm(name: "Monday 9am", kind: .absolute),
            FakeAlarm(name: "arriving home", kind: .location),
            FakeAlarm(name: "something new in a future macOS", kind: nil),
        ]
        let replaced = ReminderAlarms.replacing(
            .absolute,
            in: existing,
            with: [FakeAlarm(name: "Tuesday 8am", kind: .absolute)],
            classify: \.kind
        )

        #expect(
            replaced.map(\.name) == [
                "10 minutes before", "arriving home", "something new in a future macOS", "Tuesday 8am",
            ]
        )
    }

    @Test("Replacing a class with nothing clears only that class")
    func clearingOneClassKeepsTheRest() {
        let existing = [
            FakeAlarm(name: "relative", kind: .relative),
            FakeAlarm(name: "geofence", kind: .location),
        ]
        let cleared = ReminderAlarms.replacing(
            .location,
            in: existing,
            with: [],
            classify: \.kind
        )
        #expect(cleared == [FakeAlarm(name: "relative", kind: .relative)])
    }

    @Test("Location alarms validate their coordinates, radius and proximity")
    func locationAlarmValidation() throws {
        let alarm = try ReminderLocationAlarm.validated(
            name: "  Home  ",
            latitude: 44.4759,
            longitude: -73.2121,
            radiusMeters: 150,
            proximity: "Leaving"
        )
        #expect(alarm.name == "Home")
        #expect(alarm.proximity == .leaving)

        #expect(throws: ReminderLocationError.missingName) {
            try ReminderLocationAlarm.validated(
                name: "   ",
                latitude: 0,
                longitude: 0,
                radiusMeters: 100,
                proximity: "arriving"
            )
        }
        #expect(throws: ReminderLocationError.invalidLatitude(91)) {
            try ReminderLocationAlarm.validated(
                name: "Home",
                latitude: 91,
                longitude: 0,
                radiusMeters: 100,
                proximity: "arriving"
            )
        }
        #expect(throws: ReminderLocationError.invalidLongitude(-181)) {
            try ReminderLocationAlarm.validated(
                name: "Home",
                latitude: 0,
                longitude: -181,
                radiusMeters: 100,
                proximity: "arriving"
            )
        }
        #expect(throws: ReminderLocationError.invalidRadius(0)) {
            try ReminderLocationAlarm.validated(
                name: "Home",
                latitude: 0,
                longitude: 0,
                radiusMeters: 0,
                proximity: "arriving"
            )
        }
        #expect(throws: ReminderLocationError.unknownProximity("nearby")) {
            try ReminderLocationAlarm.validated(
                name: "Home",
                latitude: 0,
                longitude: 0,
                radiusMeters: 100,
                proximity: "nearby"
            )
        }
        // A missing coordinate arrives as NaN rather than as a number.
        #expect(throws: (any Error).self) {
            try ReminderLocationAlarm.validated(
                name: "Home",
                latitude: .nan,
                longitude: 0,
                radiusMeters: 100,
                proximity: "arriving"
            )
        }
    }

    // MARK: - URL field

    @Test("Reminder URLs must be absolute and openable")
    func urlValidation() throws {
        #expect(
            try ReminderURLField.parse("https://example.com/a?b=c")?.absoluteString
                == "https://example.com/a?b=c"
        )
        #expect(try ReminderURLField.parse("  https://example.com  ")?.host == "example.com")
        // App deep links are as legitimate as web links here.
        #expect(try ReminderURLField.parse("things:///show?id=abc")?.scheme == "things")
        // An empty string clears the field rather than failing.
        #expect(try ReminderURLField.parse("") == nil)
        #expect(try ReminderURLField.parse("   ") == nil)

        #expect(throws: ReminderURLError.notAbsolute("example.com")) {
            try ReminderURLField.parse("example.com")
        }
        #expect(throws: ReminderURLError.unsupportedScheme("javascript")) {
            try ReminderURLField.parse("javascript:alert(1)")
        }
        #expect(throws: ReminderURLError.unsupportedScheme("data")) {
            try ReminderURLField.parse("data:text/html,<b>hi</b>")
        }
        #expect(throws: (any Error).self) {
            try ReminderURLField.parse("https://")
        }
    }

    // MARK: - Search

    @Test("Search reaches notes and URLs, not only titles")
    func searchScopes() {
        let fields = ReminderSearchFields(
            title: "Renew passport",
            notes: "Appointment at the Burlington office",
            url: "https://travel.state.gov/renewal"
        )

        #expect(ReminderTextSearch.matches("burlington", in: fields, scope: .all))
        #expect(ReminderTextSearch.matches("burlington", in: fields, scope: .notes))
        #expect(!ReminderTextSearch.matches("burlington", in: fields, scope: .title))
        #expect(ReminderTextSearch.matches("state.gov", in: fields, scope: .url))
        #expect(!ReminderTextSearch.matches("state.gov", in: fields, scope: .notes))
        #expect(ReminderTextSearch.matches("PASSPORT", in: fields, scope: .title))
        #expect(!ReminderTextSearch.matches("visa", in: fields, scope: .all))
        // An empty query is not a filter.
        #expect(ReminderTextSearch.matches("   ", in: fields, scope: .all))
    }

    @Test("A reminder with no notes or URL still searches by title")
    func searchToleratesMissingFields() {
        let bare = ReminderSearchFields(title: "Call the vet")
        #expect(ReminderTextSearch.matches("vet", in: bare, scope: .all))
        #expect(!ReminderTextSearch.matches("vet", in: bare, scope: .notes))
    }

    // MARK: - Priority and completion filters

    @Test("Apple's 1-9 priority scale maps onto the named bands")
    func priorityBuckets() {
        #expect(ReminderPriorityBucket.bucket(forRawValue: 0) == .none)
        #expect(ReminderPriorityBucket.bucket(forRawValue: 1) == .high)
        #expect(ReminderPriorityBucket.bucket(forRawValue: 4) == .high)
        #expect(ReminderPriorityBucket.bucket(forRawValue: 5) == .medium)
        #expect(ReminderPriorityBucket.bucket(forRawValue: 6) == .low)
        #expect(ReminderPriorityBucket.bucket(forRawValue: 9) == .low)
        // Out-of-range values are "unset", not a crash and not a band.
        #expect(ReminderPriorityBucket.bucket(forRawValue: 42) == .none)
        #expect(ReminderPriorityBucket.bucket(forRawValue: -1) == .none)
    }

    @Test("A completion range excludes reminders that were never completed")
    func completionRangeBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)

        #expect(ReminderCompletionRange.matches(completionDate: nil, start: nil, end: nil))
        #expect(!ReminderCompletionRange.matches(completionDate: nil, start: start, end: nil))
        // Both bounds are inclusive: a reminder completed exactly at the edge
        // of a review window belongs to that window.
        #expect(ReminderCompletionRange.matches(completionDate: start, start: start, end: end))
        #expect(ReminderCompletionRange.matches(completionDate: end, start: start, end: end))
        #expect(
            !ReminderCompletionRange.matches(
                completionDate: start.addingTimeInterval(-1),
                start: start,
                end: end
            )
        )
        #expect(
            !ReminderCompletionRange.matches(
                completionDate: end.addingTimeInterval(1),
                start: start,
                end: end
            )
        )
    }

    // MARK: - Pagination

    private struct Row: Equatable {
        let identifier: String
        let title: String
        let due: Date?
    }

    private static func key(_ row: Row) -> ReminderOrderingKey {
        ReminderOrderingKey(dueDate: row.due, title: row.title, identifier: row.identifier)
    }

    @Test("Ordering puts dated reminders first and breaks every tie")
    func stableOrdering() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let rows = [
            Row(identifier: "e", title: "same", due: nil),
            Row(identifier: "c", title: "same", due: nil),
            Row(identifier: "d", title: "Same", due: nil),
            Row(identifier: "b", title: "Later", due: late),
            Row(identifier: "a", title: "Earlier", due: early),
        ]

        // Dated first in date order; then undated by title, with case
        // deciding between titles that differ only in case, and the
        // identifier deciding between titles that are identical.
        let ordered = ReminderPagination.stableSorted(rows, key: Self.key)
        #expect(ordered.map(\.identifier) == ["a", "b", "d", "c", "e"])

        // Same input in a different arrival order gives the same output, which
        // is what makes page 2 line up with page 1.
        let shuffled = ReminderPagination.stableSorted(rows.reversed(), key: Self.key)
        #expect(shuffled.map(\.identifier) == ordered.map(\.identifier))
    }

    @Test("Pages tile the result exactly once, with no gap or overlap")
    func pagesTileTheResult() {
        let rows = (0 ..< 25).map {
            Row(identifier: String(format: "id-%02d", $0), title: "Item \($0)", due: nil)
        }
        let ordered = ReminderPagination.stableSorted(rows, key: Self.key)

        var seen: [String] = []
        var offset = 0
        while true {
            let page = ReminderPagination.page(ordered, offset: offset, limit: 10)
            #expect(page.total == 25)
            seen.append(contentsOf: page.items.map(\.identifier))
            guard let next = page.nextOffset else {
                #expect(!page.hasMore)
                break
            }
            #expect(page.hasMore)
            offset = next
        }
        #expect(seen == ordered.map(\.identifier))
        #expect(Set(seen).count == 25)
    }

    @Test("Boundary offsets and limits stay in range")
    func paginationBoundaries() {
        let rows = (0 ..< 3).map { Row(identifier: "\($0)", title: "t", due: nil) }

        let last = ReminderPagination.page(rows, offset: 2, limit: 10)
        #expect(last.items.count == 1)
        #expect(!last.hasMore)
        #expect(last.nextOffset == nil)

        let past = ReminderPagination.page(rows, offset: 3, limit: 10)
        #expect(past.items.isEmpty)
        #expect(past.total == 3)
        #expect(past.nextOffset == nil)

        let wayPast = ReminderPagination.page(rows, offset: Int.max, limit: 10)
        #expect(wayPast.items.isEmpty)

        // A limit near Int.max must not overflow into a negative range.
        let huge = ReminderPagination.page(rows, offset: 1, limit: Int.max)
        #expect(huge.items.count == 2)
        #expect(!huge.hasMore)

        let empty = ReminderPagination.page([Row](), offset: 0, limit: 10)
        #expect(empty.items.isEmpty)
        #expect(empty.total == 0)
        #expect(!empty.hasMore)
    }

    @Test("Requested limits and offsets are clamped to a usable range")
    func clamping() {
        #expect(ReminderPagination.clampedLimit(nil) == ReminderPagination.defaultLimit)
        #expect(ReminderPagination.clampedLimit(0) == 1)
        #expect(ReminderPagination.clampedLimit(-5) == 1)
        #expect(ReminderPagination.clampedLimit(10) == 10)
        #expect(ReminderPagination.clampedLimit(Int.max) == ReminderPagination.maximumLimit)
        #expect(ReminderPagination.clampedOffset(nil) == 0)
        #expect(ReminderPagination.clampedOffset(-3) == 0)
        #expect(ReminderPagination.clampedOffset(12) == 12)
    }
}
