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
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            let statusAfterRequest = EKEventStore.authorizationStatus(for: .event)
            throw ServicePermissionError.requestFailed(
                domain: "CalendarError",
                what: "Calendar",
                promptCouldHaveAppeared: statusAfterRequest != .notDetermined
            )
        }
    }

    /// One resolved event, with how its occurrence was matched.
    struct ResolvedEvent {
        let event: EKEvent
        /// "series" when the identifier was looked up on its own,
        /// "exact" or "nearest" when an occurrence date was given.
        let match: String
        /// Seconds between the requested occurrence and the one returned,
        /// present only for a nearest match.
        let offset: TimeInterval?
    }

    /// Resolves an event by identifier, optionally disambiguating a specific
    /// occurrence of a recurring event by its occurrence date.
    ///
    /// The window and the choice among candidates live in
    /// `CalendarEventLookup` so they can be tested without a live store.
    private func locateEvent(
        withIdentifier id: String,
        occurrenceDate: Date?
    ) throws -> ResolvedEvent {
        if let occurrenceDate = occurrenceDate {
            // `event(withIdentifier:)` returns the first occurrence of a recurring
            // event, so search a window around the occurrence date instead and
            // match on the identifier.
            let window = CalendarEventLookup.window(around: occurrenceDate)
            let predicate = eventStore.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: nil
            )
            let events = eventStore.events(matching: predicate)
            let candidates = events.compactMap { event -> CalendarOccurrenceCandidate? in
                guard let identifier = event.eventIdentifier else { return nil }
                return CalendarOccurrenceCandidate(identifier: identifier, start: event.startDate)
            }
            let selection = CalendarEventLookup.selectOccurrence(
                from: candidates,
                identifier: id,
                occurrenceDate: occurrenceDate
            )

            func event(for candidate: CalendarOccurrenceCandidate) -> EKEvent? {
                events.first {
                    $0.eventIdentifier == candidate.identifier && $0.startDate == candidate.start
                }
            }

            switch selection {
            case .exact(let candidate):
                if let match = event(for: candidate) {
                    return ResolvedEvent(event: match, match: "exact", offset: nil)
                }
            case .nearest(let candidate, let offset):
                if let match = event(for: candidate) {
                    return ResolvedEvent(event: match, match: "nearest", offset: offset)
                }
            case .none:
                break
            }

            throw NSError(
                domain: "CalendarError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        CalendarEventLookup.notFoundMessage(
                            identifier: id,
                            occurrenceDate: occurrenceDate
                        )
                ]
            )
        }

        guard let event = eventStore.event(withIdentifier: id) else {
            throw NSError(
                domain: "CalendarError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        CalendarEventLookup.notFoundMessage(identifier: id, occurrenceDate: nil)
                ]
            )
        }
        return ResolvedEvent(event: event, match: "series", offset: nil)
    }

    private func resolveEvent(withIdentifier id: String, occurrenceDate: Date?) throws -> EKEvent {
        try locateEvent(withIdentifier: id, occurrenceDate: occurrenceDate).event
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

        func invalidAlarm(_ description: String) -> NSError {
            NSError(
                domain: "CalendarError",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }

        for alarmConfig in alarmConfigs {
            guard case .object(let config) = alarmConfig else {
                throw invalidAlarm("Each alarm must be an object.")
            }

            let alarmType: String
            if let typeValue = config["type"] {
                guard case .string(let type) = typeValue else {
                    throw invalidAlarm("Alarm type must be a string.")
                }
                alarmType = type
            } else if config["datetime"] != nil {
                alarmType = "absolute"
            } else if config["locationTitle"] != nil || config["latitude"] != nil
                || config["longitude"] != nil
            {
                alarmType = "proximity"
            } else {
                alarmType = "relative"
            }
            let alarm: EKAlarm
            switch alarmType {
            case "relative":
                guard case .int(let minutes) = config["minutes"] else {
                    throw invalidAlarm("A relative alarm requires integer minutes.")
                }
                alarm = EKAlarm(relativeOffset: TimeInterval(minutes) * 60)

            case "absolute":
                guard case .string(let datetimeStr) = config["datetime"],
                    !ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr),
                    let absoluteDate = ISO8601DateFormatter.lenientDate(
                        fromISO8601String: datetimeStr
                    )
                else {
                    throw invalidAlarm(
                        "Absolute alarm datetime must be a valid ISO 8601 date/time with a time component."
                    )
                }
                guard absoluteDate > Date() else {
                    throw invalidAlarm(
                        "Absolute alarm date \(datetimeStr) is in the past; macOS rejects past alarms silently, so it was not set."
                    )
                }
                alarm = EKAlarm(absoluteDate: absoluteDate)

            case "proximity":
                guard case .string(let locationTitle) = config["locationTitle"],
                    !locationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let latitude = config["latitude"]?.doubleCoerced,
                    (-90.0 ... 90.0).contains(latitude),
                    let longitude = config["longitude"]?.doubleCoerced,
                    (-180.0 ... 180.0).contains(longitude)
                else {
                    throw invalidAlarm(
                        "A proximity alarm requires a title and valid latitude and longitude."
                    )
                }
                let radius: Double
                if let radiusValue = config["radius"] {
                    guard let parsedRadius = radiusValue.doubleCoerced else {
                        throw invalidAlarm("A proximity alarm radius must be a number.")
                    }
                    radius = parsedRadius
                } else {
                    radius = 200
                }
                guard radius >= 0 else {
                    throw invalidAlarm("A proximity alarm radius must not be negative.")
                }
                let proximityType: String
                if let proximityValue = config["proximity"] {
                    guard case .string(let parsedProximity) = proximityValue else {
                        throw invalidAlarm("A proximity alarm trigger must be a string.")
                    }
                    proximityType = parsedProximity
                } else {
                    proximityType = "enter"
                }
                guard proximityType == "enter" || proximityType == "leave" else {
                    throw invalidAlarm("A proximity alarm must use enter or leave.")
                }

                let structuredLocation = EKStructuredLocation(title: locationTitle)
                structuredLocation.geoLocation = CLLocation(
                    latitude: latitude,
                    longitude: longitude
                )
                structuredLocation.radius = radius

                let proximityAlarm = EKAlarm()
                proximityAlarm.proximity = proximityType == "enter" ? .enter : .leave
                proximityAlarm.structuredLocation = structuredLocation
                alarm = proximityAlarm

            default:
                throw invalidAlarm("Unknown alarm type \(alarmType).")
            }

            if let soundValue = config["sound"] {
                guard case .string(let soundName) = soundValue,
                    Sound(rawValue: soundName) != nil
                else {
                    throw invalidAlarm("Alarm sound must be a supported sound name.")
                }
                alarm.soundName = soundName
            }

            if let emailValue = config["emailAddress"] {
                guard case .string(let email) = emailValue, !email.isEmpty else {
                    throw invalidAlarm("Alarm emailAddress must be a nonempty string.")
                }
                alarm.emailAddress = email
            }

            alarms.append(alarm)
        }

        return alarms
    }

    var tools: [Tool] {
        Tool(
            name: "calendar_list",
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
                    "identifier": .string(calendar.calendarIdentifier),
                    "title": .string(calendar.title),
                    "source": .string(calendar.source.title),
                    "color": .string(calendar.color.accessibilityName),
                    "isEditable": .bool(calendar.allowsContentModifications),
                    "isSubscribed": .bool(calendar.isSubscribed),
                ])
            }
        }

        Tool(
            name: "calendar_events_fetch",
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

            if let startValue = arguments["start"] {
                guard case .string(let start) = startValue else {
                    throw NSError(
                        domain: "CalendarError",
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
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Start must be a valid ISO 8601 date or date-time."]
                    )
                }
                hasStart = true
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }

            if let endValue = arguments["end"] {
                guard case .string(let end) = endValue else {
                    throw NSError(
                        domain: "CalendarError",
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
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "End must be a valid ISO 8601 date or date-time."]
                    )
                }
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

            guard startDate <= endDate else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
                )
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
                guard let statusValue = EKEventStatus(status) else {
                    throw NSError(
                        domain: "CalendarServiceError",
                        code: 9,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown status \(status). Valid values: none, tentative, confirmed, canceled."
                        ]
                    )
                }
                events = events.filter { $0.status == statusValue }
            }

            if case .string(let availability) = arguments["availability"] {
                guard let availabilityValue = EKEventAvailability(availability) else {
                    throw NSError(
                        domain: "CalendarServiceError",
                        code: 10,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown availability \(availability). Valid values: busy, free, tentative, unavailable."
                        ]
                    )
                }
                events = events.filter { $0.availability == availabilityValue }
            }

            if case .bool(let hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case .bool(let isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            // Expose the EventKit identifier so callers can feed it back to
            // calendar_events_update / calendar_events_delete, which resolve by eventIdentifier.
            return Value.array(
                events.map { ekEvent in
                    var event = Event(ekEvent)
                    event.identifier = ekEvent.eventIdentifier
                    // The schema.org keys stay exactly where they were; the
                    // EventKit fields Ontology has no room for are merged in
                    // beside them rather than replacing anything.
                    guard case .object(var encoded) = try? Value(event) else {
                        return (try? Value(event)) ?? .null
                    }
                    for (key, value) in Self.detail(of: ekEvent) where encoded[key] == nil {
                        encoded[key] = value
                    }
                    return .object(encoded)
                }
            )
        }
        Tool(
            name: "calendar_events_get",
            description:
                "Fetch one calendar event by its exact identifier, without a date range. "
                + "For a repeating event, pass occurrenceDate to get that occurrence rather than the first "
                + "one in the series. A stale or deleted identifier is reported as NOT_FOUND rather than as "
                + "an empty result.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Event identifier (from calendar_events_fetch)"
                    ),
                    "occurrenceDate": .string(
                        description:
                            "Start date/time of a specific occurrence, for a repeating event. "
                            + "The nearest occurrence within a day either side is returned, and the result says "
                            + "whether the match was exact.",
                        format: .dateTime
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Event",
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

            let id = try CalendarEventLookup.normalize(
                identifier: arguments["id"]?.stringValue
            )

            var occurrenceDate: Date? = nil
            if let occurrenceValue = arguments["occurrenceDate"] {
                guard case .string(let occurrenceInput) = occurrenceValue,
                    let parsedOccurrence = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: occurrenceInput
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "occurrenceDate must be a valid ISO 8601 date or date-time."
                        ]
                    )
                }
                occurrenceDate = parsedOccurrence.date
            }

            let resolved = try self.locateEvent(withIdentifier: id, occurrenceDate: occurrenceDate)
            let ekEvent = resolved.event

            var event = Event(ekEvent)
            event.identifier = ekEvent.eventIdentifier

            var result: [String: Value] = [
                "event": try Value(event),
                "detail": .object(Self.detail(of: ekEvent)),
                "identifier": .string(ekEvent.eventIdentifier ?? id),
                "calendar": .object([
                    "identifier": .string(ekEvent.calendar.calendarIdentifier),
                    "title": .string(ekEvent.calendar.title),
                    "isEditable": .bool(ekEvent.calendar.allowsContentModifications),
                ]),
                "isRecurring": .bool(ekEvent.hasRecurrenceRules),
                "isDetached": .bool(ekEvent.isDetached),
                "attendeeCount": .int(ekEvent.attendees?.count ?? 0),
                "occurrenceMatch": .string(resolved.match),
            ]
            if let offset = resolved.offset {
                // Reported rather than hidden: the caller asked for one moment
                // and got a different one, and how different decides whether
                // that is the event they meant.
                result["occurrenceOffsetSeconds"] = .int(Int(offset.rounded()))
            }
            return Value.object(result)
        }

        Tool(
            name: "calendar_events_create",
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
                                    required: ["type", "minutes"],
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
                                                "Alarm date/time with a time component. If timezone is omitted, local time is assumed.",
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
                                    required: ["type", "datetime"],
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
                                    required: ["type", "locationTitle", "latitude", "longitude"],
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
            guard event.startDate <= event.endDate else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
                )
            }

            // Set calendar. A requested calendar that matches nothing throws
            // (matching the update path) instead of silently filing the event
            // into the default calendar.
            guard let defaultCalendar = self.eventStore.defaultCalendarForNewEvents else {
                throw NSError(
                    domain: "CalendarServiceError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No default calendar is available for new events"
                    ]
                )
            }
            var targetCalendar = defaultCalendar
            if case .string(let calendarName) = arguments["calendar"] {
                guard
                    let matchingCalendar = self.eventStore.calendars(for: .event)
                        .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                else {
                    throw NSError(
                        domain: "CalendarServiceError",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No calendar found with name \(calendarName)"
                        ]
                    )
                }
                targetCalendar = matchingCalendar
            }
            try self.requireWritable(targetCalendar)
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
                guard let availabilityValue = EKEventAvailability(availability) else {
                    throw NSError(
                        domain: "CalendarServiceError",
                        code: 10,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown availability \(availability). Valid values: busy, free, tentative, unavailable."
                        ]
                    )
                }
                event.availability = availabilityValue
            }

            // Set alarms through the same validated path used by updates.
            if let alarmsValue = arguments["alarms"] {
                guard case .array(let alarmConfigs) = alarmsValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Alarms must be an array."]
                    )
                }
                event.alarms = try self.parseAlarms(alarmConfigs)
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

            var result = Event(event)
            result.identifier = event.eventIdentifier
            return result
        }

        Tool(
            name: "calendar_event_attendees",
            description:
                "List the people invited to an event, with each one's response status and role. "
                + "Read-only: EventKit does not allow adding or removing attendees programmatically, so "
                + "invitations must be sent from Calendar itself.",
            inputSchema: .object(
                properties: [
                    "id": .string(description: "Event identifier (from calendar_events_fetch)"),
                    "occurrenceDate": .string(
                        description:
                            "ISO 8601 date of a specific occurrence, for a repeating event"
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Event Attendees",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let id = arguments["id"]?.stringValue else {
                throw NSError(
                    domain: "CalendarService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing event identifier"]
                )
            }
            var occurrenceDate: Date? = nil
            if let occurrenceValue = arguments["occurrenceDate"] {
                guard case .string(let occurrenceInput) = occurrenceValue,
                    let parsedOccurrence = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: occurrenceInput
                    )
                else {
                    throw NSError(
                        domain: "CalendarService",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Occurrence date must be a valid ISO 8601 string."
                        ]
                    )
                }
                occurrenceDate = parsedOccurrence.date
            }

            let event = try self.resolveEvent(withIdentifier: id, occurrenceDate: occurrenceDate)

            let described: [Value] = (event.attendees ?? []).map { participant in
                var entry: [String: Value] = [
                    "role": .string(Self.describe(participant.participantRole)),
                    "status": .string(Self.describe(participant.participantStatus)),
                    "isCurrentUser": .bool(participant.isCurrentUser),
                ]
                if let name = participant.name { entry["name"] = .string(name) }
                // The URL is mailto: for an email invitee; the address is the
                // useful half and the scheme is noise.
                if let email = participant.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .nilIfEmpty
                {
                    entry["email"] = .string(email)
                }
                return .object(entry)
            }

            var result: [String: Value] = [
                "eventId": .string(id),
                "attendees": .array(described),
                "count": .int(described.count),
            ]
            if let organizer = event.organizer?.name {
                result["organizer"] = .string(organizer)
            }
            return Value.object(result)
        }

        Tool(
            name: "calendar_events_update",
            description:
                "Update an existing calendar event. For recurring events, use occurrence_date to target a specific occurrence and span to choose whether the change applies to that occurrence only or to it and all future occurrences. The recurrence parameter sets, replaces, or clears (\"none\") the event's recurrence rule.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Event identifier (from calendar_events_fetch)"
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
                                    required: ["type", "minutes"],
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
                                    required: ["type", "datetime"],
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
                                    required: ["type", "locationTitle", "latitude", "longitude"],
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
            if let occurrenceValue = arguments["occurrence_date"] {
                guard case .string(let occurrenceDateStr) = occurrenceValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Occurrence date must be an ISO 8601 string."]
                    )
                }
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
            let spanInput: String
            if let spanValue = arguments["span"] {
                guard case .string(let providedSpan) = spanValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Span must be this-event or future-events."]
                    )
                }
                spanInput = providedSpan
            } else {
                spanInput = "this-event"
            }
            switch spanInput {
            case "future-events":
                span = .futureEvents
            case "this-event":
                span = .thisEvent
            default:
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Span must be this-event or future-events."]
                )
            }

            let event = try self.resolveEvent(withIdentifier: id, occurrenceDate: occurrenceDate)
            try self.requireWritable(event.calendar)

            // Apply provided changes
            if case .string(let title) = arguments["title"] {
                event.title = title
            }

            let calendar = Calendar.current

            if let startValue = arguments["start"] {
                guard case .string(let startDateStr) = startValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Start must be an ISO 8601 string."]
                    )
                }
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

            if let endValue = arguments["end"] {
                guard case .string(let endDateStr) = endValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "End must be an ISO 8601 string."]
                    )
                }
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

            guard event.startDate <= event.endDate else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Start must not be after end."]
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
                guard let availabilityValue = EKEventAvailability(availability) else {
                    throw NSError(
                        domain: "CalendarServiceError",
                        code: 10,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown availability \(availability). Valid values: busy, free, tentative, unavailable."
                        ]
                    )
                }
                event.availability = availabilityValue
            }

            if let alarmsValue = arguments["alarms"] {
                guard case .array(let alarmConfigs) = alarmsValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Alarms must be an array."]
                    )
                }
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

            var result = Event(event)
            result.identifier = event.eventIdentifier
            return result
        }

        Tool(
            name: "calendar_availability",
            description:
                "Find free time, or check whether a proposed time is clear. EventKit has no free/busy "
                + "query, so this reads the events in the range and computes the gaps. Events marked "
                + "as free, and cancelled events, do not block; all-day events block the whole day "
                + "unless allDayBlocks is false. Pass proposedStart and proposedEnd to test one "
                + "specific slot and get back whatever is in the way.",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description:
                            "Start of the search range. Defaults to now. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "End of the search range. Defaults to one week after start.",
                        format: .dateTime
                    ),
                    "calendars": .array(
                        description:
                            "Names of calendars that count as busy. Defaults to every calendar.",
                        items: .string()
                    ),
                    "durationMinutes": .integer(
                        description: "Only report gaps at least this long. Defaults to 30.",
                        default: .int(30)
                    ),
                    "dayStart": .string(
                        description:
                            "Earliest time of day to consider, as HH:MM local. Defaults to 00:00."
                    ),
                    "dayEnd": .string(
                        description:
                            "Latest time of day to consider, as HH:MM local. Defaults to 24:00."
                    ),
                    "weekdays": .array(
                        description:
                            "Restrict to these weekdays, 1 = Sunday through 7 = Saturday. Defaults to every day.",
                        items: .integer()
                    ),
                    "allDayBlocks": .boolean(
                        description:
                            "Whether an all-day event makes that day busy. Defaults to true.",
                        default: .bool(true)
                    ),
                    "proposedStart": .string(
                        description:
                            "Check this exact slot instead of searching. Requires proposedEnd.",
                        format: .dateTime
                    ),
                    "proposedEnd": .string(
                        description: "End of the slot to check. Requires proposedStart.",
                        format: .dateTime
                    ),
                    "limit": .integer(
                        description: "Maximum free slots to return. Defaults to 50.",
                        default: .int(50)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Calendar Availability",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let proposedStart = try Self.parseOptionalDate(arguments["proposedStart"], named: "proposedStart")
            let proposedEnd = try Self.parseOptionalDate(arguments["proposedEnd"], named: "proposedEnd")
            if (proposedStart == nil) != (proposedEnd == nil) {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "proposedStart and proposedEnd must be given together."
                    ]
                )
            }

            let now = Date()
            var rangeStart = try Self.parseOptionalDate(arguments["start"], named: "start") ?? now
            var rangeEnd =
                try Self.parseOptionalDate(arguments["end"], named: "end")
                ?? rangeStart.addingTimeInterval(7 * 24 * 60 * 60)
            if let proposedStart, let proposedEnd {
                guard proposedEnd > proposedStart else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "proposedEnd must be after proposedStart."
                        ]
                    )
                }
                // Checking one slot means reading exactly the events that
                // could overlap it, not a week of them.
                rangeStart = proposedStart
                rangeEnd = proposedEnd
            }
            guard rangeEnd > rangeStart else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "end must be after start."]
                )
            }

            var selected: [EKCalendar]? = nil
            if case .array(let names) = arguments["calendars"], !names.isEmpty {
                let wanted = Set(names.compactMap(\.stringValue))
                selected = self.eventStore.calendars(for: .event).filter {
                    wanted.contains($0.title)
                }
                if selected?.isEmpty ?? true {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "None of the named calendars exist. Use calendar_list to see them."
                        ]
                    )
                }
            }

            let allDayBlocks = arguments["allDayBlocks"]?.boolValue ?? true
            let predicate = self.eventStore.predicateForEvents(
                withStart: rangeStart,
                end: rangeEnd,
                calendars: selected
            )
            let busy: [BusyInterval] = self.eventStore.events(matching: predicate)
                .compactMap { event in
                    // An event explicitly marked free is not a conflict, and
                    // neither is one that was cancelled.
                    guard event.availability != .free, event.status != .canceled else { return nil }
                    guard allDayBlocks || !event.isAllDay else { return nil }
                    guard let start = event.startDate, let end = event.endDate else { return nil }
                    return BusyInterval(start: start, end: end, title: event.title)
                }

            let formatter = ISO8601DateFormatter()
            func describe(_ interval: BusyInterval) -> Value {
                var entry: [String: Value] = [
                    "start": .string(formatter.string(from: interval.start)),
                    "end": .string(formatter.string(from: interval.end)),
                ]
                if let title = interval.title { entry["title"] = .string(title) }
                return .object(entry)
            }

            if let proposedStart, let proposedEnd {
                let proposal = FreeSlot(start: proposedStart, end: proposedEnd)
                let conflicts = CalendarAvailability.conflicts(with: proposal, busy: busy)
                return Value.object([
                    "start": .string(formatter.string(from: proposedStart)),
                    "end": .string(formatter.string(from: proposedEnd)),
                    "isFree": .bool(conflicts.isEmpty),
                    "conflicts": .array(conflicts.map(describe)),
                ])
            }

            let window = try Self.dayWindow(
                start: arguments["dayStart"]?.stringValue,
                end: arguments["dayEnd"]?.stringValue
            )
            var weekdays: Set<Int>? = nil
            if case .array(let raw) = arguments["weekdays"], !raw.isEmpty {
                let parsed = Set(raw.compactMap(\.intValue))
                guard parsed.allSatisfy({ (1 ... 7).contains($0) }) else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "weekdays must be between 1 (Sunday) and 7 (Saturday)."
                        ]
                    )
                }
                weekdays = parsed
            }
            let minimumMinutes = max(arguments["durationMinutes"]?.intValue ?? 30, 1)
            let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 500)

            let slots = CalendarAvailability.freeSlots(
                from: rangeStart,
                to: rangeEnd,
                busy: busy,
                window: window,
                weekdays: weekdays,
                minimumDuration: TimeInterval(minimumMinutes) * 60,
                limit: limit
            )
            return Value.object([
                "start": .string(formatter.string(from: rangeStart)),
                "end": .string(formatter.string(from: rangeEnd)),
                "durationMinutes": .int(minimumMinutes),
                "busyCount": .int(busy.count),
                "count": .int(slots.count),
                "slots": .array(
                    slots.map { slot in
                        .object([
                            "start": .string(formatter.string(from: slot.start)),
                            "end": .string(formatter.string(from: slot.end)),
                            "minutes": .int(Int(slot.duration / 60)),
                        ])
                    }
                ),
            ])
        }

        Tool(
            name: "calendar_events_delete",
            description:
                "Delete a calendar event. For recurring events, use occurrence_date to target a specific occurrence and span to choose whether to delete that occurrence only or it and all future occurrences.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Event identifier (from calendar_events_fetch)"
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
            if let occurrenceValue = arguments["occurrence_date"] {
                guard case .string(let occurrenceDateStr) = occurrenceValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Occurrence date must be an ISO 8601 string."]
                    )
                }
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
            let spanInput: String
            if let spanValue = arguments["span"] {
                guard case .string(let providedSpan) = spanValue else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Span must be this-event or future-events."]
                    )
                }
                spanInput = providedSpan
            } else {
                spanInput = "this-event"
            }
            switch spanInput {
            case "future-events":
                span = .futureEvents
            case "this-event":
                span = .thisEvent
            default:
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Span must be this-event or future-events."]
                )
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

