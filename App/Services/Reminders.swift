import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("reminders")

// Known coverage exclusions (verified 2026-07-21 on macOS 27.0 beta):
//
// - Subtasks: EventKit does not expose reminder subtasks through public API.
//   `EKReminder` has no public `parent`/`subTasks` members (confirmed by
//   compiling probes against the current SDK; both fail with "has no member").
//   The hierarchy is private to Reminders.app / private ReminderKit framework,
//   and BUILD_PLAN §3.3's claim of native support in macOS 14.4 does not hold
//   against the shipping SDK. Reminders' AppleScript dictionary offers no
//   route either: `sdef /System/Applications/Reminders.app` defines only a
//   `show` command and read-only `container` properties. Subtasks are
//   therefore excluded rather than hacked in.
//
// - Cross-account moves: EventKit rejects moving a reminder between accounts
//   (error -3002). BUILD_PLAN §3.3 sketched an AppleScript fallback, but the
//   same sdef inspection shows Reminders' scripting dictionary has no `move`,
//   `make`, or `delete` commands and `container` is read-only, so no clean
//   scripted move (or delete-and-recreate) exists. The typed error below is
//   kept instead of a fallback.

final class RemindersService: Service {
    private let eventStore = EKEventStore()

    static let shared = RemindersService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    func activate() async throws {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            let statusAfterRequest = EKEventStore.authorizationStatus(for: .reminder)
            throw ServicePermissionError.requestFailed(
                domain: "RemindersError",
                what: "Reminders",
                promptCouldHaveAppeared: statusAfterRequest != .notDetermined
            )
        }
    }

    /// Resolves a reminder by its calendar item identifier.
    private func resolveReminder(withIdentifier id: String) throws -> EKReminder {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No reminder found with identifier \(id)"]
            )
        }
        return reminder
    }

    /// Rejects writes to reminder lists that cannot be modified.
    private func requireWritable(_ list: EKCalendar) throws {
        guard list.allowsContentModifications, !list.isSubscribed else {
            throw NSError(
                domain: "RemindersReadOnlyError",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Reminder list \"\(list.title)\" is read-only and cannot be modified"
                ]
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description: "List available reminder lists",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map { reminderList in
                Value.object([
                    "identifier": .string(reminderList.calendarIdentifier),
                    "title": .string(reminderList.title),
                    "source": .string(reminderList.source.title),
                    "color": .string(reminderList.color.accessibilityName),
                    "isEditable": .bool(reminderList.allowsContentModifications),
                    "isSubscribed": .bool(reminderList.isSubscribed),
                ])
            }
        }

        Tool(
            name: "reminders_sections",
            description:
                "List the sections a Reminders list is divided into. Sections are not part of EventKit, so "
                + "this reads the Reminders database directly and is unavailable if that cannot be read.",
            inputSchema: .object(
                properties: [
                    "list": .string(
                        description: "Restrict to one list by name. Omit for sections across every list."
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Sections",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            guard let storePath = RemindersStoreReader.locateStore() else {
                throw RemindersStoreError.storeNotFound
            }
            let listName = arguments["list"]?.stringValue
            let sections = try RemindersStoreReader(path: storePath).sections(listName: listName)

            let described: [Value] = sections.map { section in
                var entry: [String: Value] = ["name": .string(section.name)]
                if let list = section.listName { entry["list"] = .string(list) }
                if let identifier = section.identifier { entry["identifier"] = .string(identifier) }
                return .object(entry)
            }
            return Value.object([
                "count": .int(described.count),
                "sections": .array(described),
            ])
        }

        Tool(
            name: "reminders_fetch",
            description: "Get reminders from the reminders app with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "completed": .boolean(
                        description:
                            "If true, fetch completed reminders; if false, fetch incomplete; if omitted, fetch all"
                    ),
                    "start": .string(
                        description:
                            "Start date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "lists": .array(
                        description:
                            "Names of reminder lists to fetch from; if empty, fetches from all lists",
                        items: .string()
                    ),
                    "query": .string(
                        description: "Text to search for in reminder titles"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            // Filter reminder lists based on provided names
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case .array(let listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() }
                )
                reminderLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
            }

            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil
            var startIsDateOnly = false
            var endIsDateOnly = false

            if let startValue = arguments["start"] {
                guard case .string(let start) = startValue else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Start must be an ISO 8601 string."]
                    )
                }
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: start
                    )
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Start must be a valid ISO 8601 date or date-time."]
                    )
                }
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }
            if let endValue = arguments["end"] {
                guard case .string(let end) = endValue else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "End must be an ISO 8601 string."]
                    )
                }
                guard
                    let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: end
                    )
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "End must be a valid ISO 8601 date or date-time."]
                    )
                }
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            let calendar = Calendar.current
            if let startDateValue = startDate {
                startDate = calendar.normalizedStartDate(
                    from: startDateValue,
                    isDateOnly: startIsDateOnly
                )
            }
            if let endDateValue = endDate {
                endDate = calendar.normalizedEndDate(from: endDateValue, isDateOnly: endIsDateOnly)
            }
            if let startDate, let endDate, startDate > endDate {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
                )
            }

            // Create predicates based on completion status. EventKit has no
            // single all-status date predicate, so a bounded request without a
            // status must query completed and incomplete reminders separately.
            let predicates: [NSPredicate]
            if case .bool(let completed) = arguments["completed"] {
                if completed {
                    predicates = [
                        self.eventStore.predicateForCompletedReminders(
                            withCompletionDateStarting: startDate,
                            ending: endDate,
                            calendars: reminderLists
                        )
                    ]
                } else {
                    predicates = [
                        self.eventStore.predicateForIncompleteReminders(
                            withDueDateStarting: startDate,
                            ending: endDate,
                            calendars: reminderLists
                        )
                    ]
                }
            } else if startDate != nil || endDate != nil {
                predicates = [
                    self.eventStore.predicateForCompletedReminders(
                        withCompletionDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    ),
                    self.eventStore.predicateForIncompleteReminders(
                        withDueDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    ),
                ]
            } else {
                predicates = [self.eventStore.predicateForReminders(in: reminderLists)]
            }

            var reminders: [EKReminder] = []
            for predicate in predicates {
                let fetched: [EKReminder] = await withCheckedContinuation { continuation in
                    self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                        continuation.resume(returning: fetchedReminders ?? [])
                    }
                }
                reminders.append(contentsOf: fetched)
            }
            var seenIdentifiers = Set<String>()
            reminders = reminders.filter { seenIdentifiers.insert($0.calendarItemIdentifier).inserted }

            // Apply additional filters
            var filteredReminders = reminders

            // Filter by search text if provided
            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            // Expose the EventKit identifier so callers can feed it back to
            // reminders_update / reminders_delete / reminders_complete, which
            // resolve by calendarItemIdentifier.
            return filteredReminders.map { reminder in
                var action = PlanAction(reminder)
                action.identifier = reminder.calendarItemIdentifier
                return action
            }
        }

        Tool(
            name: "reminders_create",
            description: "Create a new reminder with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "due": .string(
                        description:
                            "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Reminder list name (uses default if not specified)"
                    ),
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
                    ),
                    "recurrence": RecurrenceRuleParser.recurrenceSchema,
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }
            reminder.title = title

            // Set calendar (list). An unmatched name throws rather than
            // silently filing the reminder into the default list.
            guard let defaultList = self.eventStore.defaultCalendarForNewReminders() else {
                throw NSError(
                    domain: "RemindersError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No default reminder list is available"]
                )
            }
            var calendar = defaultList
            if case .string(let listName) = arguments["list"] {
                guard
                    let matchingCalendar = self.eventStore.calendars(for: .reminder)
                        .first(where: { $0.title.lowercased() == listName.lowercased() })
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No reminder list found with name \(listName)"
                        ]
                    )
                }
                calendar = matchingCalendar
            }
            try self.requireWritable(calendar)
            reminder.calendar = calendar

            // Set optional properties
            if let dueValue = arguments["due"] {
                guard case .string(let dueDateStr) = dueValue else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Due must be an ISO 8601 string."]
                    )
                }
                guard
                    let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: dueDateStr
                    )
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Due must be a valid ISO 8601 date or date-time."]
                    )
                }
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Set alarms
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: -TimeInterval(minutes) * 60)
                }
            }

            // Set recurrence (EKReminder shares EKRecurrenceRule with EKEvent)
            if let recurrenceValue = arguments["recurrence"] {
                switch try RecurrenceRuleParser.parse(argument: recurrenceValue) {
                case .clear:
                    reminder.recurrenceRules = nil
                case .rule(let rule):
                    guard reminder.dueDateComponents != nil else {
                        throw NSError(
                            domain: "RemindersError",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "A recurring reminder requires a due date"
                            ]
                        )
                    }
                    reminder.recurrenceRules = [rule]
                }
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_update",
            description:
                "Update an existing reminder's title, notes, due date, priority, list, alarms, or recurrence (recurrence \"none\" clears the rule)",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Reminder identifier (from reminders_fetch)"
                    ),
                    "title": .string(),
                    "notes": .string(),
                    "due": .string(
                        description:
                            "New due date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight. Pass an empty string to clear the due date.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description:
                            "Name of the reminder list to move the reminder to (must be in the same account as the current list)"
                    ),
                    "priority": .string(
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description:
                            "Minutes before due date to set alarms; replaces any existing alarms",
                        items: .integer()
                    ),
                    "recurrence": RecurrenceRuleParser.recurrenceSchema,
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder id is required"]
                )
            }

            let reminder = try self.resolveReminder(withIdentifier: id)
            try self.requireWritable(reminder.calendar)

            if case .string(let title) = arguments["title"] {
                reminder.title = title
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if let dueValue = arguments["due"] {
                guard case .string(let dueDateStr) = dueValue else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Due must be an ISO 8601 string."]
                    )
                }
                if dueDateStr.isEmpty {
                    reminder.dueDateComponents = nil
                } else {
                    guard
                        let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                            fromISO8601String: dueDateStr
                        )
                    else {
                        throw NSError(
                            domain: "RemindersError",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid due date format. Expected ISO 8601 format."
                            ]
                        )
                    }
                    let calendar = Calendar.current
                    let dueDate = calendar.normalizedStartDate(
                        from: parsedDueDate.date,
                        isDateOnly: parsedDueDate.isDateOnly
                    )
                    reminder.dueDateComponents = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: dueDate
                    )
                }
            }

            if case .string(let listName) = arguments["list"] {
                guard
                    let targetList = self.eventStore.calendars(for: .reminder)
                        .first(where: { $0.title.lowercased() == listName.lowercased() })
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No reminder list found with name \(listName)"
                        ]
                    )
                }
                try self.requireWritable(targetList)

                // EventKit cannot move reminders between accounts (error -3002),
                // e.g. from an iCloud list to an "On My Mac" list. No AppleScript
                // fallback exists either; see the header comment on this file.
                guard
                    targetList.source.sourceIdentifier
                        == reminder.calendar.source.sourceIdentifier
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Cannot move reminder to \"\(listName)\": the list is in a different account, and EventKit does not support cross-account moves"
                        ]
                    )
                }
                reminder.calendar = targetList
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: -TimeInterval(minutes) * 60)
                }
            }

            // Set recurrence (EKReminder shares EKRecurrenceRule with EKEvent)
            if let recurrenceValue = arguments["recurrence"] {
                switch try RecurrenceRuleParser.parse(argument: recurrenceValue) {
                case .clear:
                    reminder.recurrenceRules = nil
                case .rule(let rule):
                    guard reminder.dueDateComponents != nil else {
                        throw NSError(
                            domain: "RemindersError",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "A recurring reminder requires a due date"
                            ]
                        )
                    }
                    reminder.recurrenceRules = [rule]
                }
            }

            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_complete",
            description: "Mark a reminder as completed, or as incomplete again",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Reminder identifier (from reminders_fetch)"
                    ),
                    "completed": .boolean(
                        description:
                            "Whether the reminder should be marked completed (true) or incomplete (false)",
                        default: true
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Complete Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder id is required"]
                )
            }

            let reminder = try self.resolveReminder(withIdentifier: id)
            try self.requireWritable(reminder.calendar)

            var completed = true
            if case .bool(let completedArg) = arguments["completed"] {
                completed = completedArg
            }
            reminder.isCompleted = completed

            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_delete",
            description: "Delete a reminder permanently",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Reminder identifier (from reminders_fetch)"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder id is required"]
                )
            }

            let reminder = try self.resolveReminder(withIdentifier: id)
            try self.requireWritable(reminder.calendar)

            try self.eventStore.remove(reminder, commit: true)

            return Value.object(["deleted": .bool(true)])
        }
    }
}
