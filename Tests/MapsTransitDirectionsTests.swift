// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// MapKit cannot route a transit trip through `MKDirections.calculate()`, and
/// says so with an opaque MKErrorDomain 5. These tests cover the substitution
/// that replaces it, without needing MapKit or a network round trip.
@Suite("Maps transit directions")
struct MapsTransitDirectionsTests {
    @Test("A transit directionsNotFound is answered with the transit message")
    func substitutesTransitFailure() {
        let message = MapsTransitDirections.message(
            forTransportType: "transit",
            errorDomain: "MKErrorDomain",
            errorCode: 5
        )
        #expect(message == MapsTransitDirections.unavailableMessage)
    }

    @Test("The message points the caller at maps_eta and names the modes that route")
    func messageNamesTheWorkingCapability() {
        let message = MapsTransitDirections.unavailableMessage
        #expect(message.contains("maps_eta"))
        #expect(message.contains("automobile"))
        #expect(message.contains("walking"))
    }

    @Test("A different transport type keeps its own error")
    func leavesOtherModesAlone() {
        #expect(
            MapsTransitDirections.message(
                forTransportType: "automobile",
                errorDomain: "MKErrorDomain",
                errorCode: 5
            ) == nil
        )
        #expect(
            MapsTransitDirections.message(
                forTransportType: nil,
                errorDomain: "MKErrorDomain",
                errorCode: 5
            ) == nil
        )
    }

    @Test("A different failure on a transit request keeps its own error")
    func leavesOtherFailuresAlone() {
        #expect(
            MapsTransitDirections.message(
                forTransportType: "transit",
                errorDomain: "MKErrorDomain",
                errorCode: 3
            ) == nil
        )
        #expect(
            MapsTransitDirections.message(
                forTransportType: "transit",
                errorDomain: "NSURLErrorDomain",
                errorCode: 5
            ) == nil
        )
    }
}
