import CoreLocation
import EventKit
import Foundation
import JSONSchema
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
//   therefore absent from this file, which uses public EventKit only.
//
//   Oliver authorized private API use on 2026-09-11, so this is no longer
//   a policy exclusion: issue #40 tracks reaching the hierarchy through
//   ReminderKit. The finding above still stands and is exactly why that
//   work needs a private framework. Keep this file on public EventKit and
//   put the private path behind its own version gate when #40 lands.
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

    /// EventKit lists flattened for `ReminderListTarget`, which does the
    /// choosing. Keeping the decision off `EKCalendar` is what lets duplicate
    /// names and read-only lists be tested without a Reminders database.
    private func listCandidates() -> [ReminderListCandidate] {
        eventStore.calendars(for: .reminder).map { list in
            ReminderListCandidate(
                identifier: list.calendarIdentifier,
                title: list.title,
                sourceIdentifier: list.source.sourceIdentifier,
                sourceTitle: list.source.title,
                isEditable: list.allowsContentModifications,
                isSubscribed: list.isSubscribed
            )
        }
    }

    /// Accounts a new list can be created in. A source that already holds
    /// reminder lists obviously qualifies; local and CalDAV accounts qualify
    /// even when empty, which is how a fresh account looks.
    private func reminderSources() -> [EKSource] {
        eventStore.sources.filter { source in
            !source.calendars(for: .reminder).isEmpty
                || source.sourceType == .local
                || source.sourceType == .calDAV
        }
    }

    private func sourceCandidates() -> [ReminderSourceCandidate] {
        reminderSources().map {
            ReminderSourceCandidate(identifier: $0.sourceIdentifier, title: $0.title)
        }
    }

    /// Resolves the list named by `list_id` / `list` (+ optional `list_source`)
    /// to the live calendar. Returns nil when the caller named none.
    private func resolveList(from arguments: [String: Value]) throws -> EKCalendar? {
        let identifier = arguments["list_id"]?.stringValue
        let name = arguments["list"]?.stringValue
        guard identifier?.isEmpty == false || name?.isEmpty == false else { return nil }

        let candidate = try ReminderListTarget.resolve(
            identifier: identifier,
            name: name,
            source: arguments["list_source"]?.stringValue,
            in: listCandidates()
        )
        guard
            let list = eventStore.calendars(for: .reminder)
                .first(where: { $0.calendarIdentifier == candidate.identifier })
        else {
            throw ReminderListError.unknownIdentifier(candidate.identifier)
        }
        return list
    }

    private func reminderCount(in list: EKCalendar) async -> Int {
        let predicate = eventStore.predicateForReminders(in: [list])
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return reminders.count
    }

    private static func describe(_ list: EKCalendar) -> Value {
        .object([
            "identifier": .string(list.calendarIdentifier),
            "title": .string(list.title),
            "source": .string(list.source.title),
            "sourceIdentifier": .string(list.source.sourceIdentifier),
            "isEditable": .bool(list.allowsContentModifications),
            "isSubscribed": .bool(list.isSubscribed),
        ])
    }

    /// EventKit keeps every kind of alarm in one array, so an edit has to know
    /// which kind it is looking at before it replaces anything.
    private static func alarmClass(_ alarm: EKAlarm) -> ReminderAlarmClass? {
        if alarm.structuredLocation != nil, alarm.proximity != .none { return .location }
        if alarm.absoluteDate != nil { return .absolute }
        return .relative
    }

    private static func makeAlarm(_ location: ReminderLocationAlarm) -> EKAlarm {
        let place = EKStructuredLocation(title: location.name)
        place.geoLocation = CLLocation(
            latitude: location.latitude,
            longitude: location.longitude
        )
        place.radius = location.radiusMeters

        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = location.proximity == .arriving ? .enter : .leave
        return alarm
    }

    private static func describe(_ alarm: EKAlarm) -> Value {
        switch alarmClass(alarm) {
        case .location:
            var entry: [String: Value] = [
                "type": .string("location"),
                "proximity": .string(alarm.proximity == .enter ? "arriving" : "leaving"),
            ]
            if let place = alarm.structuredLocation {
                if let title = place.title { entry["name"] = .string(title) }
                if let coordinate = place.geoLocation?.coordinate {
                    entry["latitude"] = .double(coordinate.latitude)
                    entry["longitude"] = .double(coordinate.longitude)
                }
                if place.radius > 0 { entry["radiusMeters"] = .double(place.radius) }
            }
            return .object(entry)
        case .absolute:
            return .object([
                "type": .string("absolute"),
                "date": .string(ISO8601DateFormatter().string(from: alarm.absoluteDate ?? Date())),
            ])
        default:
            return .object([
                "type": .string("relative"),
                "minutesBefore": .int(Int((-alarm.relativeOffset / 60).rounded())),
            ])
        }
    }

    /// Applies the `url`, `alarms`, `alarm_dates` and `location_alarm`
    /// arguments shared by create and update. Each alarm argument replaces only
    /// its own class, so setting a due-date alarm no longer drops the
    /// geofence the user set in Reminders.app.
    private func applySharedFields(_ arguments: [String: Value], to reminder: EKReminder) throws {
        if case .string(let raw) = arguments["url"] {
            reminder.url = try ReminderURLField.parse(raw)
        }

        if case .array(let alarmMinutes) = arguments["alarms"] {
            let relative = alarmMinutes.compactMap { value -> EKAlarm? in
                guard let minutes = value.intValue else { return nil }
                return EKAlarm(relativeOffset: -TimeInterval(minutes) * 60)
            }
            reminder.alarms = ReminderAlarms.replacing(
                .relative,
                in: reminder.alarms ?? [],
                with: relative,
                classify: Self.alarmClass
            )
        }

        if case .array(let alarmDates) = arguments["alarm_dates"] {
            let absolute = try alarmDates.map { value -> EKAlarm in
                guard let raw = value.stringValue,
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: raw)
                else {
                    throw RemindersToolError.invalidArgument(
                        "alarm_dates",
                        "each entry must be an ISO 8601 date or date-time"
                    )
                }
                let date = Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
                return EKAlarm(absoluteDate: date)
            }
            reminder.alarms = ReminderAlarms.replacing(
                .absolute,
                in: reminder.alarms ?? [],
                with: absolute,
                classify: Self.alarmClass
            )
        }

        if let locationValue = arguments["location_alarm"] {
            let replacements: [EKAlarm]
            if let keyword = locationValue.stringValue {
                guard keyword.lowercased() == "none" else {
                    throw RemindersToolError.invalidArgument(
                        "location_alarm",
                        "the only string accepted is \"none\", which clears location alarms"
                    )
                }
                replacements = []
            } else if let fields = locationValue.objectValue {
                let location = try ReminderLocationAlarm.validated(
                    name: fields["name"]?.stringValue ?? "",
                    latitude: fields["latitude"]?.doubleValue ?? .nan,
                    longitude: fields["longitude"]?.doubleValue ?? .nan,
                    radiusMeters: fields["radius_meters"]?.doubleValue ?? 100,
                    proximity: fields["proximity"]?.stringValue ?? ReminderProximity.arriving.rawValue
                )
                replacements = [Self.makeAlarm(location)]
            } else {
                throw RemindersToolError.invalidArgument(
                    "location_alarm",
                    "expected an object or the string \"none\""
                )
            }
            reminder.alarms = ReminderAlarms.replacing(
                .location,
                in: reminder.alarms ?? [],
                with: replacements,
                classify: Self.alarmClass
            )
        }
    }

    private static var locationAlarmSchema: JSONSchema {
        .anyOf([
            .string(
                description:
                    "\"none\" removes the reminder's location alarms and leaves its other alarms in place."
            ),
            .object(
                description:
                    "A geofenced alarm. Replaces any existing location alarms; time-based alarms are untouched.",
                properties: [
                    "name": .string(description: "Place name shown on the reminder"),
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "radius_meters": .number(
                        description: "How close counts as arrived",
                        default: .double(100),
                        exclusiveMinimum: 0
                    ),
                    "proximity": .string(
                        description: "Fire on arrival or on departure",
                        default: .string(ReminderProximity.arriving.rawValue),
                        enum: ReminderProximity.allCases.map { .string($0.rawValue) }
                    ),
                ],
                required: ["name", "latitude", "longitude"],
                additionalProperties: false
            ),
        ])
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
                        description:
                            "Text to search for. Searches titles, notes and URLs unless search_scope narrows it."
                    ),
                    "search_scope": .string(
                        description: "Which fields query searches",
                        default: .string(ReminderSearchScope.all.rawValue),
                        enum: ReminderSearchScope.allCases.map { .string($0.rawValue) }
                    ),
                    "priority": .string(
                        description: "Return only reminders in this priority band",
                        enum: ReminderPriorityBucket.allCases.map { .string($0.rawValue) }
                    ),
                    "completed_start": .string(
                        description:
                            "Earliest completion date to include. Excludes reminders that were never completed.",
                        format: .dateTime
                    ),
                    "completed_end": .string(
                        description: "Latest completion date to include. Excludes reminders that were never completed.",
                        format: .dateTime
                    ),
                    "offset": .integer(
                        description: "How many reminders to skip, for paging through a long list",
                        default: .int(0),
                        minimum: 0
                    ),
                    "limit": .integer(
                        description: "Maximum reminders to return in one page",
                        default: .int(ReminderPagination.defaultLimit),
                        minimum: 1,
                        maximum: ReminderPagination.maximumLimit
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

            if case .string(let searchText) = arguments["query"], !searchText.isEmpty {
                let rawScope =
                    arguments["search_scope"]?.stringValue
                    ?? ReminderSearchScope.all.rawValue
                guard let scope = ReminderSearchScope(rawValue: rawScope.lowercased()) else {
                    throw RemindersToolError.invalidArgument(
                        "search_scope",
                        "expected one of \(ReminderSearchScope.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                filteredReminders = filteredReminders.filter { reminder in
                    ReminderTextSearch.matches(
                        searchText,
                        in: ReminderSearchFields(
                            title: reminder.title,
                            notes: reminder.notes,
                            url: reminder.url?.absoluteString
                        ),
                        scope: scope
                    )
                }
            }

            if case .string(let rawPriority) = arguments["priority"] {
                guard let bucket = ReminderPriorityBucket(rawValue: rawPriority.lowercased()) else {
                    throw RemindersToolError.invalidArgument(
                        "priority",
                        "expected one of \(ReminderPriorityBucket.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                filteredReminders = filteredReminders.filter {
                    ReminderPriorityBucket.bucket(forRawValue: $0.priority) == bucket
                }
            }

            let completedStart = try Self.parseOptionalDate(arguments["completed_start"], named: "completed_start")
            let completedEnd = try Self.parseOptionalDate(arguments["completed_end"], named: "completed_end")
            if completedStart != nil || completedEnd != nil {
                filteredReminders = filteredReminders.filter {
                    ReminderCompletionRange.matches(
                        completionDate: $0.completionDate,
                        start: completedStart,
                        end: completedEnd
                    )
                }
            }

            // EventKit returns reminders in no documented order, so page 2
            // could otherwise repeat or skip what page 1 already showed.
            let ordered = ReminderPagination.stableSorted(filteredReminders) { reminder in
                ReminderOrderingKey(
                    dueDate: reminder.dueDateComponents?.date,
                    title: reminder.title ?? "",
                    identifier: reminder.calendarItemIdentifier
                )
            }
            let page = ReminderPagination.page(
                ordered,
                offset: ReminderPagination.clampedOffset(arguments["offset"]?.intValue),
                limit: ReminderPagination.clampedLimit(arguments["limit"]?.intValue)
            )

            // Expose the EventKit identifier so callers can feed it back to
            // reminders_get / reminders_update / reminders_delete /
            // reminders_complete, which resolve by calendarItemIdentifier.
            return RemindersPage(
                total: page.total,
                offset: page.offset,
                limit: page.limit,
                hasMore: page.hasMore,
                nextOffset: page.nextOffset,
                reminders: page.items.map { reminder in
                    var action = PlanAction(reminder)
                    action.identifier = reminder.calendarItemIdentifier
                    return action
                }
            )
        }

        Tool(
            name: "reminders_get",
            description:
                "Get one reminder by its exact identifier, with its list, alarms, URL and completion date",
            inputSchema: .object(
                properties: [
                    "id": .string(description: "Reminder identifier (from reminders_fetch)")
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Reminder",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
                throw RemindersToolError.missingArgument("id")
            }
            let reminder = try self.resolveReminder(withIdentifier: id)

            var detail: [String: Value] = [
                "identifier": .string(reminder.calendarItemIdentifier),
                "title": .string(reminder.title ?? ""),
                "isCompleted": .bool(reminder.isCompleted),
                "priority": .string(
                    ReminderPriorityBucket.bucket(forRawValue: reminder.priority).rawValue
                ),
                "priorityValue": .int(reminder.priority),
                "list": Self.describe(reminder.calendar),
                "alarms": .array((reminder.alarms ?? []).map(Self.describe)),
            ]
            if let notes = reminder.notes { detail["notes"] = .string(notes) }
            if let url = reminder.url { detail["url"] = .string(url.absoluteString) }
            let formatter = ISO8601DateFormatter()
            if let due = reminder.dueDateComponents?.date {
                detail["due"] = .string(formatter.string(from: due))
            }
            if let completed = reminder.completionDate {
                detail["completionDate"] = .string(formatter.string(from: completed))
            }
            if let rules = reminder.recurrenceRules, !rules.isEmpty {
                detail["isRecurring"] = .bool(true)
            }
            return Value.object(detail)
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
                        description:
                            "Reminder list name (uses default if not specified). A name that exists in more than one account is rejected; pass list_id or list_source instead."
                    ),
                    "list_id": .string(
                        description: "Reminder list identifier (from reminders_lists). Takes precedence over list."
                    ),
                    "list_source": .string(
                        description: "Account name or source identifier, to disambiguate a list name"
                    ),
                    "notes": .string(),
                    "url": .string(
                        description: "URL to store in the reminder's own URL field",
                        format: .uri
                    ),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
                    ),
                    "alarm_dates": .array(
                        description: "Absolute alarm times, independent of the due date",
                        items: .string(format: .dateTime)
                    ),
                    "location_alarm": Self.locationAlarmSchema,
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

            // Set calendar (list). An unmatched or ambiguous name throws rather
            // than silently filing the reminder into the default list.
            guard
                let calendar = try self.resolveList(from: arguments)
                    ?? self.eventStore.defaultCalendarForNewReminders()
            else {
                throw RemindersToolError.noDefaultList
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

            // URL and alarms, by the same rules update uses.
            try self.applySharedFields(arguments, to: reminder)

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
                    "url": .string(
                        description:
                            "URL for the reminder's own URL field. Pass an empty string to clear it.",
                        format: .uri
                    ),
                    "list": .string(
                        description:
                            "Name of the reminder list to move the reminder to (must be in the same account as the current list)"
                    ),
                    "list_id": .string(
                        description:
                            "Identifier of the list to move the reminder to. Takes precedence over list."
                    ),
                    "list_source": .string(
                        description: "Account name or source identifier, to disambiguate a list name"
                    ),
                    "priority": .string(
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description:
                            "Minutes before due date to set alarms; replaces existing relative alarms and leaves absolute and location alarms alone",
                        items: .integer()
                    ),
                    "alarm_dates": .array(
                        description:
                            "Absolute alarm times; replaces existing absolute alarms and leaves relative and location alarms alone",
                        items: .string(format: .dateTime)
                    ),
                    "location_alarm": Self.locationAlarmSchema,
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

            if let targetList = try self.resolveList(from: arguments) {
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
                                "Cannot move reminder to \"\(targetList.title)\": the list is in a different account, and EventKit does not support cross-account moves"
                        ]
                    )
                }
                reminder.calendar = targetList
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            try self.applySharedFields(arguments, to: reminder)

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

        Tool(
            name: "reminders_create_list",
            description:
                "Create a reminder list in a named account. The account is required: which account a list lives in decides where it syncs.",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Name for the new list"),
                    "source": .string(
                        description:
                            "Account to create the list in, by name (\"iCloud\", \"On My Mac\") or source identifier"
                    ),
                ],
                required: ["name", "source"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder List",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard let name = arguments["name"]?.stringValue,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RemindersToolError.missingArgument("name")
            }
            guard let requestedSource = arguments["source"]?.stringValue, !requestedSource.isEmpty
            else {
                throw RemindersToolError.missingArgument("source")
            }

            let candidate = try ReminderSourceTarget.resolve(
                requestedSource,
                in: self.sourceCandidates()
            )
            guard
                let source = self.reminderSources()
                    .first(where: { $0.sourceIdentifier == candidate.identifier })
            else {
                throw ReminderSourceError.unknown(
                    requested: requestedSource,
                    available: self.sourceCandidates().map(\.title)
                )
            }
            try ReminderListTarget.requireNameIsFree(
                name,
                inSource: candidate.identifier,
                sourceTitle: candidate.title,
                among: self.listCandidates()
            )

            let list = EKCalendar(for: .reminder, eventStore: self.eventStore)
            list.title = name
            list.source = source
            try self.eventStore.saveCalendar(list, commit: true)

            return Self.describe(list)
        }

        Tool(
            name: "reminders_rename_list",
            description: "Rename a reminder list. The list stays in its current account.",
            inputSchema: .object(
                properties: [
                    "list_id": .string(
                        description: "List identifier (from reminders_lists). Takes precedence over list."
                    ),
                    "list": .string(
                        description:
                            "Current list name. Rejected when the name exists in more than one account; pass list_id or list_source."
                    ),
                    "list_source": .string(
                        description: "Account name or source identifier, to disambiguate a list name"
                    ),
                    "name": .string(description: "New name for the list"),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Rename Reminder List",
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard let name = arguments["name"]?.stringValue,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RemindersToolError.missingArgument("name")
            }
            guard let list = try self.resolveList(from: arguments) else {
                throw ReminderListError.noTarget
            }
            try self.requireWritable(list)
            try ReminderListTarget.requireNameIsFree(
                name,
                inSource: list.source.sourceIdentifier,
                sourceTitle: list.source.title,
                among: self.listCandidates(),
                ignoring: list.calendarIdentifier
            )

            let previousName = list.title
            list.title = name
            try self.eventStore.saveCalendar(list, commit: true)

            var described = Self.describe(list).objectValue ?? [:]
            described["previousTitle"] = .string(previousName)
            return Value.object(described)
        }

        Tool(
            name: "reminders_delete_list",
            description:
                "Delete a reminder list. Deleting a list deletes the reminders in it, so a list that still holds "
                + "reminders is refused unless delete_reminders is true.",
            inputSchema: .object(
                properties: [
                    "list_id": .string(
                        description: "List identifier (from reminders_lists). Takes precedence over list."
                    ),
                    "list": .string(
                        description:
                            "List name. Rejected when the name exists in more than one account; pass list_id or list_source."
                    ),
                    "list_source": .string(
                        description: "Account name or source identifier, to disambiguate a list name"
                    ),
                    "delete_reminders": .boolean(
                        description:
                            "Confirms that the reminders still in the list are deleted along with it",
                        default: .bool(false)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder List",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard let list = try self.resolveList(from: arguments) else {
                throw ReminderListError.noTarget
            }
            let candidate = ReminderListCandidate(
                identifier: list.calendarIdentifier,
                title: list.title,
                sourceIdentifier: list.source.sourceIdentifier,
                sourceTitle: list.source.title,
                isEditable: list.allowsContentModifications,
                isSubscribed: list.isSubscribed
            )
            let count = await self.reminderCount(in: list)
            try ReminderListTarget.checkDeletable(
                candidate,
                reminderCount: count,
                deletesContainedReminders: arguments["delete_reminders"]?.boolValue ?? false
            )

            try self.eventStore.removeCalendar(list, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "title": .string(candidate.title),
                "source": .string(candidate.sourceTitle),
                "remindersDeleted": .int(count),
            ])
        }
    }

    private static func parseOptionalDate(_ value: Value?, named name: String) throws -> Date? {
        guard let value else { return nil }
        guard let raw = value.stringValue else {
            throw RemindersToolError.invalidArgument(name, "must be an ISO 8601 string")
        }
        guard !raw.isEmpty else { return nil }
        guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: raw) else {
            throw RemindersToolError.invalidArgument(
                name,
                "must be a valid ISO 8601 date or date-time"
            )
        }
        return parsed.isDateOnly
            ? Calendar.current.normalizedStartDate(from: parsed.date, isDateOnly: true)
            : parsed.date
    }
}

/// One bounded page of reminders. Paging needs the totals alongside the items,
/// so fetch returns this rather than a bare array.
private struct RemindersPage: Encodable {
    let total: Int
    let offset: Int
    let limit: Int
    let hasMore: Bool
    let nextOffset: Int?
    let reminders: [PlanAction]
}

enum RemindersToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, String)
    case notFound(String)
    case noDefaultList

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .invalidArgument(name, detail):
            return "Invalid \(name): \(detail)"
        case let .notFound(id):
            return "No reminder found with identifier \(id)"
        case .noDefaultList:
            return "No default reminder list is available"
        }
    }
}