/// Shared parser for the `recurrence` parameter on calendar_events_create/calendar_events_update
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
            guard let parsed = Int(intervalString), (1 ... Int(Int32.max)).contains(parsed) else {
                throw invalidRecurrence(
                    "INTERVAL must be between 1 and \(Int32.max), got \"\(intervalString)\""
                )
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
        guard let ordinal = Int(ordinalString), ordinal != 0, (-53 ... 53).contains(ordinal) else {
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
                            minimum: 1,
                            maximum: Int(Int32.max)
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
            guard (1 ... Int(Int32.max)).contains(intervalValue) else {
                throw invalidRecurrence("interval must be between 1 and \(Int32.max)")
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

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension CalendarService {
    static func parseOptionalDate(_ value: Value?, named name: String) throws -> Date? {
        guard let value else { return nil }
        guard case .string(let raw) = value,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: raw)
        else {
            throw NSError(
                domain: "CalendarError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(name) must be a valid ISO 8601 date or date-time."
                ]
            )
        }
        return parsed.isDateOnly
            ? Foundation.Calendar.current.normalizedStartDate(from: parsed.date, isDateOnly: true)
            : parsed.date
    }

    /// "HH:MM" to minutes after midnight. "24:00" is accepted for the end of
    /// the day, which is the natural way to write "until midnight".
    static func dayWindow(start: String?, end: String?) throws -> DayWindow {
        func minutes(_ raw: String?, _ name: String, default fallback: Int) throws -> Int {
            guard let raw, !raw.isEmpty else { return fallback }
            let parts = raw.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                (0 ... 24).contains(hour), (0 ... 59).contains(minute),
                hour * 60 + minute <= 24 * 60
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(name) must be a time of day as HH:MM, between 00:00 and 24:00."
                    ]
                )
            }
            return hour * 60 + minute
        }
        let startMinute = try minutes(start, "dayStart", default: 0)
        let endMinute = try minutes(end, "dayEnd", default: 24 * 60)
        guard endMinute > startMinute else {
            throw NSError(
                domain: "CalendarError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "dayEnd must be after dayStart."]
            )
        }
        return DayWindow(startMinute: startMinute, endMinute: endMinute)
    }

    /// Everything about an event that EventKit knows and the schema.org
    /// `Event` type has no room for.
    ///
    /// `Ontology.Event` carries name, calendar, start, end, location and URL.
    /// That left notes, the all-day flag, availability, status, alarms,
    /// recurrence, attendees, the organizer, the time zone, the geofence and
    /// both timestamps unreachable through any read tool in this surface — a
    /// caller could create an all-day event with a note and an alarm, then read
    /// it back as a timed event with neither. This fills the gap without
    /// changing the shape of what was already returned: the schema.org keys
    /// stay where they were and these are added beside them.
    static func detail(of event: EKEvent) -> [String: Value] {
        let formatter = ISO8601DateFormatter()
        var detail: [String: Value] = [
            "isAllDay": .bool(event.isAllDay),
            "availability": .string(event.availability.stringValue),
            "status": .string(describe(event.status)),
            "isDetached": .bool(event.isDetached),
            "hasAttendees": .bool(event.hasAttendees),
        ]

        if let notes = event.notes, !notes.isEmpty { detail["notes"] = .string(notes) }
        if let timeZone = event.timeZone { detail["timeZone"] = .string(timeZone.identifier) }
        if let created = event.creationDate {
            detail["createdAt"] = .string(formatter.string(from: created))
        }
        if let modified = event.lastModifiedDate {
            detail["lastModifiedAt"] = .string(formatter.string(from: modified))
        }
        // The original scheduled time of this occurrence. For a detached
        // occurrence it is the only way to tell which one was moved.
        if let occurrence = event.occurrenceDate {
            detail["occurrenceDate"] = .string(formatter.string(from: occurrence))
        }
        // Birthday events point back at the contact they came from, which is
        // what makes "whose birthday is this" answerable without name matching.
        if let contact = event.birthdayContactIdentifier {
            detail["birthdayContactIdentifier"] = .string(contact)
        }
        if let external = event.calendarItemExternalIdentifier {
            detail["externalIdentifier"] = .string(external)
        }

        if let place = event.structuredLocation {
            var described: [String: Value] = [:]
            if let title = place.title, !title.isEmpty { described["name"] = .string(title) }
            if let coordinate = place.geoLocation?.coordinate {
                described["latitude"] = .double(coordinate.latitude)
                described["longitude"] = .double(coordinate.longitude)
            }
            if place.radius > 0 { described["radiusMeters"] = .double(place.radius) }
            if !described.isEmpty { detail["structuredLocation"] = .object(described) }
        }

        let alarms = event.alarms ?? []
        if !alarms.isEmpty { detail["alarms"] = .array(alarms.map(describeAlarm)) }

        if let rule = event.recurrenceRules?.first {
            let description = describe(rule)
            var recurrence: [String: Value] = ["rrule": .string(description.rrule)]
            if let summary = description.summary { recurrence["summary"] = .string(summary) }
            detail["recurrence"] = .object(recurrence)
            // More than one rule is legal in RFC 5545 and rare in practice;
            // saying so beats silently reporting the first as the whole truth.
            if (event.recurrenceRules?.count ?? 0) > 1 {
                detail["additionalRecurrenceRules"] = .int((event.recurrenceRules?.count ?? 1) - 1)
            }
        }

        if let organizer = event.organizer {
            detail["organizer"] = describe(organizer)
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            detail["attendees"] = .array(attendees.map(describe))
            if let me = attendees.first(where: { $0.isCurrentUser }) {
                detail["myStatus"] = .string(describe(me.participantStatus))
            }
        }

        return detail
    }

    /// EventKit models a geofenced alarm, an absolute alarm and a relative
    /// alarm in one type, distinguished by which fields are set.
    static func describeAlarm(_ alarm: EKAlarm) -> Value {
        var entry: [String: Value] = [:]
        if let place = alarm.structuredLocation, alarm.proximity != .none {
            entry["type"] = .string("location")
            entry["proximity"] = .string(alarm.proximity == .enter ? "arriving" : "leaving")
            if let title = place.title, !title.isEmpty { entry["name"] = .string(title) }
            if let coordinate = place.geoLocation?.coordinate {
                entry["latitude"] = .double(coordinate.latitude)
                entry["longitude"] = .double(coordinate.longitude)
            }
            if place.radius > 0 { entry["radiusMeters"] = .double(place.radius) }
        } else if let absolute = alarm.absoluteDate {
            entry["type"] = .string("absolute")
            entry["date"] = .string(ISO8601DateFormatter().string(from: absolute))
        } else {
            entry["type"] = .string("relative")
            entry["minutesBefore"] = .int(Int((-alarm.relativeOffset / 60).rounded()))
        }
        if let email = alarm.emailAddress { entry["emailAddress"] = .string(email) }
        if let sound = alarm.soundName { entry["sound"] = .string(sound) }
        return .object(entry)
    }

    /// `EKRecurrenceRule` field by field, with no interpretation. The RRULE
    /// spelling happens in `RecurrenceDescription`, which is tested.
    static func describe(_ rule: EKRecurrenceRule) -> RecurrenceDescription {
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "daily"
        }
        return RecurrenceDescription(
            frequency: frequency,
            interval: rule.interval,
            daysOfTheWeek: (rule.daysOfTheWeek ?? []).map {
                (weekday: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
            },
            daysOfTheMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            daysOfTheYear: (rule.daysOfTheYear ?? []).map(\.intValue),
            weeksOfTheYear: (rule.weeksOfTheYear ?? []).map(\.intValue),
            monthsOfTheYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            firstDayOfTheWeek: rule.firstDayOfTheWeek,
            endDate: rule.recurrenceEnd?.endDate,
            occurrenceCount: rule.recurrenceEnd?.occurrenceCount ?? 0
        )
    }

    static func describe(_ participant: EKParticipant) -> Value {
        var entry: [String: Value] = [
            "status": .string(describe(participant.participantStatus)),
            "role": .string(describe(participant.participantRole)),
            "type": .string(describe(participant.participantType)),
            "isCurrentUser": .bool(participant.isCurrentUser),
        ]
        if let name = participant.name, !name.isEmpty { entry["name"] = .string(name) }
        // The URL is a mailto: in almost every case; the address is what a
        // caller needs to match the attendee against a contact.
        let url = participant.url.absoluteString
        entry["url"] = .string(url)
        if url.lowercased().hasPrefix("mailto:") {
            entry["email"] = .string(String(url.dropFirst("mailto:".count)))
        }
        return .object(entry)
    }

    fileprivate static func describe(_ type: EKParticipantType) -> String {
        switch type {
        case .person: "person"
        case .room: "room"
        case .resource: "resource"
        case .group: "group"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    fileprivate static func describe(_ status: EKEventStatus) -> String {
        // Apple's own header warns that only `canceled` is dependable, so the
        // rest are reported as what EventKit said rather than relied on.
        switch status {
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .canceled: "canceled"
        case .none: "none"
        @unknown default: "unknown"
        }
    }

    fileprivate static func describe(_ role: EKParticipantRole) -> String {
        switch role {
        case .required: "required"
        case .optional: "optional"
        case .chair: "chair"
        case .nonParticipant: "non-participant"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    fileprivate static func describe(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in-process"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}
