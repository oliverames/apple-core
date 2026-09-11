import AppKit
import Foundation
import JSONSchema
import MapKit
import OSLog
import Ontology

private let log = Logger.service("maps")

private let defaultSearchRadius: CLLocationDistance = 5000  // Default 5km
private let defaultPointOfInterestRadius = min(defaultSearchRadius, MKLocalPointsOfInterestRequest.maxRadius)
private let defaultSearchLimit: Int = 10
private let defaultMapImageSize: CGSize = CGSize(width: 1024, height: 1024)
private let maximumMapImageDimension = 4096

final class MapsService: NSObject, Service {
    static let shared = MapsService()

    override init() {
        log.debug("Initializing maps service")
        super.init()
    }

    var isActivated: Bool {
        get async {
            // MapKit doesn't require explicit permission, but we rely on location
            return await LocationService.shared.isActivated
        }
    }

    func activate() async throws {
        log.debug("Activating maps service")
        // Maps service depends on location service being active
        try await LocationService.shared.activate()
    }

    var tools: [Tool] {
        Tool(
            name: "maps_search",
            description: "Search for places, addresses, points of interest by text query",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Search text (place name, address, etc.)"
                    ),
                    "region": .object(
                        description: "Region to bias search results",
                        properties: [
                            "latitude": .number(minimum: -90, maximum: 90),
                            "longitude": .number(minimum: -180, maximum: 180),
                            "radius": .number(
                                description: "Search radius in meters",
                                default: .double(defaultSearchRadius),
                                exclusiveMinimum: 0
                            ),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Places",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let query = arguments["query"]?.stringValue else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Search query is required"]
                )
            }

            // Set up search request
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query

