import AppKit
import CoreLocation
import EventKit
import Foundation
import JSONSchema
import OSLog
import Ontology

private let log = Logger.service("calendar")

final class CalendarService: Service {
    private let eventStore = EKEventStore()

    static let shared = CalendarService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToEvents()
    }

    /// Resolves an event by identifier, optionally disambiguating a specific
    /// occurrence of a recurring event by its occurrence date.
    private func resolveEvent(withIdentifier id: String, occurrenceDate: Date?) throws -> EKEvent {
        if let occurrenceDate = occurrenceDate {
            // `event(withIdentifier:)` returns the first occurrence of a recurring
            // event, so search a window around the occurrence date instead and
            // match on the identifier.
            let windowStart = occurrenceDate.addingTimeInterval(-86400)
            let windowEnd = occurrenceDate.addingTimeInterval(2 * 86400)
            let predicate = eventStore.predicateForEvents(
                withStart: windowStart,
                end: windowEnd,
                calendars: nil
            )
            let occurrences = eventStore.events(matching: predicate)
                .filter { $0.eventIdentifier == id }
            guard
                let match = occurrences.min(by: {
                    abs($0.startDate.timeIntervalSince(occurrenceDate))
                        < abs($1.startDate.timeIntervalSince(occurrenceDate))
                })
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No occurrence of event \(id) found near the given occurrence date"
                    ]
                )
            }
            return match
        }

        guard let event = eventStore.event(withIdentifier: id) else {
            throw NSError(
                domain: "CalendarError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No event found with identifier \(id)"]
            )
        }
        return event
    }

    /// Rejects writes to calendars that cannot be modified (birthday calendars,
    /// subscribed calendars, and anything else EventKit marks immutable).
    private func requireWritable(_ calendar: EKCalendar) throws {
        guard calendar.allowsContentModifications, calendar.type != .birthday,
            calendar.type != .subscription, !calendar.isSubscribed
        else {
            throw NSError(
                domain: "CalendarReadOnlyError",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Calendar \"\(calendar.title)\" is read-only and cannot be modified"
                ]
            )
        }
    }

    /// Parses the shared alarm configuration schema into `EKAlarm`s, throwing
    /// on invalid configurations (including absolute alarms in the past, which
    /// macOS would otherwise reject silently).
    private func parseAlarms(_ alarmConfigs: [Value]) throws -> [EKAlarm] {
        var alarms: [EKAlarm] = []

        for alarmConfig in alarmConfigs {
            guard case .object(let config) = alarmConfig else { continue }

            var alarm: EKAlarm?

            let alarmType = config["type"]?.stringValue ?? "relative"
            switch alarmType {
            case "relative":
                if case .int(let minutes) = config["minutes"] {
                    alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }

            case "absolute":
                guard case .string(let datetimeStr) = config["datetime"],
                    !ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr),
                    let absoluteDate = ISO8601DateFormatter.lenientDate(
                        fromISO8601String: datetimeStr
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Absolute alarm datetime must be a valid ISO 8601 date/time with a time component"
                        ]
                    )
                }
                guard absoluteDate > Date() else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Absolute alarm date \(datetimeStr) is in the past; macOS rejects past alarms silently, so it was not set"
                        ]
                    )
                }
                alarm = EKAlarm(absoluteDate: absoluteDate)

            case "proximity":
                if case .string(let locationTitle) = config["locationTitle"],
                    case .double(let latitude) = config["latitude"],
                    case .double(let longitude) = config["longitude"]
                {
                    let proximityAlarm = EKAlarm()

                    let structuredLocation = EKStructuredLocation(title: locationTitle)
                    structuredLocation.geoLocation = CLLocation(
                        latitude: latitude,
                        longitude: longitude
                    )

                    if case .double(let radius) = config["radius"] {
                        structuredLocation.radius = radius
                    } else if case .int(let radiusInt) = config["radius"] {
                        structuredLocation.radius = Double(radiusInt)
                    }

                    let proximityType = config["proximity"]?.stringValue ?? "enter"
                    proximityAlarm.proximity = proximityType == "enter" ? .enter : .leave
                    proximityAlarm.structuredLocation = structuredLocation
                    alarm = proximityAlarm
                }

            default:
                log.error("Unexpected alarm type encountered: \(alarmType, privacy: .public)")
                continue
            }

            guard let alarm = alarm else { continue }

            if case .string(let soundName) = config["sound"],
                Sound(rawValue: soundName) != nil
            {
                alarm.soundName = soundName
            }

            if case .string(let email) = config["emailAddress"], !email.isEmpty {
                alarm.emailAddress = email
            }

            alarms.append(alarm)
        }

        return alarms
    }

    var tools: [Tool] {
        Tool(
            name: "calendars_list",
            description: "List available calendars",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Calendars",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let calendars = self.eventStore.calendars(for: .event)

            return calendars.map { calendar in
                Value.object([
                    "title": .string(calendar.title),
                    "source": .string(calendar.source.title),
                    "color": .string(calendar.color.accessibilityName),
                    "isEditable": .bool(calendar.allowsContentModifications),
                    "isSubscribed": .bool(calendar.isSubscribed),
                ])
            }
        }

        Tool(
            name: "events_fetch",
            description: "Get events from the calendar with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description:
                            "Start date/time (defaults to now; if end is date-only and start is omitted, uses end's local midnight). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time (defaults to one week from start; one day if start is date-only). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "calendars": .array(
                        description:
                            "Names of calendars to fetch from; if empty, fetches from all calendars",
                        items: .string(),
                    ),
                    "query": .string(
                        description: "Text to search for in event titles and locations"
                    ),
                    "includeAllDay": .boolean(
                        default: true
                    ),
                    "status": .string(
                        description: "Filter by event status",
                        enum: ["none", "tentative", "confirmed", "canceled"]
                    ),
                    "availability": .string(
                        description: "Filter by availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Events",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Filter calendars based on provided names
            var calendars = self.eventStore.calendars(for: .event)
            if case .array(let calendarNames) = arguments["calendars"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }

            // Parse dates and set defaults
            let now = Date()
            let calendar = Calendar.current
            var startDate = now
            var endDate = calendar.date(byAdding: .weekOfYear, value: 1, to: now)!
            var hasStart = false
            var hasEnd = false
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: start
                )
            {
                hasStart = true
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }

            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                hasEnd = true
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            if !hasStart, endIsDateOnly {
                startDate = endDate
                startIsDateOnly = true
            }

            startDate = calendar.normalizedStartDate(from: startDate, isDateOnly: startIsDateOnly)

            if endIsDateOnly {
                endDate = calendar.normalizedEndDate(from: endDate, isDateOnly: true)
            } else if !hasEnd {
                if startIsDateOnly {
                    endDate = calendar.normalizedEndDate(from: startDate, isDateOnly: true)
                } else if let nextWeek = calendar.date(
                    byAdding: .weekOfYear,
                    value: 1,
                    to: startDate
                ) {
                    endDate = nextWeek
                }
            }

            // Create base predicate for date range and calendars
            let predicate = self.eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )

            // Fetch events
            var events = self.eventStore.events(matching: predicate)

            // Apply additional filters
            if case .bool(let includeAllDay) = arguments["includeAllDay"],
                !includeAllDay
            {
                events = events.filter { !$0.isAllDay }
            }

            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if case .string(let status) = arguments["status"] {
                let statusValue = EKEventStatus(status)
                events = events.filter { $0.status == statusValue }
            }

            if case .string(let availability) = arguments["availability"] {
                let availabilityValue = EKEventAvailability(availability)
                events = events.filter { $0.availability == availabilityValue }
            }

            if case .bool(let hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case .bool(let isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            return events.map { Event($0) }
        }
        Tool(
            name: "events_create",
            description: "Create a new calendar event with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start": .string(
                        description:
                            "Start date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to use (uses default if not specified)"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(
                        default: false
                    ),
                    "availability": .string(
                        description: "Availability status",
                        default: .string(EKEventAvailability.busy.stringValue),
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Alarm configurations for the event",
                        items: .anyOf(
                            [
                                // Relative alarm (minutes before event)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "relative",
                                        ),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["minutes"],
                                    additionalProperties: false
                                ),
                                // Absolute alarm (specific date/time)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "absolute",
                                        ),
                                        "datetime": .string(
                                            description:
                                                "Alarm date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                                            format: .dateTime
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["datetime"],
                                    additionalProperties: false
                                ),
                                // Proximity alarm (location-based)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "proximity",
                                        ),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
                                        ),
                                        "locationTitle": .string(),
                                        "latitude": .number(),
                                        "longitude": .number(),
                                        "radius": .number(
                                            description: "Radius in meters",
                                            default: .int(200)
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                    "recurrence": RecurrenceRuleParser.recurrenceSchema,
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                required: ["title", "start", "end"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Create new event
            let event = EKEvent(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            // Parse dates
            guard case .string(let startDateStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                case .string(let endDateStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            let calendar = Calendar.current
            let startDate = calendar.normalizedStartDate(
                from: parsedStart.date,
                isDateOnly: parsedStart.isDateOnly
            )
            let endDate = calendar.normalizedStartDate(
                from: parsedEnd.date,
                isDateOnly: parsedEnd.isDateOnly
            )

            // For all-day events, ensure we use local midnight
            if case .bool(true) = arguments["isAllDay"] {
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            // Set calendar
            var targetCalendar = self.eventStore.defaultCalendarForNewEvents
            if case .string(let calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    targetCalendar = matchingCalendar
                }
            }
            event.calendar = targetCalendar

            // Set optional properties
            if case .string(let location) = arguments["location"] {
                event.location = location
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set alarms
            if case .array(let alarmConfigs) = arguments["alarms"] {
                var alarms: [EKAlarm] = []

                for alarmConfig in alarmConfigs {
                    guard case .object(let config) = alarmConfig else { continue }

                    var alarm: EKAlarm?

                    let alarmType = config["type"]?.stringValue ?? "relative"
                    switch alarmType {
                    case "relative":
                        if case .int(let minutes) = config["minutes"] {
                            alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                        }

                    case "absolute":
                        if case .string(let datetimeStr) = config["datetime"] {
                            if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr) {
                                log.error(
                                    "Absolute alarm datetime must include time component: \(datetimeStr, privacy: .public)"
                                )
                            } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                                fromISO8601String: datetimeStr
                            ) {
                                alarm = EKAlarm(absoluteDate: absoluteDate)
                            }
                        }

                    case "proximity":
                        if case .string(let locationTitle) = config["locationTitle"],
                            case .double(let latitude) = config["latitude"],
                            case .double(let longitude) = config["longitude"]
                        {
                            alarm = EKAlarm()

                            // Create structured location
                            let structuredLocation = EKStructuredLocation(title: locationTitle)
                            structuredLocation.geoLocation = CLLocation(
                                latitude: latitude,
                                longitude: longitude
                            )

                            if case .double(let radius) = config["radius"] {
                                structuredLocation.radius = radius
                            } else if case .int(let radiusInt) = config["radius"] {
                                structuredLocation.radius = Double(radiusInt)
                            }

                            // Set proximity type
                            let proximityType = config["proximity"]?.stringValue ?? "enter"
                            let proximity: EKAlarmProximity =
                                proximityType == "enter" ? .enter : .leave
                            alarm?.proximity = proximity
                            alarm?.structuredLocation = structuredLocation
                        }

                    default:
                        log.error(
                            "Unexpected alarm type encountered: \(alarmType, privacy: .public)"
                        )
                        continue
                    }

                    guard let alarm = alarm else { continue }

                    if case .string(let soundName) = config["sound"],
                        Sound(rawValue: soundName) != nil
                    {
                        alarm.soundName = soundName
                    }

                    if case .string(let email) = config["emailAddress"], !email.isEmpty {
                        alarm.emailAddress = email
                    }

                    alarms.append(alarm)
                }

                event.alarms = alarms
            }

            // Set recurrence
            if let recurrenceValue = arguments["recurrence"] {
                switch try RecurrenceRuleParser.parse(argument: recurrenceValue) {
                case .clear:
                    event.recurrenceRules = nil
                case .rule(let rule):
                    event.recurrenceRules = [rule]
                }
            }

            // Save the event
            try self.eventStore.save(event, span: .thisEvent)

            return Event(event)
        }

        Tool(
            name: "events_update",
            description:
                "Update an existing calendar event. For recurring events, use occurrence_date to target a specific occurrence and span to choose whether the change applies to that occurrence only or to it and all future occurrences. The recurrence parameter sets, replaces, or clears (\"none\") the event's recurrence rule.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Event identifier (from events_fetch)"
                    ),
                    "occurrence_date": .string(
                        description:
                            "Start date/time of the specific occurrence to modify, for recurring events. If omitted, the first occurrence is targeted.",
                        format: .dateTime
                    ),
                    "span": .string(
                        description:
                            "Scope of the change for recurring events: this occurrence only, or this and all future occurrences",
                        default: "this-event",
                        enum: ["this-event", "future-events"]
                    ),
                    "title": .string(),
                    "start": .string(
                        description:
                            "New start date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "New end date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Name of the calendar to move the event to"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(),
                    "availability": .string(
                        description: "Availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description:
                            "Alarm configurations; replaces any existing alarms on the event",
                        items: .anyOf(
                            [
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "relative",
                                        ),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["minutes"],
                                    additionalProperties: false
                                ),
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "absolute",
                                        ),
                                        "datetime": .string(
                                            description:
                                                "Alarm date/time; must be in the future. If timezone is omitted, local time is assumed.",
                                            format: .dateTime
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["datetime"],
                                    additionalProperties: false
                                ),
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "proximity",
                                        ),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
                                        ),
                                        "locationTitle": .string(),
                                        "latitude": .number(),
                                        "longitude": .number(),
                                        "radius": .number(
                                            description: "Radius in meters",
                                            default: .int(200)
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                    "recurrence": RecurrenceRuleParser.recurrenceSchema,
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event id is required"]
                )
            }

            var occurrenceDate: Date? = nil
            if case .string(let occurrenceDateStr) = arguments["occurrence_date"] {
                guard
                    let parsedOccurrence = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: occurrenceDateStr
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid occurrence_date format. Expected ISO 8601 format."
                        ]
                    )
                }
                occurrenceDate = parsedOccurrence.date
            }

            let span: EKSpan
            switch arguments["span"]?.stringValue ?? "this-event" {
            case "future-events":
                span = .futureEvents
            default:
                span = .thisEvent
            }

            let event = try self.resolveEvent(withIdentifier: id, occurrenceDate: occurrenceDate)
            try self.requireWritable(event.calendar)

            // Apply provided changes
            if case .string(let title) = arguments["title"] {
                event.title = title
            }

            let calendar = Calendar.current

            if case .string(let startDateStr) = arguments["start"] {
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startDateStr
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid start date format. Expected ISO 8601 format."
                        ]
                    )
                }
                event.startDate = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
            }

            if case .string(let endDateStr) = arguments["end"] {
                guard
                    let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: endDateStr
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid end date format. Expected ISO 8601 format."
                        ]
                    )
                }
                event.endDate = calendar.normalizedStartDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )
            }

            if case .string(let calendarName) = arguments["calendar"] {
                guard
                    let targetCalendar = self.eventStore.calendars(for: .event)
                        .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No calendar found with name \(calendarName)"
                        ]
                    )
                }
                try self.requireWritable(targetCalendar)
                event.calendar = targetCalendar
            }

            if case .string(let location) = arguments["location"] {
                event.location = location
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .bool(let isAllDay) = arguments["isAllDay"] {
                event.isAllDay = isAllDay
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            if case .array(let alarmConfigs) = arguments["alarms"] {
                event.alarms = try self.parseAlarms(alarmConfigs)
            }

            // Set recurrence. "none" clears the rules; combined with span
            // "future-events" this ends the series from this occurrence on.
            if let recurrenceValue = arguments["recurrence"] {
                switch try RecurrenceRuleParser.parse(argument: recurrenceValue) {
                case .clear:
                    event.recurrenceRules = nil
                case .rule(let rule):
                    event.recurrenceRules = [rule]
                }
            }

            // Save the changes. With span "this-event" on a recurring series,
            // EventKit detaches this occurrence from the series.
            try self.eventStore.save(event, span: span)

            return Event(event)
        }

        Tool(
            name: "events_delete",
            description:
                "Delete a calendar event. For recurring events, use occurrence_date to target a specific occurrence and span to choose whether to delete that occurrence only or it and all future occurrences.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Event identifier (from events_fetch)"
                    ),
                    "occurrence_date": .string(
                        description:
                            "Start date/time of the specific occurrence to delete, for recurring events. If omitted, the first occurrence is targeted.",
                        format: .dateTime
                    ),
                    "span": .string(
                        description:
                            "Scope of the deletion for recurring events: this occurrence only, or this and all future occurrences",
                        default: "this-event",
                        enum: ["this-event", "future-events"]
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event id is required"]
                )
            }

            var occurrenceDate: Date? = nil
            if case .string(let occurrenceDateStr) = arguments["occurrence_date"] {
                guard
                    let parsedOccurrence = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: occurrenceDateStr
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid occurrence_date format. Expected ISO 8601 format."
                        ]
                    )
                }
                occurrenceDate = parsedOccurrence.date
            }

            let span: EKSpan
            switch arguments["span"]?.stringValue ?? "this-event" {
            case "future-events":
                span = .futureEvents
            default:
                span = .thisEvent
            }

            let event = try self.resolveEvent(withIdentifier: id, occurrenceDate: occurrenceDate)
            try self.requireWritable(event.calendar)

            try self.eventStore.remove(event, span: span)

            return Value.object(["deleted": .bool(true)])
        }
    }
}

