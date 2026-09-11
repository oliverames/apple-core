import CoreLocation
import Foundation
import OSLog
import Ontology

private let log = Logger.service("location")

final class LocationService: NSObject, Service, CLLocationManagerDelegate {
    private static let cachedLocationMaximumAge: TimeInterval = 60

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    private static func isUsableCachedLocation(_ location: CLLocation, now: Date = Date()) -> Bool {
        location.horizontalAccuracy >= 0
            && now.timeIntervalSince(location.timestamp) <= cachedLocationMaximumAge
    }

    private let locationManager = {
        let manager = CLLocationManager()
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = true
        return manager
    }()
    // Delegate callbacks and async tool handlers land on different
    // executors; unsynchronized access to either field was a genuine data
    // race, and an unchecked continuation store leaked the first caller's
    // continuation whenever two activations overlapped during a prompt.
    private let stateLock = NSLock()
    private var _latestLocation: CLLocation?
    private var latestLocation: CLLocation? {
        get { stateLock.withLock { _latestLocation } }
        set { stateLock.withLock { _latestLocation = newValue } }
    }
    private var authorizationContinuations: [CheckedContinuation<Void, Error>] = []

    /// Resolves every pending `activate()` waiter with one outcome and
    /// clears the queue.
    private func settleAuthorization(_ result: Result<Void, Error>) {
        let pending = stateLock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let pending = authorizationContinuations
            authorizationContinuations.removeAll()
            return pending
        }
        for continuation in pending {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    static let shared = LocationService()

    override init() {
        log.debug("Initializing location service")

        super.init()
        locationManager.delegate = self

        // Check authorization status first to avoid any permission prompts
        let status = locationManager.authorizationStatus
        if Self.isAuthorized(status) && CLLocationManager.locationServicesEnabled() {
            log.debug("Starting location updates with existing authorization...")
            locationManager.startUpdatingLocation()
        }
    }

    deinit {
        log.info("Deinitializing location service, stopping updates...")
        locationManager.stopUpdatingLocation()
    }

    var isActivated: Bool {
        get async {
            Self.isAuthorized(locationManager.authorizationStatus)
                && CLLocationManager.locationServicesEnabled()
        }
    }

    func activate() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateLock.withLock { authorizationContinuations.append(continuation) }
            locationManager.delegate = self

            // Check current authorization status first
            let status = locationManager.authorizationStatus
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                // Already authorized, resume immediately
                log.debug("Location access authorized")
                settleAuthorization(.success(()))
            case .denied, .restricted:
                // Already denied, throw error immediately
                log.error("Location access denied")
                settleAuthorization(
                    .failure(
                        NSError(
                            domain: "LocationServiceError",
                            code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "Location access denied"]
                        )
                    )
                )
            case .notDetermined:
                // Need to request authorization
                log.debug("Requesting location access")
                locationManager.requestWhenInUseAuthorization()
            @unknown default:
                // Handle unknown future cases
                log.error("Unknown location authorization status")
                settleAuthorization(
                    .failure(
                        NSError(
                            domain: "LocationServiceError",
                            code: 8,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Unknown authorization status"
                            ]
                        )
                    )
                )
            }
        }
    }

    var tools: [Tool] {
        Tool(
            name: "location_current",
            description:
                "Get the user's current location, with when the fix was taken, how accurate it is, and whether it came from the cached fix",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Current Location",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in
                Task {
                    let status = self.locationManager.authorizationStatus

                    guard Self.isAuthorized(status) else {
                        log.error("Location access not authorized")
                        continuation.resume(
                            throwing: NSError(
                                domain: "LocationServiceError",
                                code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Location access not authorized"
                                ]
                            )
                        )
                        return
                    }

                    // If we already have a recent location, use it
                    if let location = self.latestLocation,
                        Self.isUsableCachedLocation(location)
                    {
                        continuation.resume(
                            returning: Self.describe(location, cached: true)
                        )
                        return
                    }
                    self.latestLocation = nil

                    // Otherwise, request a new location update
                    self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                    self.locationManager.startUpdatingLocation()

                    // Modern timeout pattern using task group
                    let location = await withTaskGroup(of: CLLocation?.self) { group in
                        // Start location monitoring task
                        group.addTask {
                            while self.latestLocation == nil {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                if Task.isCancelled { return nil }
                            }
                            return self.latestLocation
                        }

                        // Start timeout task
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                            return nil
                        }

                        // Return first non-nil result or nil if timeout
                        for await result in group {
                            group.cancelAll()
                            return result
                        }

                        return nil
                    }

                    self.locationManager.stopUpdatingLocation()

                    if let location = location {
                        continuation.resume(
                            returning: Self.describe(location, cached: false)
                        )
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "LocationServiceError",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to get location"]
                            )
                        )
                    }
                }
            }
        }

        Tool(
            name: "location_geocode",
            description: "Convert an address to geographic coordinates",
            inputSchema: .object(
                properties: [
                    "address": .string(
                        description: "Address to geocode"
                    )
                ],
                required: ["address"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Geocode Address",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let address = arguments["address"]?.stringValue else {
                throw NSError(
                    domain: "LocationServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid address"]
                )
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in
                let geocoder = CLGeocoder()

                geocoder.geocodeAddressString(address) { placemarks, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let placemark = placemarks?.first, let location = placemark.location
                    else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "LocationServiceError",
                                code: 4,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "No location found for address"
                                ]
                            )
                        )
                        return
                    }

                    var result: [String: Value] = [
                        "@context": .string("https://schema.org"),
                        "@type": .string("Place"),
                        "geo": .object([
                            "@type": .string("GeoCoordinates"),
                            "latitude": .double(location.coordinate.latitude),
                            "longitude": .double(location.coordinate.longitude),
                        ]),
                    ]

                    // Add address components if available
                    if let name = placemark.name {
                        result["name"] = .string(name)
                    }

                    var addressComponents: [String: Value] = [
                        "@type": .string("PostalAddress")
                    ]

                    if let thoroughfare = placemark.thoroughfare {
                        addressComponents["streetAddress"] = .string(thoroughfare)
                    }

                    if let locality = placemark.locality {
                        addressComponents["addressLocality"] = .string(locality)
                    }

                    if let administrativeArea = placemark.administrativeArea {
                        addressComponents["addressRegion"] = .string(administrativeArea)
                    }

                    if let postalCode = placemark.postalCode {
                        addressComponents["postalCode"] = .string(postalCode)
                    }

                    if let country = placemark.country {
                        addressComponents["addressCountry"] = .string(country)
                    }

                    if addressComponents.count > 1 {  // More than just the @type
                        result["address"] = .object(addressComponents)
                    }

                    continuation.resume(returning: .object(result))
                }
            }
        }

        Tool(
            name: "location_reverse_geocode",
            description: "Convert geographic coordinates to an address",
            inputSchema: .object(
                properties: [
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                ],
                required: ["latitude", "longitude"]
            ),
            annotations: .init(
                title: "Reverse Geocode Location",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let latitude = arguments["latitude"]?.doubleCoerced,
                let longitude = arguments["longitude"]?.doubleCoerced,
                NumericArgument.validatedDouble(latitude, in: -90 ... 90) != nil,
                NumericArgument.validatedDouble(longitude, in: -180 ... 180) != nil
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "LocationServiceError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in
                let location = CLLocation(latitude: latitude, longitude: longitude)
                let geocoder = CLGeocoder()

                geocoder.reverseGeocodeLocation(location) { placemarks, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let placemark = placemarks?.first else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "LocationServiceError",
                                code: 6,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "No address found for location"
                                ]
                            )
                        )
                        return
                    }

                    var result: [String: Value] = [
                        "@context": .string("https://schema.org"),
                        "@type": .string("Place"),
                        "geo": .object([
                            "@type": .string("GeoCoordinates"),
                            "latitude": .double(latitude),
                            "longitude": .double(longitude),
                        ]),
                    ]

                    // Add address components if available
                    if let name = placemark.name {
                        result["name"] = .string(name)
                    }

                    var addressComponents: [String: Value] = [
                        "@type": .string("PostalAddress")
                    ]

                    if let thoroughfare = placemark.thoroughfare {
                        addressComponents["streetAddress"] = .string(thoroughfare)
                    }

                    if let locality = placemark.locality {
                        addressComponents["addressLocality"] = .string(locality)
                    }

                    if let administrativeArea = placemark.administrativeArea {
                        addressComponents["addressRegion"] = .string(administrativeArea)
                    }

                    if let postalCode = placemark.postalCode {
                        addressComponents["postalCode"] = .string(postalCode)
                    }

                    if let country = placemark.country {
                        addressComponents["addressCountry"] = .string(country)
                    }

                    if addressComponents.count > 1 {  // More than just the @type
                        result["address"] = .object(addressComponents)
                    }

                    continuation.resume(returning: .object(result))
                }
            }
        }

        Tool(
            name: "location_geocode_batch",
            description:
                "Turn up to \(GeocodeBatch.maximumAddresses) addresses into coordinates in one call. "
                + "Results come back in the order the addresses were given, with the index attached, and each address carries its own outcome: "
                + "one that cannot be resolved returns an error for that entry rather than failing the call. "
                + "An ambiguous address reports how many places matched and lists the alternatives instead of picking one. "
                + "The device's own location is never substituted for an address that fails.",
            inputSchema: .object(
                properties: [
                    "addresses": .array(
                        description: "Addresses to geocode, in the order you want them back",
                        items: .string()
                    )
                ],
                required: ["addresses"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Geocode Several Addresses",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let raw = arguments["addresses"]?.arrayValue else {
                throw NSError(
                    domain: "LocationServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "addresses is required"]
                )
            }
            let addresses = try GeocodeBatch.prepare(raw.compactMap(\.stringValue))

            var results: [Value] = []
            var succeeded = 0
            var failed = 0
            var ambiguous = 0
            for (index, address) in addresses.enumerated() {
                var entry: [String: Value] = [
                    "index": .int(index),
                    "address": .string(address),
                ]
                if let rejection = GeocodeBatch.rejection(for: address) {
                    entry["ok"] = .bool(false)
                    entry["error"] = .string(rejection)
                    failed += 1
                    results.append(.object(entry))
                    continue
                }
                // Sequential, spaced out. CLGeocoder is rate limited by Apple
                // and starts refusing when a batch is fired at it at once,
                // which would turn a bounded feature into a flaky one.
                if index > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(GeocodeBatch.requestInterval * 1_000_000_000)
                    )
                }
                do {
                    let placemarks = try await LocationService.geocode(address)
                    guard let first = placemarks.first, let location = first.location else {
                        entry["ok"] = .bool(false)
                        entry["error"] = .string("No location found for this address.")
                        failed += 1
                        results.append(.object(entry))
                        continue
                    }
                    succeeded += 1
                    entry["ok"] = .bool(true)
                    entry["candidateCount"] = .int(placemarks.count)
                    entry["place"] = LocationService.describe(
                        first,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                    if let note = GeocodeBatch.ambiguityNote(candidateCount: placemarks.count) {
                        ambiguous += 1
                        entry["ambiguous"] = .bool(true)
                        entry["note"] = .string(note)
                        entry["candidates"] = .array(
                            placemarks
                                .dropFirst()
                                .prefix(GeocodeBatch.maximumCandidates - 1)
                                .compactMap { placemark in
                                    guard let coordinate = placemark.location?.coordinate else {
                                        return nil
                                    }
                                    return LocationService.describe(
                                        placemark,
                                        latitude: coordinate.latitude,
                                        longitude: coordinate.longitude
                                    )
                                }
                        )
                    }
                } catch {
                    entry["ok"] = .bool(false)
                    entry["error"] = .string(error.localizedDescription)
                    failed += 1
                }
                results.append(.object(entry))
            }

            return Value.object([
                "results": .array(results),
                "requested": .int(addresses.count),
                "succeeded": .int(succeeded),
                "failed": .int(failed),
                "ambiguous": .int(ambiguous),
            ])
        }

        Tool(
            name: "location_resolve_map_url",
            description:
                "Read a shared Apple Maps link: the place, coordinates, or the trip it describes. "
                + "Apple Maps links only, on \(AppleMapsURL.allowedHosts.sorted().joined(separator: " or ")), over https. "
                + "This is not a web fetcher: an ordinary link is read offline from the link itself, and a short link is followed "
                + "at most \(AppleMapsURL.maximumRedirects) times, never off those hosts, with no page content ever read.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The Apple Maps link to read"),
                    "followShortLink": .boolean(
                        description:
                            "Follow a maps.apple.com short link to the place it points at. Requires a network request; everything else is offline.",
                        default: .bool(true)
                    ),
                ],
                required: ["url"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Apple Maps Link",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let raw = arguments["url"]?.stringValue else {
                throw NSError(
                    domain: "LocationServiceError",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "url is required"]
                )
            }
            var link = try AppleMapsURL.parse(raw)
            var resolvedFrom: String?
            if link.needsRedirect {
                guard arguments["followShortLink"]?.boolValue ?? true else {
                    throw AppleMapsURLError.noUsableParameters(raw)
                }
                let expanded = try await LocationService.expandShortLink(raw)
                link = try AppleMapsURL.parse(expanded)
                resolvedFrom = raw
            }

            var result: [String: Value] = [
                "kind": .string(link.kind.rawValue),
                "url": .string(raw),
            ]
            if let resolvedFrom {
                result["resolvedFromShortLink"] = .string(resolvedFrom)
            }
            if let latitude = link.latitude, let longitude = link.longitude {
                result["geo"] = .object([
                    "@type": .string("GeoCoordinates"),
                    "latitude": .double(latitude),
                    "longitude": .double(longitude),
                ])
            }
            if let query = link.query { result["query"] = .string(query) }
            if let address = link.address { result["address"] = .string(address) }
            if let identifier = link.placeIdentifier { result["placeIdentifier"] = .string(identifier) }
            if let origin = link.origin { result["origin"] = .string(origin) }
            if let destination = link.destination { result["destination"] = .string(destination) }
            if let transportType = link.transportType {
                result["transportType"] = .string(transportType)
            }
            result["note"] = .string(
                link.kind == .directions
                    ? "A directions link. Pass origin and destination to maps_directions for the route itself."
                    : "Read from the link. Use maps_search or location_geocode to confirm what is actually at that point."
            )
            return Value.object(result)
        }

        Tool(
            name: "location_time_zone",
            description:
                "What time it is where a place is. Give an address or a coordinate and get the time zone, "
                + "the local wall-clock time there, the offset from UTC, whether summer time is in force, "
                + "and how far ahead or behind this Mac it is. Answers the scheduling question a geocode "
                + "leaves open.",
            inputSchema: .object(
                properties: [
                    "address": .string(
                        description: "Address or place name. Use this or a latitude and longitude, not both."
                    ),
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "at": .string(
                        description:
                            "The instant to ask about, as an ISO 8601 timestamp. Defaults to now. Summer time makes the answer depend on when you ask.",
                        format: .dateTime
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Time Zone of a Place",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let address = arguments["address"]?.stringValue
            let latitude = arguments["latitude"]?.doubleCoerced
            let longitude = arguments["longitude"]?.doubleCoerced

            var instant = Date()
            if let raw = arguments["at"]?.stringValue, !raw.isEmpty {
                guard let parsed = LocationService.parseTimestamp(raw) else {
                    throw NSError(
                        domain: "LocationServiceError",
                        code: 10,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "at must be an ISO 8601 timestamp, such as 2026-09-11T14:00:00Z."
                        ]
                    )
                }
                instant = parsed
            }

            let placemark: CLPlacemark
            let resolvedCoordinate: CLLocationCoordinate2D
            if let latitude, let longitude {
                guard NumericArgument.validatedDouble(latitude, in: -90 ... 90) != nil,
                    NumericArgument.validatedDouble(longitude, in: -180 ... 180) != nil
                else {
                    throw NSError(
                        domain: "LocationServiceError",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                    )
                }
                let location = CLLocation(latitude: latitude, longitude: longitude)
                placemark = try await LocationService.firstPlacemark(reverseGeocoding: location)
                resolvedCoordinate = placemark.location?.coordinate ?? location.coordinate
            } else if let address, !address.isEmpty {
                placemark = try await LocationService.firstPlacemark(geocoding: address)
                guard let coordinate = placemark.location?.coordinate else {
                    throw NSError(
                        domain: "LocationServiceError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey: "No location found for \(address)"
                        ]
                    )
                }
                resolvedCoordinate = coordinate
            } else {
                throw NSError(
                    domain: "LocationServiceError",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Give either an address or both a latitude and a longitude."
                    ]
                )
            }

            // A placemark in the middle of an ocean has no time zone, and
            // guessing one from the longitude would be a made-up answer.
            guard let timeZone = placemark.timeZone else {
                throw NSError(
                    domain: "LocationServiceError",
                    code: 11,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "macOS reports no time zone for that point. It is probably at sea or otherwise outside any zone."
                    ]
                )
            }

            let summary = LocationTimeZone.describe(timeZone, at: instant)
            let local = TimeZone.current
            let difference = LocationTimeZone.differenceFromLocal(
                timeZone,
                localZone: local,
                at: instant
            )

            var response: [String: Value] = [
                "timeZone": .string(summary.identifier),
                "utcOffsetSeconds": .int(summary.utcOffsetSeconds),
                "utcOffset": .string(summary.utcOffsetText),
                "localTime": .string(summary.localTime),
                "isDaylightSavingTime": .bool(summary.isDaylightSavingTime),
                "daylightSavingOffsetSeconds": .int(summary.daylightSavingOffsetSeconds),
                "askedAbout": .string(ISO8601DateFormatter().string(from: instant)),
                "differenceFromThisMacSeconds": .int(difference),
                "differenceFromThisMac": .string(
                    LocationTimeZone.describeDifference(seconds: difference)
                ),
                "thisMacTimeZone": .string(local.identifier),
                "geo": .object([
                    "@type": .string("GeoCoordinates"),
                    "latitude": .double(resolvedCoordinate.latitude),
                    "longitude": .double(resolvedCoordinate.longitude),
                ]),
            ]
            if let abbreviation = summary.abbreviation {
                response["abbreviation"] = .string(abbreviation)
            }
            if let name = placemark.name { response["place"] = .string(name) }
            if let locality = placemark.locality { response["locality"] = .string(locality) }
            if let country = placemark.country { response["country"] = .string(country) }
            if let transition = summary.nextTransition {
                response["nextOffsetChange"] = .string(
                    ISO8601DateFormatter().string(from: transition)
                )
            }
            return Value.object(response)
        }
    }

    // MARK: - Shaping

    /// Parses a caller-supplied timestamp, with or without fractional
    /// seconds. `ISO8601DateFormatter` rejects whichever form it was not
    /// configured for, and a caller writing the other one should not be told
    /// their timestamp is not a timestamp.
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// The first placemark for a coordinate, as an async call.
    static func firstPlacemark(reverseGeocoding location: CLLocation) async throws -> CLPlacemark {
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw NSError(
                domain: "LocationServiceError",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "No address found for location"]
            )
        }
        return placemark
    }

    /// The first placemark for an address, as an async call.
    static func firstPlacemark(geocoding address: String) async throws -> CLPlacemark {
        let placemarks = try await CLGeocoder().geocodeAddressString(address)
        guard let placemark = placemarks.first else {
            throw NSError(
                domain: "LocationServiceError",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "No location found for \(address)"]
            )
        }
        return placemark
    }

    /// One fix, described with the freshness and precision the bare
    /// `GeoCoordinates` encoding leaves out.
    ///
    /// Every key `GeoCoordinates` used to encode is still here, spelled the
    /// same way: this adds fields beside them rather than reshaping the
    /// answer, so nothing a client already reads moves.
    static func describe(_ location: CLLocation, cached: Bool) -> Value {
        let freshness = LocationFreshness.make(
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            cached: cached
        )
        var result: [String: Value] = [
            "@context": .string("https://schema.org"),
            "@type": .string("GeoCoordinates"),
            "latitude": .double(location.coordinate.latitude),
            "longitude": .double(location.coordinate.longitude),
            "elevation": .double(location.altitude),
            "observedAt": .string(ISO8601DateFormatter().string(from: freshness.observedAt)),
            "ageSeconds": .int(freshness.ageSeconds),
            "cached": .bool(freshness.cached),
            "precision": .string(freshness.precision),
            "note": .string(freshness.note),
        ]
        if let horizontal = freshness.horizontalAccuracyMeters {
            result["horizontalAccuracyMeters"] = .double(horizontal)
        }
        if let vertical = freshness.verticalAccuracyMeters {
            result["verticalAccuracyMeters"] = .double(vertical)
        }
        return .object(result)
    }

    /// A placemark as a schema.org Place. Extracted from the two geocoding
    /// tools, which had the same twenty lines twice; the batch form would have
    /// made it three times.
    static func describe(_ placemark: CLPlacemark, latitude: Double, longitude: Double) -> Value {
        var result: [String: Value] = [
            "@context": .string("https://schema.org"),
            "@type": .string("Place"),
            "geo": .object([
                "@type": .string("GeoCoordinates"),
                "latitude": .double(latitude),
                "longitude": .double(longitude),
            ]),
        ]
        if let name = placemark.name { result["name"] = .string(name) }

        var addressComponents: [String: Value] = ["@type": .string("PostalAddress")]
        if let thoroughfare = placemark.thoroughfare {
            addressComponents["streetAddress"] = .string(thoroughfare)
        }
        if let locality = placemark.locality {
            addressComponents["addressLocality"] = .string(locality)
        }
        if let administrativeArea = placemark.administrativeArea {
            addressComponents["addressRegion"] = .string(administrativeArea)
        }
        if let postalCode = placemark.postalCode {
            addressComponents["postalCode"] = .string(postalCode)
        }
        if let country = placemark.country {
            addressComponents["addressCountry"] = .string(country)
        }
        if addressComponents.count > 1 {
            result["address"] = .object(addressComponents)
        }
        return .object(result)
    }

    /// Geocodes one address and returns every candidate the geocoder offered.
    ///
    /// Returning the candidates rather than the first one is the whole
    /// ambiguity contract: "Springfield" has a dozen answers and a batch that
    /// picked one silently would be confidently wrong twelve times out of
    /// thirteen.
    static func geocode(_ address: String) async throws -> [CLPlacemark] {
        try await withCheckedThrowingContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: placemarks ?? [])
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        log.debug("Location manager did update locations")
        if let location = locations.last(where: { Self.isUsableCachedLocation($0) }) {
            self.latestLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("Location manager failed with error: \(error.localizedDescription)")
    }

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        if Self.isAuthorized(status) {
            log.debug("Location access authorized")
            if CLLocationManager.locationServicesEnabled() {
                manager.startUpdatingLocation()
            }
            settleAuthorization(.success(()))
            return
        }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            log.error("Location access denied")
            settleAuthorization(
                .failure(
                    NSError(
                        domain: "LocationServiceError",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Location access denied"]
                    )
                )
            )
        case .notDetermined:
            log.debug("Location access not determined")
            // Wait for the user to make a choice
            break
        @unknown default:
            log.error("Unknown location authorization status")
            break
        }
    }
}