            // Configure region if provided
            if let suppliedRegion = arguments["region"] {
                guard let regionArg = suppliedRegion.objectValue else {
                    throw Self.invalidGeometry("region must contain latitude and longitude.")
                }
                let center = try Self.coordinate(from: regionArg)
                let radius = regionArg["radius"]?.doubleCoerced ?? defaultSearchRadius
                guard radius.isFinite, radius > 0 else {
                    throw Self.invalidGeometry("radius must be a positive, finite number of meters.")
                }
                let region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )
                try Self.validate(span: region.span)
                searchRequest.region = region
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Place], Error>) in

                let search = MKLocalSearch(request: searchRequest)
                search.start { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "No search results"]
                            )
                        )
                        return
                    }

                    // Convert MKMapItems to Ontology Place objects
                    let places = response.mapItems.map { item -> Place in
                        return Self.place(item)
                    }

                    continuation.resume(returning: places)
                }
            }
        }

        Tool(
            name: "maps_place_details",
            description: """
                Look up a place again by its Apple Maps place identifier and return its current \
                details. The identifier is the "@id" value on any result from maps_search or \
                maps_explore. Returns the place's name, address, coordinates, telephone, URL, \
                point of interest category and time zone when Apple Maps supplies them, and names \
                the ones it does not in "unavailableFields" rather than returning empty values. \
                Apple's public MapKit API supplies no reviews, opening hours or accessibility \
                information, so this tool never returns them. An identifier stops resolving once \
                Apple Maps drops the place, which is reported as an error rather than an empty \
                result.
                """,
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Apple Maps place identifier, the \"@id\" of a maps_search or maps_explore result"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Place Details",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let requested = try MapsPlaceIdentifier.normalized(arguments["identifier"]?.stringValue)
            guard let identifier = MKMapItem.Identifier(rawValue: requested) else {
                throw MapsPlaceLookupError.malformedIdentifier(requested)
            }

            let item: MKMapItem
            do {
                item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
            } catch {
                log.debug("Place identifier did not resolve: \(error.localizedDescription)")
                throw MapsPlaceLookupError.unresolvedIdentifier(requested)
            }

            let place = Self.place(item)
            let summary = MapsPlaceLookupSummary(
                requestedIdentifier: requested,
                resolvedIdentifier: item.identifier?.rawValue,
                alternateIdentifiers: item.alternateIdentifiers.map(\.rawValue),
                pointOfInterestCategory: item.pointOfInterestCategory?.rawValue,
                timeZoneIdentifier: item.timeZone?.identifier,
                hasName: place.name?.isEmpty == false,
                hasAddress: place.address != nil,
                hasCoordinates: place.geo != nil,
                hasTelephone: place.telephone?.isEmpty == false,
                hasURL: place.url != nil
            )
            return PlaceDetails(place: place, lookup: summary)
        }

        Tool(
            name: "maps_directions",
            description: "Get directions between two locations with optional transport type",
            inputSchema: .object(
                properties: [
                    "originAddress": .string(
                        description: "Origin address"
                    ),
                    "originCoordinates": .object(
                        description: "Origin coordinates",
                        properties: [
                            "latitude": .number(minimum: -90, maximum: 90),
                            "longitude": .number(minimum: -180, maximum: 180),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                    "destinationAddress": .string(
                        description: "Destination address"
                    ),
                    "destinationCoordinates": .object(
                        description: "Destination coordinates",
                        properties: [
                            "latitude": .number(minimum: -90, maximum: 90),
                            "longitude": .number(minimum: -180, maximum: 180),
                        ],
                        required: ["latitude", "longitude"],
                        additionalProperties: false
                    ),
                    "transportType": .string(
                        description:
                            "Transport type. \"transit\" returns no steps: Apple Maps supplies transit travel "
                            + "time only, so use maps_eta for that trip. \"any\" lets MapKit choose and in "
                            + "practice returns driving routes.",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit", "any"]
                    ),
                    "departureDate": .string(
                        description:
                            "When the trip starts, as an ISO 8601 date and time. Transit directions depend on this."
                    ),
                    "arrivalDate": .string(
                        description:
                            "When the trip must end, as an ISO 8601 date and time. Cannot be combined with departureDate."
                    ),
                    "alternates": .boolean(
                        description: "Return alternative routes as well as the fastest one",
                        default: true
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Directions",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            // Need either origin address or coordinates
            guard
                arguments["originAddress"]?.stringValue != nil
                    || (arguments["originCoordinates"]?.objectValue?["latitude"]?.doubleCoerced != nil
                        && arguments["originCoordinates"]?.objectValue?["longitude"]?.doubleCoerced
                            != nil)
            else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Origin address or coordinates required"]
                )
            }

            // Need either destination address or coordinates
            guard
                arguments["destinationAddress"]?.stringValue != nil
                    || (arguments["destinationCoordinates"]?.objectValue?["latitude"]?.doubleCoerced
                        != nil
                        && arguments["destinationCoordinates"]?.objectValue?["longitude"]?
                            .doubleCoerced != nil)
            else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Destination address or coordinates required"
                    ]
                )
            }

            // Get origin and destination
            let originItem = try await self.getMapItem(
                address: arguments["originAddress"]?.stringValue,
                coordinates: arguments["originCoordinates"]?.objectValue
            )

            let destinationItem = try await self.getMapItem(
                address: arguments["destinationAddress"]?.stringValue,
                coordinates: arguments["destinationCoordinates"]?.objectValue
            )

            // Set up directions request
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = originItem
            directionsRequest.destination = destinationItem

            // Set transport type
            let requestedTransportType = arguments["transportType"]?.stringValue
            switch requestedTransportType {
            case nil, "automobile":
                directionsRequest.transportType = .automobile
            case "walking":
                directionsRequest.transportType = .walking
            case "transit":
                directionsRequest.transportType = .transit
            case "any":
                directionsRequest.transportType = .any
            default:
                throw NSError(
                    domain: "MapsServiceError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown transport type."]
                )
            }

            // Without a date, transit directions are calculated against "now",
            // which is the wrong answer for any question about a trip later
            // today. MapKit accepts one anchor or the other, never both.
            let departure = arguments["departureDate"]?.stringValue
            let arrival = arguments["arrivalDate"]?.stringValue
            if departure != nil, arrival != nil {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Give either departureDate or arrivalDate, not both."
                    ]
                )
            }
            if let departure {
                directionsRequest.departureDate = try MapsService.parseDate(departure, named: "departureDate")
            }
            if let arrival {
                directionsRequest.arrivalDate = try MapsService.parseDate(arrival, named: "arrivalDate")
            }

            directionsRequest.requestsAlternateRoutes = arguments["alternates"]?.boolValue ?? true

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let directions = MKDirections(request: directionsRequest)
                directions.calculate { response, error in
                    if let error = error {
                        // MapKit advertises a transit transport type that
                        // calculate() cannot serve, and reports it as an
                        // opaque directionsNotFound. Say what is actually
                        // available instead of passing that through.
                        let nsError = error as NSError
                        if let message = MapsTransitDirections.message(
                            forTransportType: requestedTransportType,
                            errorDomain: nsError.domain,
                            errorCode: nsError.code
                        ) {
                            continuation.resume(
                                throwing: NSError(
                                    domain: "MapsServiceError",
                                    code: 17,
                                    userInfo: [NSLocalizedDescriptionKey: message]
                                )
                            )
                            return
                        }
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response, !response.routes.isEmpty else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 5,
                                userInfo: [NSLocalizedDescriptionKey: "No routes found"]
                            )
                        )
                        return
                    }

                    continuation.resume(returning: MapsService.describe(response))
                }
            }
        }

        Tool(
            name: "maps_explore",
            description: "Find points of interest near a location",
            inputSchema: .object(
                properties: [
                    "category": .string(
                        description: "POI category",
                        enum: MKPointOfInterestCategory.allCases.map { .string($0.stringValue) }
                    ),
                    "latitude": .number(minimum: -90, maximum: 90),
                    "longitude": .number(minimum: -180, maximum: 180),
                    "radius": .number(
                        description: "Search radius in meters",
                        default: .double(defaultPointOfInterestRadius),
                        maximum: MKLocalPointsOfInterestRequest.maxRadius,
                        exclusiveMinimum: 0
                    ),
                    "limit": .integer(
                        description: "Maximum results to return",
                        default: .int(defaultSearchLimit)
                    ),
                ],
                required: ["category", "latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Find Nearby Points of Interest",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let categoryString = arguments["category"]?.stringValue
            else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Category and coordinates are required"]
                )
            }

            let center = try Self.coordinate(from: arguments)
            let radius = arguments["radius"]?.doubleCoerced ?? defaultPointOfInterestRadius
            guard radius.isFinite, radius > 0, radius <= MKLocalPointsOfInterestRequest.maxRadius else {
                throw Self.invalidGeometry(
                    "radius must be greater than zero and at most \(MKLocalPointsOfInterestRequest.maxRadius) meters."
                )
            }
            // Clamp for consistency with the other surfaces; MapKit's own
            // result ceiling bounds this in practice, but the schema makes
            // no promise and an unclamped value is a footgun.
            let limit = min(max(arguments["limit"]?.intValue ?? defaultSearchLimit, 1), 50)

            guard let category = MKPointOfInterestCategory.from(string: categoryString) else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid POI category"]
                )
            }

            // Create search request
            let request = MKLocalPointsOfInterestRequest(
                center: center,
                radius: radius
            )
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Place], Error>) in

                let search = MKLocalSearch(request: request)
                search.start { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 8,
                                userInfo: [NSLocalizedDescriptionKey: "No POI results found"]
                            )
                        )
                        return
                    }

                    // Convert MKMapItems to Value objects
                    let places = response.mapItems.prefix(limit).map { item -> Place in
                        return Self.place(item)
                    }

                    continuation.resume(returning: places)
                }
            }
        }

        Tool(
            name: "maps_eta",
            description: "Calculate estimated travel time between two locations",
            inputSchema: .object(
                properties: [
                    "originLatitude": .number(minimum: -90, maximum: 90),
                    "originLongitude": .number(minimum: -180, maximum: 180),
                    "destinationLatitude": .number(minimum: -90, maximum: 90),
                    "destinationLongitude": .number(minimum: -180, maximum: 180),
                    "transportType": .string(
                        description: "Transport type",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit"]
                    ),
                ],
                required: [
                    "originLatitude", "originLongitude", "destinationLatitude",
                    "destinationLongitude",
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Estimated Travel Time",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let originLat = arguments["originLatitude"]?.doubleCoerced,
                let originLng = arguments["originLongitude"]?.doubleCoerced,
                let destLat = arguments["destinationLatitude"]?.doubleCoerced,
                let destLng = arguments["destinationLongitude"]?.doubleCoerced
            else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Origin and destination coordinates required"
                    ]
                )
            }

            let origin = try Self.coordinate(latitude: originLat, longitude: originLng)
            let destination = try Self.coordinate(latitude: destLat, longitude: destLng)
            // Create origin and destination placemarks
            let originPlacemark = MKPlacemark(
                coordinate: origin
            )
            let destPlacemark = MKPlacemark(
                coordinate: destination
            )

            // Create map items from placemarks
            let originItem = MKMapItem(placemark: originPlacemark)
            let destinationItem = MKMapItem(placemark: destPlacemark)

            // Set up directions request
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = originItem
            directionsRequest.destination = destinationItem

            // Set transport type
            if let transportTypeStr = arguments["transportType"]?.stringValue {
                switch transportTypeStr {
                case "automobile":
                    directionsRequest.transportType = .automobile
                case "walking":
                    directionsRequest.transportType = .walking
                case "transit":
                    directionsRequest.transportType = .transit
                default:
                    directionsRequest.transportType = .automobile
                }
            } else {
                directionsRequest.transportType = .automobile
            }

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Trip, Error>) in

                let directions = MKDirections(request: directionsRequest)
                directions.calculateETA { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let response = response else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 10,
                                userInfo: [NSLocalizedDescriptionKey: "Could not calculate ETA"]
                            )
                        )
                        return
                    }

                    let trip = Trip(response)

                    continuation.resume(returning: trip)
                }
            }
        }

        Tool(
            name: "maps_route_matrix",
            description:
                "Travel time and distance for every combination of origins and destinations, in one call. "
                + "Use it to answer which of several places is closest to which, without asking for each route separately. "
                + "Bounded to \(MapsRouteMatrix.maximumPairs) pairs, because a matrix is the product of the two lists. "
                + "Each route reports its own status, so one route that cannot be computed does not lose the others.",
            inputSchema: .object(
                properties: [
                    "origins": .array(
                        description: "Starting points, each an address or a latitude and longitude",
                        items: MapsService.pointSchema
                    ),
                    "destinations": .array(
                        description: "End points, each an address or a latitude and longitude",
                        items: MapsService.pointSchema
                    ),
                    "transportType": .string(
                        description:
                            "Transport type. Transit times depend on departureDate and are unavailable in many places.",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit"]
                    ),
                    "departureDate": .string(
                        description: "When the trips start, as an ISO 8601 date and time"
                    ),
                ],
                required: ["origins", "destinations"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Route Matrix",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let origins = try MapsService.points(from: arguments["origins"], named: "origins")
            let destinations = try MapsService.points(
                from: arguments["destinations"],
                named: "destinations"
            )
            let pairs = try MapsRouteMatrix.pairs(
                originCount: origins.count,
                destinationCount: destinations.count
            )
            let transportType = try MapsService.transportType(
                arguments["transportType"]?.stringValue
            )
            let departure = try arguments["departureDate"]?.stringValue.map {
                try MapsService.parseDate($0, named: "departureDate")
            }

            let originItems = try await MapsService.resolve(origins)
            let destinationItems = try await MapsService.resolve(destinations)

            // Bounded concurrency. MapKit routing is a rate-limited network
            // service, and firing twenty-five requests at once is the reliable
            // way to have it answer none of them.
            var outcomes: [MapsRouteOutcome] = []
            for chunk in stride(from: 0, to: pairs.count, by: MapsRouteMatrix.maximumConcurrency) {
                let slice = pairs[chunk ..< min(chunk + MapsRouteMatrix.maximumConcurrency, pairs.count)]
                await withTaskGroup(of: MapsRouteOutcome.self) { group in
                    for pair in slice {
                        group.addTask {
                            await MapsService.travel(
                                from: originItems[pair.origin],
                                to: destinationItems[pair.destination],
                                transportType: transportType,
                                departure: departure,
                                originIndex: pair.origin,
                                destinationIndex: pair.destination
                            )
                        }
                    }
                    for await outcome in group { outcomes.append(outcome) }
                }
            }
            let ordered = MapsRouteMatrix.ordered(outcomes)

            let nearest = MapsRouteMatrix.nearestByTravelTime(ordered, originCount: origins.count)
            return Value.object([
                "transportType": .string(arguments["transportType"]?.stringValue ?? "automobile"),
                "origins": .array(origins.map { .string($0.label) }),
                "destinations": .array(destinations.map { .string($0.label) }),
                "routes": .array(ordered.map { MapsService.describe($0) }),
                "computed": .int(ordered.filter(\.ok).count),
                "failed": .int(ordered.filter { !$0.ok }.count),
                "nearestDestinationByTravelTime": .array(
                    nearest.map { $0.map { .int($0) } ?? .null }
                ),
            ])
        }

        Tool(
            name: "maps_itinerary",
            description:
                "Travel time and distance for a trip through a list of stops, in the order given, with the totals for the whole trip. "
                + "Stops are never reordered: optimising the order is a different question that needs its own algorithm and its own statement of the traffic it assumed. "
                + "Up to \(MapsItinerary.maximumStops) stops.",
            inputSchema: .object(
                properties: [
                    "stops": .array(
                        description:
                            "Stops in the order they will be visited, each an address or a latitude and longitude",
                        items: MapsService.pointSchema
                    ),
                    "transportType": .string(
                        description: "Transport type",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit"]
                    ),
                    "departureDate": .string(
                        description:
                            "When the trip starts, as an ISO 8601 date and time. Given one, each stop reports an arrival time."
                    ),
                    "dwellMinutes": .integer(
                        description: "How long the trip stays at each stop, for the arrival times",
                        default: .int(0)
                    ),
                ],
                required: ["stops"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Multi-Stop Itinerary",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let stops = try MapsService.points(from: arguments["stops"], named: "stops")
            let legs = try MapsItinerary.legs(stopCount: stops.count)
            let transportType = try MapsService.transportType(
                arguments["transportType"]?.stringValue
            )
            let departure = try arguments["departureDate"]?.stringValue.map {
                try MapsService.parseDate($0, named: "departureDate")
            }
            let items = try await MapsService.resolve(stops)

            // Sequential, in order. The legs are a chain, and the arrival
            // times below depend on each one landing in place.
            var outcomes: [MapsRouteOutcome] = []
            for leg in legs {
                outcomes.append(
                    await MapsService.travel(
                        from: items[leg.from],
                        to: items[leg.to],
                        transportType: transportType,
                        departure: departure,
                        originIndex: leg.from,
                        destinationIndex: leg.to
                    )
                )
            }
            let totals = MapsItinerary.totals(outcomes)

            var described: [Value] = []
            let arrivals = departure.map {
                MapsItinerary.arrivals(
                    departingAt: $0,
                    outcomes: outcomes,
                    dwellSeconds: (arguments["dwellMinutes"]?.intValue ?? 0) * 60
                )
            }
            let formatter = ISO8601DateFormatter()
            for (index, outcome) in outcomes.enumerated() {
                guard case .object(var entry) = MapsService.describe(outcome) else { continue }
                entry["from"] = .string(stops[outcome.originIndex].label)
                entry["to"] = .string(stops[outcome.destinationIndex].label)
                if let arrival = arrivals?[index] ?? nil {
                    entry["arrivesAt"] = .string(formatter.string(from: arrival))
                }
                described.append(.object(entry))
            }

            var totalsValue: [String: Value] = [
                "distanceMeters": .int(totals.distanceMeters),
                "travelSeconds": .int(totals.travelSeconds),
                "legCount": .int(totals.legCount),
                "computedLegCount": .int(totals.computedLegCount),
                "failedLegCount": .int(totals.failedLegCount),
                "partial": .bool(totals.isPartial),
            ]
            if totals.isPartial {
                totalsValue["note"] = .string(
                    "\(totals.failedLegCount) leg\(totals.failedLegCount == 1 ? "" : "s") could not be routed, so these totals are a floor, not the trip. Check the legs for which."
                )
            }
            return Value.object([
                "totals": .object(totalsValue),
                "stops": .array(stops.map { .string($0.label) }),
                "transportType": .string(arguments["transportType"]?.stringValue ?? "automobile"),
                "legs": .array(described),
            ])
        }

        Tool(
            name: "maps_search_along_route",
            description: MapsService.searchAlongRouteDescription,
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "What to look for, such as \"coffee\", \"petrol\" or \"pharmacy\""
                    ),
                    "origin": MapsService.pointSchema,
                    "destination": MapsService.pointSchema,
                    "transportType": .string(
                        description: "How the trip is made",
                        default: "automobile",
                        enum: ["automobile", "walking", "transit"]
                    ),
                    "maxDetourMeters": .integer(
                        description:
                            "How far off the route a place may be and still count, in metres",
                        default: .int(2000),
                        minimum: 100,
                        maximum: 20000
                    ),
                    "maxResults": .integer(
                        description: "How many places to return, in route order",
                        default: .int(10),
                        minimum: 1,
                        maximum: 25
                    ),
                    "maxSamples": .integer(
                        description:
                            "How many points along the route to search around, up to \(RouteSampling.maximumMaxSamples)",
                        default: .int(RouteSampling.defaultMaxSamples),
                        minimum: 1,
                        maximum: RouteSampling.maximumMaxSamples
                    ),
                ],
                required: ["query", "origin", "destination"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Along a Route",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await MapsService.searchAlongRoute(arguments)
        }

        Tool(
            name: "maps_generate",
            description:
                "Generate a map image. Give it places — addresses or coordinates — and it frames them all and "
                + "marks each one; or give it a centre and a span to control the view exactly.",
            inputSchema: .object(
                properties: [
                    "points": .array(
                        description:
                            "Places to frame and mark, by address or coordinate. The map is centred and zoomed to fit "
                            + "all of them, and each is drawn as a numbered marker. Up to \(MapSnapshotFraming.maximumPoints). "
                            + "Use this instead of working out a centre and a span by hand.",
                        items: MapsService.pointSchema,
                        maxItems: MapSnapshotFraming.maximumPoints
                    ),
                    "latitude": .number(
                        description: "Centre of the map. Not needed when points are given.",
                        minimum: -90,
                        maximum: 90
                    ),
                    "longitude": .number(
                        description: "Centre of the map. Not needed when points are given.",
                        minimum: -180,
                        maximum: 180
                    ),
                    "latitudeDelta": .number(
                        description:
                            "Latitude degrees visible on map. Worked out from points when left out.",
                        minimum: 0,
                        maximum: 180
                    ),
                    "longitudeDelta": .number(
                        description:
                            "Longitude degrees visible on map. Worked out from points when left out.",
                        minimum: 0,
                        maximum: 360
                    ),
                    "width": .integer(
                        description: "Image width in pixels",
                        default: .int(Int(defaultMapImageSize.width)),
                        minimum: 1,
                        maximum: maximumMapImageDimension
                    ),
                    "height": .integer(
                        description: "Image height in pixels",
                        default: .int(Int(defaultMapImageSize.height)),
                        minimum: 1,
                        maximum: maximumMapImageDimension
                    ),
                    "mapType": .string(
                        description: "Map type",
                        default: "standard",
                        enum: ["standard", "satellite", "hybrid", "mutedStandard"]
                    ),
                    "showPointsOfInterest": .oneOf(
                        [
                            .boolean(
                                description: "Show all (true) or no (false) POIs",
                                default: false
                            ),
                            .array(
                                description: "Specific POI types to show",
                                items: .anyOf(
                                    MKPointOfInterestCategory.allCases.map {
                                        .string(const: .string($0.stringValue))
                                    }
                                ),
                                minItems: 1
                            ),
                        ]
                    ),
                    "showBuildings": .boolean(
                        description: "Whether to show buildings",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Generate Map Image",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let framed = try await MapsService.frame(arguments)

            let width = arguments["width"]?.intValue ?? Int(defaultMapImageSize.width)
            let height = arguments["height"]?.intValue ?? Int(defaultMapImageSize.height)
            guard (1 ... maximumMapImageDimension).contains(width),
                (1 ... maximumMapImageDimension).contains(height)
            else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Map width and height must each be between 1 and \(maximumMapImageDimension) pixels."
                    ]
                )
            }
            let mapTypeString = arguments["mapType"]?.stringValue ?? "standard"

            let options = MKMapSnapshotter.Options()
            try Self.validate(span: framed.region.span)
            options.region = framed.region

            switch mapTypeString {
            case "satellite":
                options.mapType = .satellite
            case "hybrid":
                options.mapType = .hybrid
            case "mutedStandard":
                options.mapType = .mutedStandard
            default:
                options.mapType = .standard
            }

            options.size = CGSize(width: width, height: height)

            let filter: MKPointOfInterestFilter
            switch arguments["showPointsOfInterest"] {
            case .bool(true), .string("true"):
                filter = .includingAll
            case .bool(false), .string("false"):
                filter = .excludingAll
            case let .string(string):
                do {
                    let jsonData = string.data(using: .utf8)!
                    let poiStrings = try JSONDecoder().decode([String].self, from: jsonData)
                    let categories = poiStrings.compactMap {
                        MKPointOfInterestCategory.from(string: $0)
                    }
                    filter = categories.isEmpty ? .excludingAll : .init(including: categories)
                } catch {
                    filter = .excludingAll
                }
            case let .array(poiTypes):
                let categories = poiTypes.compactMap { $0.stringValue }.compactMap {
                    MKPointOfInterestCategory.from(string: $0)
                }
                filter = categories.isEmpty ? .excludingAll : .init(including: categories)
            default:
                filter = .excludingAll
            }
            options.pointOfInterestFilter = filter

            options.showsBuildings = arguments["showBuildings"]?.boolValue == true

            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in

                let snapshotter = MKMapSnapshotter(options: options)
                snapshotter.start { snapshot, error in
                    if let error = error {
                        log.error("Map snapshot failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let snapshot = snapshot else {
                        log.error("Map snapshot failed: No snapshot data")
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 14,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Failed to generate map snapshot"
                                ]
                            )
                        )
                        return
                    }

                    // Get image representation (e.g., PNG)
                    let rendered = MapsService.annotated(
                        snapshot,
                        region: framed.region,
                        markers: framed.markers
                    )
                    guard let imageData = rendered.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: imageData),
                        let pngData = bitmap.representation(using: .png, properties: [:])
                    else {
                        log.error("Map snapshot failed: Could not convert image to PNG")
                        continuation.resume(
                            throwing: NSError(
                                domain: "MapsServiceError",
                                code: 15,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Failed to convert snapshot to PNG format"
                                ]
                            )
                        )
                        return
                    }

                    continuation.resume(
                        returning: .data(mimeType: "image/png", pngData)
                    )
                }
            }
        }
    }

    // MARK: - Place identity

    /// The schema.org `Place` already carries an `identifier`, encoded as
    /// `@id`, but `Place(MKMapItem)` never fills it in, so every place this
    /// service returned used to be anonymous. Filling the existing field is
    /// what makes a result addressable later; adding a second identifier field
    /// under a new name would have given clients two ways to say the same
    /// thing.
    static func place(_ item: MKMapItem) -> Place {
        var place = Place(item)
        place.identifier = item.identifier?.rawValue
        return place
    }

    /// Everything a detail lookup returns: the place itself, and the identity
    /// and MapKit-only attributes that `Place` has nowhere to put.
    struct PlaceDetails: Codable, Sendable {
        var place: Place
        var lookup: MapsPlaceLookupSummary
    }

    // MARK: - Searching along a route

    static let searchAlongRouteDescription =
        "Find places along the way between two points, not just near one of them: coffee on the drive, "
        + "a pharmacy on the walk home. Routes the trip, searches around points spread evenly along it, "
        + "and reports how far off the route each place is and how far along the trip it comes. "
        + "The detour distance is straight-line to the route, not a second routing call."

    static func searchAlongRoute(_ arguments: [String: Value]) async throws -> Value {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw invalidGeometry("query is required: say what to look for along the way.")
        }
        let origin = try Self.point(arguments["origin"], named: "origin")
        let destination = try Self.point(arguments["destination"], named: "destination")
        let transportType = try Self.transportType(arguments["transportType"]?.stringValue)
        let maxDetour = Double(arguments["maxDetourMeters"]?.intValue ?? 2000)
        let maxResults = min(25, max(1, arguments["maxResults"]?.intValue ?? 10))
        let maxSamples = RouteSampling.clampedSamples(arguments["maxSamples"]?.intValue)

        let items = try await Self.resolve([origin, destination])
        let request = MKDirections.Request()
        request.source = items[0]
        request.destination = items[1]
        request.transportType = transportType
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw NSError(
                domain: "MapsServiceError",
                code: 16,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No route between those two points, so there is nothing to search along."
                ]
            )
        }

        let polyline = Self.coordinates(of: route.polyline)
        let samples = RouteSampling.samples(along: polyline, maximum: maxSamples)
        guard !samples.isEmpty else {
            throw NSError(
                domain: "MapsServiceError",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "The route has no shape to search along."]
            )
        }

        // Searched one sample at a time. MKLocalSearch is a rate-limited
        // network service, and a burst of twenty searches is the reliable way
        // to have it answer none of them.
        var found: [String: (item: MKMapItem, offset: Double, along: Double)] = [:]
        var searchesFailed = 0
        for sample in samples {
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query
            searchRequest.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: sample.coordinate.latitude,
                    longitude: sample.coordinate.longitude
                ),
                latitudinalMeters: maxDetour * 2,
                longitudinalMeters: maxDetour * 2
            )
            guard let results = try? await MKLocalSearch(request: searchRequest).start() else {
                searchesFailed += 1
                continue
            }
            for item in results.mapItems {
                let coordinate = item.placemark.coordinate
                guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { continue }
                guard
                    let nearest = RouteSampling.nearestPoint(
                        to: RouteCoordinate(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        ),
                        on: polyline
                    ), nearest.distanceFromRoute <= maxDetour
                else { continue }
                // Searching overlapping circles returns the same place more
                // than once. Identity first, then name and position, because a
                // place without an identifier still must not appear twice.
                let key =
                    item.identifier?.rawValue
                    ?? "\(item.name ?? "")|\(Int(coordinate.latitude * 10000))|\(Int(coordinate.longitude * 10000))"
                if let existing = found[key], existing.offset <= nearest.distanceFromRoute {
                    continue
                }
                found[key] = (item, nearest.distanceFromRoute, nearest.distanceAlongRoute)
            }
        }

        let routeLength = RouteSampling.length(of: polyline)
        let ordered = found.values
            .sorted { left, right in
                if left.along != right.along { return left.along < right.along }
                return (left.item.name ?? "") < (right.item.name ?? "")
            }
            .prefix(maxResults)

        let places: [Value] = ordered.map { entry in
            let coordinate = entry.item.placemark.coordinate
            var described: [String: Value] = [
                "name": .string(entry.item.name ?? "Unnamed place"),
                "latitude": .double(coordinate.latitude),
                "longitude": .double(coordinate.longitude),
                "metresFromRoute": .int(Int(entry.offset.rounded())),
                "metresAlongRoute": .int(Int(entry.along.rounded())),
            ]
            if routeLength > 0 {
                described["fractionAlongRoute"] = .double(
                    (entry.along / routeLength * 100).rounded() / 100
                )
            }
            if let identifier = entry.item.identifier?.rawValue {
                described["placeIdentifier"] = .string(identifier)
            }
            if let title = entry.item.placemark.title { described["address"] = .string(title) }
            if let phone = entry.item.phoneNumber { described["telephone"] = .string(phone) }
            if let url = entry.item.url { described["url"] = .string(url.absoluteString) }
            return .object(described)
        }

        var result: [String: Value] = [
            "query": .string(query),
            "origin": .string(origin.label),
            "destination": .string(destination.label),
            "transportType": .string(arguments["transportType"]?.stringValue ?? "automobile"),
            "routeDistanceMeters": .int(Int(route.distance.rounded())),
            "routeTravelTimeSeconds": .int(Int(route.expectedTravelTime.rounded())),
            "searchedPoints": .int(samples.count),
            "places": .array(places),
            "found": .int(found.count),
            "note": .string(
                "Distances off the route are straight-line to the nearest point on it, not a second route. "
                    + "Order is by how far along the trip each place comes."
            ),
        ]
        if searchesFailed > 0 {
            result["searchesFailed"] = .int(searchesFailed)
            result["searchesFailedNote"] = .string(
                "\(searchesFailed) of \(samples.count) searches along the route failed, so stretches of it were not covered."
            )
        }
        if places.isEmpty {
            result["emptyNote"] = .string(
                "Nothing matching was found within \(Int(maxDetour)) metres of the route. Raise maxDetourMeters, or search a different term."
            )
        }
        return .object(result)
    }

    /// One end of a route, from an object argument rather than a list.
    static func point(_ value: Value?, named argument: String) throws -> RoutePoint {
        guard let value else {
            throw invalidGeometry("\(argument) is required.")
        }
        guard let point = try Self.points(from: .array([value]), named: argument).first else {
            throw invalidGeometry("\(argument) is required.")
        }
        return point
    }

    /// A polyline's points, as plain coordinates.
    static func coordinates(of polyline: MKPolyline) -> [RouteCoordinate] {
        var points = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Map framing

    /// One marked place on a generated map.
    struct MapMarker: Sendable {
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    struct FramedMap: Sendable {
        let region: MKCoordinateRegion
        let markers: [MapMarker]
    }

    /// Works out which piece of the world the image should show.
    ///
    /// Places win where they are given, because a caller that supplied places
    /// wants to see them; an explicit centre or span still overrides the
    /// framing, so the old four-argument call means exactly what it did.
    static func frame(_ arguments: [String: Value]) async throws -> FramedMap {
        var markers: [MapMarker] = []
        if let raw = arguments["points"]?.arrayValue, !raw.isEmpty {
            guard raw.count <= MapSnapshotFraming.maximumPoints else {
                throw invalidGeometry(
                    "\(raw.count) points is over the \(MapSnapshotFraming.maximumPoints) one map may mark."
                )
            }
            let points = try Self.points(from: arguments["points"], named: "points")
            let items = try await Self.resolve(points)
            markers = zip(points, items).map { point, item in
                MapMarker(coordinate: item.placemark.coordinate, label: point.label)
            }
        }

        let framed = MapSnapshotFraming.region(
            containing: markers.map {
                MapFramePoint(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    label: $0.label
                )
            }
        )

        var center: CLLocationCoordinate2D?
        if let latitude = arguments["latitude"]?.doubleCoerced,
            let longitude = arguments["longitude"]?.doubleCoerced
        {
            center = try Self.coordinate(latitude: latitude, longitude: longitude)
        } else if let framed {
            center = CLLocationCoordinate2D(
                latitude: framed.centerLatitude,
                longitude: framed.centerLongitude
            )
        }
        guard let center else {
            throw invalidGeometry(
                "Give either points to frame, or a latitude and longitude to centre the map on."
            )
        }

        var span: MKCoordinateSpan?
        if let latitudeDelta = arguments["latitudeDelta"]?.doubleCoerced,
            let longitudeDelta = arguments["longitudeDelta"]?.doubleCoerced
        {
            span = MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        } else if let framed {
            span = MKCoordinateSpan(
                latitudeDelta: framed.latitudeDelta,
                longitudeDelta: framed.longitudeDelta
            )
        }
        guard let span else {
            throw invalidGeometry(
                "Give either points to frame, or both latitudeDelta and longitudeDelta."
            )
        }

        return FramedMap(
            region: MKCoordinateRegion(center: center, span: span),
            markers: markers
        )
    }

    /// Draws numbered markers onto a finished snapshot.
    ///
    /// Which way up the snapshot's point space runs is measured from the
    /// snapshot rather than assumed, because getting it wrong mirrors every
    /// marker about the middle of the map and the image still looks plausible.
    static func annotated(
        _ snapshot: MKMapSnapshotter.Snapshot,
        region: MKCoordinateRegion,
        markers: [MapMarker]
    ) -> NSImage {
        let image = snapshot.image
        guard !markers.isEmpty else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let northEdge = snapshot.point(
            for: CLLocationCoordinate2D(
                latitude: min(90, region.center.latitude + region.span.latitudeDelta / 2),
                longitude: region.center.longitude
            )
        )
        let isTopLeftOrigin = MapMarkerGeometry.isTopLeftOrigin(
            northEdgeY: Double(northEdge.y),
            height: Double(size.height)
        )

        // Drawn into a bitmap at the snapshot's own pixel size, so a retina
        // snapshot is not quietly downsampled to its point size on the way out.
        // A snapshot's representation is an `NSCustomImageRep` that reports
        // zero pixels rather than its raster size, checked on this Mac, so a
        // non-positive answer falls back to the point size instead of becoming
        // a one-pixel image.
        let reported = image.representations.first
        let pixelsWide = max(1, (reported?.pixelsWide ?? 0) > 0 ? reported!.pixelsWide : Int(size.width))
        let pixelsHigh = max(1, (reported?.pixelsHigh ?? 0) > 0 ? reported!.pixelsHigh : Int(size.height))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return image }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.current = context

        image.draw(in: CGRect(origin: .zero, size: size))

        let radius = max(9, min(size.width, size.height) * 0.022)
        for (index, marker) in markers.enumerated() {
            let point = snapshot.point(for: marker.coordinate)
            let y = MapMarkerGeometry.drawingY(
                snapshotY: Double(point.y),
                height: Double(size.height),
                isTopLeftOrigin: isTopLeftOrigin
            )
            guard
                MapMarkerGeometry.isVisible(
                    x: Double(point.x),
                    y: y,
                    width: Double(size.width),
                    height: Double(size.height),
                    radius: Double(radius)
                )
            else { continue }

            let circle = NSBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius,
                    y: CGFloat(y) - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            NSColor.systemRed.setFill()
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = max(1, radius * 0.18)
            circle.stroke()

            let number = "\(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: radius),
                .foregroundColor: NSColor.white,
            ]
            let textSize = number.size(withAttributes: attributes)
            number.draw(
                at: NSPoint(
                    x: point.x - textSize.width / 2,
                    y: CGFloat(y) - textSize.height / 2
                ),
                withAttributes: attributes
            )
        }
        context.flushGraphics()

        let annotated = NSImage(size: size)
        annotated.addRepresentation(bitmap)
        return annotated
    }

    // MARK: - Multi-route support

    /// One end of a route, as the caller gave it. The label is kept so the
    /// answer can name the places back rather than returning bare indexes.
    struct RoutePoint: Sendable {
        let label: String
        let address: String?
        let coordinates: [String: Value]?
    }

    /// The schema for one end of a route, shared by the matrix and the
    /// itinerary so the two cannot drift apart.
    static var pointSchema: JSONSchema {
        .object(
            properties: [
                "address": .string(description: "Address or place name"),
                "latitude": .number(minimum: -90, maximum: 90),
                "longitude": .number(minimum: -180, maximum: 180),
                "label": .string(description: "What to call this point in the answer"),
            ],
            additionalProperties: false
        )
    }

    static func points(from value: Value?, named argument: String) throws -> [RoutePoint] {
        guard let raw = value?.arrayValue, !raw.isEmpty else {
            throw invalidGeometry("\(argument) is required and must not be empty.")
        }
        return try raw.enumerated().map { index, entry in
            guard let object = entry.objectValue else {
                throw invalidGeometry("\(argument)[\(index)] must be an object.")
            }
            let address = object["address"]?.stringValue
            let latitude = object["latitude"]?.doubleCoerced
            let longitude = object["longitude"]?.doubleCoerced
            if let latitude, let longitude {
                _ = try coordinate(latitude: latitude, longitude: longitude)
                return RoutePoint(
                    label: object["label"]?.stringValue
                        ?? "\(latitude), \(longitude)",
                    address: nil,
                    coordinates: ["latitude": .double(latitude), "longitude": .double(longitude)]
                )
            }
            guard let address, !address.isEmpty else {
                throw invalidGeometry(
                    "\(argument)[\(index)] needs either an address or both latitude and longitude."
                )
            }
            return RoutePoint(
                label: object["label"]?.stringValue ?? address,
                address: address,
                coordinates: nil
            )
        }
    }

    /// Geocodes every point once, before any routing happens.
    ///
    /// A matrix reuses each origin across every destination, so resolving
    /// inside the routing loop would geocode the same address five times and
    /// spend the rate limit on work already done.
    static func resolve(_ points: [RoutePoint]) async throws -> [MKMapItem] {
        var items: [MKMapItem] = []
        for point in points {
            items.append(
                try await MapsService.shared.getMapItem(
                    address: point.address,
                    coordinates: point.coordinates
                )
            )
        }
        return items
    }

    static func transportType(_ raw: String?) throws -> MKDirectionsTransportType {
        switch raw {
        case nil, "automobile": return .automobile
        case "walking": return .walking
        case "transit": return .transit
        default:
            throw NSError(
                domain: "MapsServiceError",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unknown transport type."]
            )
        }
    }

    /// One route's time and distance, as an outcome rather than a throw.
    ///
    /// Returning the failure instead of raising it is the whole point of the
    /// per-route status: a matrix where one pair has no ferry must still
    /// answer for the other twenty-four.
    static func travel(
        from origin: MKMapItem,
        to destination: MKMapItem,
        transportType: MKDirectionsTransportType,
        departure: Date?,
        originIndex: Int,
        destinationIndex: Int
    ) async -> MapsRouteOutcome {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transportType
        if let departure { request.departureDate = departure }
        do {
            let response = try await MKDirections(request: request).calculateETA()
            return MapsRouteOutcome(
                originIndex: originIndex,
                destinationIndex: destinationIndex,
                distanceMeters: Int(response.distance.rounded()),
                travelSeconds: Int(response.expectedTravelTime.rounded()),
                error: nil
            )
        } catch {
            let nsError = error as NSError
            let message = MapsTransitDirections.message(
                forTransportType: transportType == .transit ? "transit" : nil,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
            return MapsRouteOutcome(
                originIndex: originIndex,
                destinationIndex: destinationIndex,
                distanceMeters: nil,
                travelSeconds: nil,
                error: message ?? error.localizedDescription
            )
        }
    }

    static func describe(_ outcome: MapsRouteOutcome) -> Value {
        var entry: [String: Value] = [
            "originIndex": .int(outcome.originIndex),
            "destinationIndex": .int(outcome.destinationIndex),
            "status": .string(outcome.status),
        ]
        if let distance = outcome.distanceMeters { entry["distanceMeters"] = .int(distance) }
        if let seconds = outcome.travelSeconds {
            entry["expectedTravelSeconds"] = .int(seconds)
        }
        if let error = outcome.error { entry["error"] = .string(error) }
        return .object(entry)
    }

    // MARK: - Helper methods

    private static func invalidGeometry(_ message: String) -> NSError {
        NSError(domain: "MapsServiceError", code: 16, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func coordinate(from arguments: [String: Value]) throws -> CLLocationCoordinate2D {
        guard let latitude = arguments["latitude"]?.doubleCoerced,
            let longitude = arguments["longitude"]?.doubleCoerced
        else { throw invalidGeometry("Latitude and longitude are required.") }
        return try coordinate(latitude: latitude, longitude: longitude)
    }

    private static func coordinate(latitude: Double, longitude: Double) throws -> CLLocationCoordinate2D {
        guard NumericArgument.validatedDouble(latitude, in: -90 ... 90) != nil,
            NumericArgument.validatedDouble(longitude, in: -180 ... 180) != nil
        else { throw invalidGeometry("Latitude must be -90 through 90 and longitude -180 through 180.") }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func validate(span: MKCoordinateSpan) throws {
        guard NumericArgument.isValidMapSpan(latitude: span.latitudeDelta, longitude: span.longitudeDelta)
        else { throw invalidGeometry("Latitude span must be 0 through 180 and longitude span 0 through 360.") }
    }

    private func getMapItem(address: String?, coordinates: [String: Value]?) async throws
        -> MKMapItem
    {
        if let address = address {
            // Use geocoding to get location from address
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = address

            let search = MKLocalSearch(request: searchRequest)
            let response = try await search.start()

            guard let mapItem = response.mapItems.first else {
                throw NSError(
                    domain: "MapsServiceError",
                    code: 11,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not find location for address: \(address)"
                    ]
                )
            }

            return mapItem
        } else if let coordinates = coordinates,
            let lat = coordinates["latitude"]?.doubleCoerced,
            let lng = coordinates["longitude"]?.doubleCoerced
        {

            // Create placemark and map item from coordinates
            let placemark = MKPlacemark(
                coordinate: try Self.coordinate(latitude: lat, longitude: lng)
            )
            return MKMapItem(placemark: placemark)
        } else {
            throw NSError(
                domain: "MapsServiceError",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey: "Either address or coordinates must be provided"
                ]
            )
        }
    }

    /// ISO 8601 with and without fractional seconds. Clients send both, and a
    /// silently ignored date would produce transit directions for the wrong
    /// time of day rather than an error.
    static func parseDate(_ raw: String, named argument: String) throws -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        throw NSError(
            domain: "MapsServiceError",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(argument) must be an ISO 8601 date and time, such as 2026-08-18T09:30:00Z."
            ]
        )
    }

    /// The schema.org Trip type carries the turn instructions but has nowhere
    /// to put how far or how long the trip is, and only ever describes the
    /// first route. Both are the substance of a directions answer, so the
    /// response is described directly.
    static func describe(_ response: MKDirections.Response) -> Value {
        let routes: [Value] = response.routes.map { route in
            var entry: [String: Value] = [
                "distanceMeters": .int(Int(route.distance.rounded())),
                "expectedTravelSeconds": .int(Int(route.expectedTravelTime.rounded())),
                "hasTolls": .bool(route.hasTolls),
                "hasHighways": .bool(route.hasHighways),
                "steps": .array(
                    route.steps
                        .filter { !$0.instructions.isEmpty }
                        .map { step in
                            .object([
                                "instructions": .string(step.instructions),
                                "distanceMeters": .int(Int(step.distance.rounded())),
                            ])
                        }
                ),
            ]
            if !route.name.isEmpty { entry["name"] = .string(route.name) }
            if !route.advisoryNotices.isEmpty {
                entry["advisoryNotices"] = .array(route.advisoryNotices.map { .string($0) })
            }
            return .object(entry)
        }

        var result: [String: Value] = ["routes": .array(routes)]
        if let origin = response.source.name { result["origin"] = .string(origin) }
        if let destination = response.destination.name {
            result["destination"] = .string(destination)
        }
        return .object(result)
    }

}