// MARK: - Recurrence parsing

/// Result of parsing the shared `recurrence` tool parameter.
enum ParsedRecurrence {
    /// Remove any existing recurrence rules (`recurrence: "none"`).
    case clear
    /// Replace recurrence rules with this single rule.
    case rule(EKRecurrenceRule)
}

/// Shared parser for the `recurrence` parameter on events_create/events_update
/// and reminders_create/reminders_update (EKEvent and EKReminder share
/// `EKRecurrenceRule`).
///
/// Accepts either a structured object (freq/interval/days_of_week/
/// days_of_month/until/count) or a raw RFC 5545 RRULE string. EventKit accepts
/// RRULE combinations beyond what the Calendar GUI exposes, so the raw path
/// intentionally allows more than the structured path.
///
/// RRULE support matrix (`EKRecurrenceRule` cannot represent everything in
/// RFC 5545; unsupported parts are rejected with a typed error rather than
/// silently dropped):
/// - Supported: FREQ=DAILY/WEEKLY/MONTHLY/YEARLY; INTERVAL; COUNT; UNTIL
///   (DATE or DATE-TIME, with or without trailing Z); BYDAY including ordinal
///   prefixes such as 1MO or -1FR (ordinals only for MONTHLY/YEARLY); BYMONTHDAY
///   (MONTHLY only, per EventKit's daysOfTheMonth contract); BYMONTH, BYWEEKNO,
///   and BYYEARDAY (YEARLY only); BYSETPOS (requires another BY* part);
///   WKST=MO (the RFC 5545 default; a no-op because EventKit's
///   firstDayOfTheWeek is read-only).
/// - Rejected as unsupported: FREQ=SECONDLY/MINUTELY/HOURLY; BYSECOND;
///   BYMINUTE; BYHOUR; RSCALE; SKIP; WKST other than MO; COUNT and UNTIL
///   together; BY* parts on frequencies where EventKit would silently ignore
///   them; and any unrecognized part.
enum RecurrenceRuleParser {
    // BEGIN RRULE-CORE (standalone-testable: depends only on Foundation + EventKit)