// MARK: - Apple Maps short links

/// Refuses every redirect so the caller sees each hop and can judge it.
///
/// `URLSession` follows redirects by default, which would take a maps.apple.com
/// link wherever it was pointed, including at something on the user's own
/// network. Handing the hop back instead is what makes the host check in
/// `AppleMapsURL` the thing that decides, rather than a check that runs after
/// the request already went somewhere.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension LocationService {
    /// Follows an Apple Maps short link to the URL it names, and no further.
    ///
    /// Bounded three ways: at most `AppleMapsURL.maximumRedirects` hops, every
    /// hop re-checked against the Apple Maps host list, and a HEAD request so
    /// no page body is ever fetched. A link that leaves those hosts is
    /// abandoned with an error naming where it tried to go.
    static func expandShortLink(_ raw: String) async throws -> String {
        var current = try AppleMapsURL.validate(raw)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        for hop in 1 ... AppleMapsURL.maximumRedirects {
            guard let url = current.url else { throw AppleMapsURLError.notAURL(raw) }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppleMapsURLError.noUsableParameters(raw)
            }
            guard (300 ... 399).contains(http.statusCode),
                let location = http.value(forHTTPHeaderField: "Location"),
                let next = URL(string: location, relativeTo: url)
            else {
                // No redirect left to follow: this is where the link lands.
                return url.absoluteString
            }
            try AppleMapsURL.checkRedirect(to: next.absoluteURL, hop: hop)
            current = try AppleMapsURL.validate(next.absoluteURL.absoluteString)
        }
        throw AppleMapsURLError.tooManyRedirects(limit: AppleMapsURL.maximumRedirects)
    }
}
