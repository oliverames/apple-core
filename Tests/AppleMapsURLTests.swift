import Foundation
import Testing

@Suite("Apple Maps link resolution")
struct AppleMapsURLTests {
    @Test("A coordinate link resolves to its point")
    func coordinateLink() throws {
        let link = try AppleMapsURL.parse("https://maps.apple.com/?ll=44.2601,-72.5754&q=Montpelier")
        #expect(link.kind == .place)
        #expect(link.latitude == 44.2601)
        #expect(link.longitude == -72.5754)
        #expect(link.query == "Montpelier")
    }

    @Test("A search link with no coordinates is a search")
    func searchLink() throws {
        let link = try AppleMapsURL.parse("https://maps.apple.com/?q=coffee")
        #expect(link.kind == .search)
        #expect(link.query == "coffee")
    }

    @Test("A directions link keeps both ends and the travel mode")
    func directionsLink() throws {
        let link = try AppleMapsURL.parse(
            "https://maps.apple.com/?saddr=Burlington,+VT&daddr=Montpelier,+VT&dirflg=w"
        )
        #expect(link.kind == .directions)
        #expect(link.origin == "Burlington, VT")
        #expect(link.destination == "Montpelier, VT")
        #expect(link.transportType == "walking")
    }

    @Test("A place identifier is carried through")
    func placeIdentifier() throws {
        let link = try AppleMapsURL.parse("https://maps.apple.com/place?place-id=I123&q=Somewhere")
        #expect(link.placeIdentifier == "I123")
    }

    @Test("A host that merely looks like Apple Maps is refused")
    func hostSpoofing() {
        for host in [
            "https://maps.apple.com.evil.test/?q=x",
            "https://notmaps.apple.com/?q=x",
            "https://maps.apple.evil/?q=x",
            "https://evil.test/?q=x",
        ] {
            #expect(throws: AppleMapsURLError.self) { try AppleMapsURL.parse(host) }
        }
        #expect(AppleMapsURL.isAllowedHost("MAPS.APPLE.COM"))
        #expect(!AppleMapsURL.isAllowedHost(nil))
    }

    @Test("Only https is read; no other scheme is followed")
    func schemeRestriction() {
        #expect(throws: AppleMapsURLError.unsupportedScheme("http")) {
            try AppleMapsURL.parse("http://maps.apple.com/?q=x")
        }
        #expect(throws: AppleMapsURLError.self) {
            try AppleMapsURL.parse("file:///etc/passwd")
        }
    }

    @Test("An Apple Maps link with nothing in it is an error, not an empty answer")
    func emptyLink() {
        #expect(throws: AppleMapsURLError.self) {
            try AppleMapsURL.parse("https://maps.apple.com/?foo=bar")
        }
    }

    @Test("A short link is recognised as needing a redirect")
    func shortLink() throws {
        let link = try AppleMapsURL.parse("https://maps.apple.com/p/AbCdEf")
        #expect(link.needsRedirect)
        #expect(AppleMapsURL.isShortLinkPath("/p/AbCdEf"))
        #expect(!AppleMapsURL.isShortLinkPath("/place"))
        #expect(!AppleMapsURL.isShortLinkPath("/"))
    }

    @Test("Redirects are bounded and may not leave Apple Maps")
    func redirectPolicy() {
        #expect(throws: AppleMapsURLError.redirectLeftAppleMaps("evil.test")) {
            // swift-format-ignore: NeverForceUnwrap
            try AppleMapsURL.checkRedirect(to: URL(string: "https://evil.test/x")!, hop: 1)
        }
        #expect(
            throws: AppleMapsURLError.tooManyRedirects(limit: AppleMapsURL.maximumRedirects)
        ) {
            // swift-format-ignore: NeverForceUnwrap
            try AppleMapsURL.checkRedirect(
                to: URL(string: "https://maps.apple.com/?q=x")!,
                hop: AppleMapsURL.maximumRedirects + 1
            )
        }
        #expect(throws: Never.self) {
            // swift-format-ignore: NeverForceUnwrap
            try AppleMapsURL.checkRedirect(to: URL(string: "https://maps.apple.com/?q=x")!, hop: 1)
        }
    }

    @Test("Coordinates are validated as coordinates, not merely as two numbers")
    func coordinateValidation() {
        #expect(AppleMapsURL.coordinatePair("44.2,-72.5")?.latitude == 44.2)
        #expect(AppleMapsURL.coordinatePair("91,0") == nil)
        #expect(AppleMapsURL.coordinatePair("0,181") == nil)
        #expect(AppleMapsURL.coordinatePair("north,south") == nil)
        #expect(AppleMapsURL.coordinatePair(nil) == nil)
    }

    @Test("dirflg becomes the words maps_directions already uses")
    func transportTranslation() {
        #expect(AppleMapsURL.transportType("d") == "automobile")
        #expect(AppleMapsURL.transportType("w") == "walking")
        #expect(AppleMapsURL.transportType("r") == "transit")
        #expect(AppleMapsURL.transportType("x") == nil)
    }
}
