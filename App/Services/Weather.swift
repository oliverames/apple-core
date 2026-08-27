import CoreLocation
import Foundation
import OSLog
import Ontology
import WeatherKit

private let log = Logger.service("weather")

final class WeatherService: Service {
    static let shared = WeatherService()

    private let weatherService = WeatherKit.WeatherService.shared

    private static func location(from arguments: [String: Value]) throws -> CLLocation {
        guard let requestedLatitude = arguments["latitude"]?.doubleCoerced,
            let requestedLongitude = arguments["longitude"]?.doubleCoerced,
            let latitude = NumericArgument.validatedDouble(requestedLatitude, in: -90 ... 90),
            let longitude = NumericArgument.validatedDouble(requestedLongitude, in: -180 ... 180)
        else {
            log.error("Invalid coordinates")
            throw NSError(
                domain: "WeatherServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Latitude must be -90 through 90 and longitude -180 through 180"]
            )
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    var tools: [Tool] {
        Tool(
            name: "weather_current",
            description:
                "Get current weather for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Current Weather",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(from: arguments)
            let currentWeather = try await self.weatherService.weather(
                for: location,
                including: .current
            )

            return WeatherConditions(currentWeather)
        }

        Tool(
            name: "weather_daily",
            description: "Get daily weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "days": .integer(
                        description: "Number of forecast days (max 10)",
                        default: 7,
                        minimum: 1,
                        maximum: 10
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Daily Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let days: Int
            switch arguments["days"] {
            case let .int(daysRequested):
                days = NumericArgument.clampedInt(daysRequested, to: 1 ... 10)
            case let .double(daysRequested):
                days = NumericArgument.clampedInt(daysRequested, to: 1 ... 10) ?? 7
            default:
                days = 7
            }

            let location = try Self.location(from: arguments)
            let dailyForecast = try await self.weatherService.weather(
                for: location,
                including: .daily
            )

            return dailyForecast.prefix(days).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_hourly",
            description: "Get hourly weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "hours": .integer(
                        description: "Number of hours to forecast",
                        default: 24,
                        minimum: 1,
                        maximum: 240
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Hourly Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let hours: Int
            switch arguments["hours"] {
            case let .int(hoursRequested):
                hours = NumericArgument.clampedInt(hoursRequested, to: 1 ... 240)
            case let .double(hoursRequested):
                hours = NumericArgument.clampedInt(hoursRequested, to: 1 ... 240) ?? 24
            default:
                hours = 24
            }

            let location = try Self.location(from: arguments)
            let hourlyForecasts = try await self.weatherService.weather(
                for: location,
                including: .hourly
            )

            return hourlyForecasts.prefix(hours).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_minute",
            description: "Get minute-by-minute weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "minutes": .integer(
                        description: "Number of minutes to forecast",
                        default: 60,
                        minimum: 1,
                        maximum: 120
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Minute-by-Minute Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let minutes: Int
            switch arguments["minutes"] {
            case let .int(minutesRequested):
                minutes = NumericArgument.clampedInt(minutesRequested, to: 1 ... 120)
            case let .double(minutesRequested):
                minutes = NumericArgument.clampedInt(minutesRequested, to: 1 ... 120) ?? 60
            default:
                minutes = 60
            }

            let location = try Self.location(from: arguments)
            guard
                let minuteByMinuteForecast = try await self.weatherService.weather(
                    for: location,
                    including: .minute
                )
            else {
                throw NSError(
                    domain: "WeatherServiceError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No minute-by-minute forecast available"]
                )
            }

            return minuteByMinuteForecast.prefix(minutes).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_alerts",
            description:
                "Get the severe weather alerts in force for a location, such as storm, flood or heat warnings. "
                + "Returns an empty list when there are none.",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Weather Alerts",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(from: arguments)
            // Alerts are nil where the region has no alerting authority, which
            // is not the same as "no alerts" and should not read as an error.
            let alerts = try await self.weatherService.weather(for: location, including: .alerts)
            guard let alerts else {
                return Value.object([
                    "alerts": .array([]),
                    "note": .string("No alerting authority covers this location."),
                ])
            }

            let described: [Value] = alerts.map { alert in
                var entry: [String: Value] = [
                    "summary": .string(alert.summary),
                    "severity": .string(String(describing: alert.severity)),
                    "source": .string(alert.source),
                    "detailsURL": .string(alert.detailsURL.absoluteString),
                ]
                if let region = alert.region { entry["region"] = .string(region) }
                return .object(entry)
            }
            return Value.object(["alerts": .array(described)])
        }

        Tool(
            name: "weather_history",
            description:
                "Get the daily weather that was recorded for a location between two dates. Use this for past weather, "
                + "not for the forecast.",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "startDate": .string(description: "First day, as an ISO 8601 date"),
                    "endDate": .string(description: "Last day, as an ISO 8601 date"),
                ],
                required: ["latitude", "longitude", "startDate", "endDate"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Past Weather",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(from: arguments)
            guard let rawStart = arguments["startDate"]?.stringValue,
                let rawEnd = arguments["endDate"]?.stringValue
            else {
                throw NSError(
                    domain: "WeatherServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "startDate and endDate are required"]
                )
            }
            let start = try WeatherService.parseDate(rawStart, named: "startDate")
            let end = try WeatherService.parseDate(rawEnd, named: "endDate")
            guard start < end else {
                throw NSError(
                    domain: "WeatherServiceError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "startDate must come before endDate."]
                )
            }

            let history = try await self.weatherService.weather(
                for: location,
                including: .daily(startDate: start, endDate: end)
            )
            return history.map { WeatherForecast($0) }
        }
    }

    /// Accepts a bare day as well as a full timestamp: a question about past
    /// weather is nearly always asked in whole days.
    static func parseDate(_ raw: String, named argument: String) throws -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }

        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let date = dayOnly.date(from: raw) { return date }

        throw NSError(
            domain: "WeatherServiceError",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(argument) must be an ISO 8601 date, such as 2026-08-18."
            ]
        )
    }
}