    static func invalidRecurrence(_ message: String) -> NSError {
        return NSError(
            domain: "RecurrenceError",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Invalid recurrence: \(message)"]
        )
    }

    static func unsupportedRecurrence(_ message: String) -> NSError {
        return NSError(
            domain: "RecurrenceError",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Unsupported recurrence: \(message). EKRecurrenceRule cannot represent this part of RFC 5545."
            ]
        )
    }

    private static let weekdaysByCode: [String: EKWeekday] = [
        "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
        "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]

    private static let weekdaysByName: [String: EKWeekday] = [
        "sunday": .sunday, "monday": .monday, "tuesday": .tuesday,
        "wednesday": .wednesday, "thursday": .thursday, "friday": .friday,
        "saturday": .saturday,
    ]

    /// Parses an RFC 5545 RRULE string (with or without a leading "RRULE:")
    /// into an `EKRecurrenceRule`. See the type comment for the support matrix.
    static func rule(fromRRULE rruleString: String) throws -> EKRecurrenceRule {
        var raw = rruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.uppercased().hasPrefix("RRULE:") {
            raw = String(raw.dropFirst("RRULE:".count))
        }
        guard !raw.isEmpty else {
            throw invalidRecurrence("RRULE string is empty")
        }

        var parts: [String: String] = [:]
        for component in raw.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, !pair[1].isEmpty else {
                throw invalidRecurrence("malformed RRULE part \"\(component)\"; expected KEY=VALUE")
            }
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            guard parts[key] == nil else {
                throw invalidRecurrence("duplicate RRULE part \(key)")
            }
            parts[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }

        // Frequency
        guard let freqString = parts.removeValue(forKey: "FREQ") else {
            throw invalidRecurrence("RRULE must include FREQ")
        }
        let frequency: EKRecurrenceFrequency
        switch freqString.uppercased() {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        case "SECONDLY", "MINUTELY", "HOURLY":
            throw unsupportedRecurrence("FREQ=\(freqString.uppercased())")
        default:
            throw invalidRecurrence("unknown FREQ value \"\(freqString)\"")
        }

        // Interval
        var interval = 1
        if let intervalString = parts.removeValue(forKey: "INTERVAL") {
            guard let parsed = Int(intervalString), parsed >= 1 else {
                throw invalidRecurrence("INTERVAL must be a positive integer, got \"\(intervalString)\"")
            }
            interval = parsed
        }

        // End: COUNT and UNTIL are mutually exclusive per RFC 5545
        var end: EKRecurrenceEnd? = nil
        let countString = parts.removeValue(forKey: "COUNT")
        let untilString = parts.removeValue(forKey: "UNTIL")
        if countString != nil, untilString != nil {
            throw invalidRecurrence("COUNT and UNTIL must not both be present")
        }
        if let countString = countString {
            guard let count = Int(countString), count >= 1 else {
                throw invalidRecurrence("COUNT must be a positive integer, got \"\(countString)\"")
            }
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        if let untilString = untilString {
            end = EKRecurrenceEnd(end: try untilDate(from: untilString))
        }

        // BYDAY
        var daysOfTheWeek: [EKRecurrenceDayOfWeek]? = nil
        if let bydayString = parts.removeValue(forKey: "BYDAY") {
            daysOfTheWeek = try bydayString.split(separator: ",").map { token in
                try dayOfWeek(fromToken: String(token), frequency: frequency)
            }
        }

        // Numeric BY* lists, each constrained to the frequencies EventKit
        // honors (it silently ignores them elsewhere, which we refuse to do).
        let daysOfTheMonth = try numericList(
            &parts,
            key: "BYMONTHDAY",
            frequency: frequency,
            allowed: [.monthly],
            range: -31 ... 31
        )
        let monthsOfTheYear = try numericList(
            &parts,
            key: "BYMONTH",
            frequency: frequency,
            allowed: [.yearly],
            range: 1 ... 12
        )
        let weeksOfTheYear = try numericList(
            &parts,
            key: "BYWEEKNO",
            frequency: frequency,
            allowed: [.yearly],
            range: -53 ... 53
        )
        let daysOfTheYear = try numericList(
            &parts,
            key: "BYYEARDAY",
            frequency: frequency,
            allowed: [.yearly],
            range: -366 ... 366
        )

        // BYSETPOS requires at least one other BY* part to select from
        var setPositions: [NSNumber]? = nil
        if let bysetposString = parts.removeValue(forKey: "BYSETPOS") {
            guard
                daysOfTheWeek != nil || daysOfTheMonth != nil || monthsOfTheYear != nil
                    || weeksOfTheYear != nil || daysOfTheYear != nil
            else {
                throw invalidRecurrence("BYSETPOS requires at least one other BY* part")
            }
            setPositions = try parseIntegers(bysetposString, key: "BYSETPOS", range: -366 ... 366)
        }

        // WKST: EventKit's firstDayOfTheWeek is read-only, so only the RFC
        // default (MO) is accepted as a no-op.
        if let wkst = parts.removeValue(forKey: "WKST") {
            guard wkst.uppercased() == "MO" else {
                throw unsupportedRecurrence(
                    "WKST=\(wkst.uppercased()) (EventKit's week start is fixed and cannot be set)"
                )
            }
        }

        // Anything left over is either known-unrepresentable or unrecognized
        if let leftover = parts.keys.sorted().first {
            let unrepresentable: Set<String> = ["BYSECOND", "BYMINUTE", "BYHOUR", "RSCALE", "SKIP"]
            if unrepresentable.contains(leftover) {
                throw unsupportedRecurrence(leftover)
            }
            throw invalidRecurrence("unrecognized RRULE part \(leftover)")
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth,
            monthsOfTheYear: monthsOfTheYear,
            weeksOfTheYear: weeksOfTheYear,
            daysOfTheYear: daysOfTheYear,
            setPositions: setPositions,
            end: end
        )
    }

    /// Parses a BYDAY token such as "MO", "1MO", or "-1FR".
    private static func dayOfWeek(
        fromToken token: String,
        frequency: EKRecurrenceFrequency
    ) throws -> EKRecurrenceDayOfWeek {
        let trimmed = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count >= 2 else {
            throw invalidRecurrence("malformed BYDAY token \"\(token)\"")
        }
        let code = String(trimmed.suffix(2))
        guard let weekday = weekdaysByCode[code] else {
            throw invalidRecurrence("unknown BYDAY weekday \"\(token)\"")
        }
        let ordinalString = String(trimmed.dropLast(2))
        guard !ordinalString.isEmpty else {
            return EKRecurrenceDayOfWeek(weekday)
        }
        guard let ordinal = Int(ordinalString), ordinal != 0, abs(ordinal) <= 53 else {
            throw invalidRecurrence("malformed BYDAY ordinal in \"\(token)\"")
        }
        guard frequency == .monthly || frequency == .yearly else {
            throw unsupportedRecurrence(
                "BYDAY ordinal \"\(token)\" (EventKit honors week-number ordinals only for MONTHLY and YEARLY)"
            )
        }
        return EKRecurrenceDayOfWeek(weekday, weekNumber: ordinal)
    }

    /// Parses a comma-separated numeric BY* list, enforcing the frequencies
    /// EventKit honors for that key.
    private static func numericList(
        _ parts: inout [String: String],
        key: String,
        frequency: EKRecurrenceFrequency,
        allowed: Set<EKRecurrenceFrequency>,
        range: ClosedRange<Int>
    ) throws -> [NSNumber]? {
        guard let listString = parts.removeValue(forKey: key) else { return nil }
        guard allowed.contains(frequency) else {
            throw unsupportedRecurrence(
                "\(key) with this FREQ (EventKit silently ignores it, so it is rejected instead)"
            )
        }
        return try parseIntegers(listString, key: key, range: range)
    }

    private static func parseIntegers(
        _ listString: String,
        key: String,
        range: ClosedRange<Int>
    ) throws -> [NSNumber] {
        return try listString.split(separator: ",").map { token in
            guard let value = Int(token.trimmingCharacters(in: .whitespaces)), value != 0,
                range.contains(value)
            else {
                throw invalidRecurrence("invalid \(key) value \"\(token)\"")
            }
            return NSNumber(value: value)
        }
    }

    /// Parses an RRULE UNTIL value: DATE (yyyyMMdd) or DATE-TIME
    /// (yyyyMMdd'T'HHmmss, optionally with a trailing Z for UTC).
    private static func untilDate(from value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else if value.contains("T") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = .current
        } else {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            guard let date = formatter.date(from: value) else {
                throw invalidRecurrence("invalid UNTIL value \"\(value)\"")
            }
            // Date-only UNTIL is inclusive of that day
            return date.addingTimeInterval(86399)
        }
        guard let date = formatter.date(from: value) else {
            throw invalidRecurrence("invalid UNTIL value \"\(value)\"")
        }
        return date
    }

    // END RRULE-CORE

    /// The shared JSON schema for the `recurrence` tool parameter.
    static var recurrenceSchema: JSONSchema {
        return .anyOf(
            [
                .string(
                    description:
                        "Either \"none\" to remove recurrence, or a raw RFC 5545 RRULE string (e.g. \"FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE\"). Supported parts: FREQ (DAILY/WEEKLY/MONTHLY/YEARLY), INTERVAL, COUNT or UNTIL, BYDAY (ordinals for MONTHLY/YEARLY), BYMONTHDAY (MONTHLY), BYMONTH/BYWEEKNO/BYYEARDAY (YEARLY), BYSETPOS, WKST=MO. Unsupported parts are rejected, not dropped."
                ),
                .object(
                    properties: [
                        "freq": .string(
                            description: "Recurrence frequency",
                            enum: ["daily", "weekly", "monthly", "yearly"]
                        ),
                        "interval": .integer(
                            description: "Repeat every N frequency units",
                            default: .int(1),
                            minimum: 1
                        ),
                        "days_of_week": .array(
                            description: "Weekdays the recurrence falls on",
                            items: .string(
                                enum: [
                                    "sunday", "monday", "tuesday", "wednesday", "thursday",
                                    "friday", "saturday",
                                ]
                            )
                        ),
                        "days_of_month": .array(
                            description:
                                "Days of the month (1-31, or negative from the end); monthly frequency only",
                            items: .integer()
                        ),
                        "until": .string(
                            description:
                                "Last date/time of the recurrence (ISO 8601). Mutually exclusive with count.",
                            format: .dateTime
                        ),
                        "count": .integer(
                            description:
                                "Total number of occurrences. Mutually exclusive with until.",
                            minimum: 1
                        ),
                    ],
                    required: ["freq"],
                    additionalProperties: false
                ),
            ]
        )
    }

    /// Parses the `recurrence` tool argument: "none", a raw RRULE string, or a
    /// structured object.
    static func parse(argument: Value) throws -> ParsedRecurrence {
        switch argument {
        case .string(let stringValue):
            if stringValue.lowercased() == "none" {
                return .clear
            }
            return .rule(try rule(fromRRULE: stringValue))
        case .object(let object):
            return .rule(try rule(fromStructured: object))
        default:
            throw invalidRecurrence(
                "recurrence must be \"none\", an RRULE string, or a structured object"
            )
        }
    }

    /// Builds an `EKRecurrenceRule` from the structured object form.
    private static func rule(fromStructured object: [String: Value]) throws -> EKRecurrenceRule {
        guard case .string(let freqString) = object["freq"] else {
            throw invalidRecurrence("structured recurrence requires a freq field")
        }
        let frequency: EKRecurrenceFrequency
        switch freqString.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default:
            throw invalidRecurrence("unknown freq value \"\(freqString)\"")
        }

        var interval = 1
        if case .int(let intervalValue) = object["interval"] {
            guard intervalValue >= 1 else {
                throw invalidRecurrence("interval must be a positive integer")
            }
            interval = intervalValue
        }

        var daysOfTheWeek: [EKRecurrenceDayOfWeek]? = nil
        if case .array(let dayValues) = object["days_of_week"], !dayValues.isEmpty {
            daysOfTheWeek = try dayValues.map { dayValue in
                guard case .string(let dayName) = dayValue,
                    let weekday = weekdaysByName[dayName.lowercased()]
                else {
                    throw invalidRecurrence("unknown weekday in days_of_week")
                }
                return EKRecurrenceDayOfWeek(weekday)
            }
        }

        var daysOfTheMonth: [NSNumber]? = nil
        if case .array(let dayValues) = object["days_of_month"], !dayValues.isEmpty {
            guard frequency == .monthly else {
                throw unsupportedRecurrence(
                    "days_of_month with \(freqString) frequency (EventKit honors it only for monthly)"
                )
            }
            daysOfTheMonth = try dayValues.map { dayValue in
                guard case .int(let day) = dayValue, day != 0, (-31 ... 31).contains(day) else {
                    throw invalidRecurrence("days_of_month values must be 1-31 or negative from the end")
                }
                return NSNumber(value: day)
            }
        }

        var end: EKRecurrenceEnd? = nil
        let hasUntil = object["until"] != nil
        let hasCount = object["count"] != nil
        if hasUntil, hasCount {
            throw invalidRecurrence("until and count must not both be present")
        }
        if case .string(let untilString) = object["until"] {
            guard
                let parsedUntil = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: untilString
                )
            else {
                throw invalidRecurrence("until must be an ISO 8601 date/time")
            }
            var untilDate = parsedUntil.date
            if parsedUntil.isDateOnly {
                // Date-only until is inclusive of that day
                untilDate = Foundation.Calendar.current.normalizedEndDate(
                    from: untilDate,
                    isDateOnly: true
                )
            }
            end = EKRecurrenceEnd(end: untilDate)
        }
        if case .int(let count) = object["count"] {
            guard count >= 1 else {
                throw invalidRecurrence("count must be a positive integer")
            }
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }
}
