// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SQLite3
import Testing

/// Two things are checked here: that the routing classification never
/// overstates its evidence, and that the chat.db query behind it reads the
/// right columns. Both run on fabricated data. Nothing is ever sent.
@Suite("Messages route diagnostic")
struct MessagesRouteDiagnosticTests {
    // MARK: Classification

    @Test("An address with no history predicts nothing")
    func noHistory() {
        let assessment = MessagesRouteDiagnostic.assess(address: "+15550100", observations: [])
        #expect(assessment.likelyService == nil)
        #expect(assessment.confidence == .none)
        #expect(assessment.summary.contains("no conversation"))
    }

    @Test("A consistent send history is observed evidence, not a guarantee")
    func observedIMessage() {
        let assessment = MessagesRouteDiagnostic.assess(
            address: "friend@example.com",
            observations: [
                MessagesRouteObservation(
                    handle: "friend@example.com",
                    registeredService: "iMessage",
                    lastOutgoingService: "iMessage",
                    lastMessageDate: Date(timeIntervalSince1970: 1_756_000_000),
                    messageCount: 40
                )
            ]
        )
        #expect(assessment.likelyService == "iMessage")
        #expect(assessment.confidence == .observed)
        #expect(assessment.deliveryCaveat.contains("not a guarantee of delivery"))
    }

    @Test("A registration with no sends is inferred rather than observed")
    func registeredOnly() {
        let assessment = MessagesRouteDiagnostic.assess(
            address: "+15550101",
            observations: [
                MessagesRouteObservation(handle: "+15550101", registeredService: "SMS")
            ]
        )
        #expect(assessment.likelyService == "SMS")
        #expect(assessment.confidence == .registered)
        #expect(assessment.summary.contains("inferred"))
    }

    @Test("Sends over two services predict nothing at all")
    func mixedHistory() {
        let assessment = MessagesRouteDiagnostic.assess(
            address: "+15550102",
            observations: [
                MessagesRouteObservation(
                    handle: "+15550102",
                    registeredService: "iMessage",
                    lastOutgoingService: "iMessage"
                ),
                MessagesRouteObservation(
                    handle: "+15550102",
                    registeredService: "SMS",
                    lastOutgoingService: "SMS"
                ),
            ]
        )
        #expect(assessment.likelyService == nil)
        #expect(assessment.confidence == .mixed)
    }

    @Test("A known address with no service recorded predicts nothing")
    func knownButUnclassified() {
        let assessment = MessagesRouteDiagnostic.assess(
            address: "+15550103",
            observations: [MessagesRouteObservation(handle: "+15550103", messageCount: 3)]
        )
        #expect(assessment.confidence == .none)
        #expect(assessment.likelyService == nil)
    }

    @Test("Service names are normalized, and MMS is reported as SMS")
    func serviceNormalization() {
        #expect(MessagesRouteDiagnostic.normalizeService("imessage") == "iMessage")
        #expect(MessagesRouteDiagnostic.normalizeService("SMS") == "SMS")
        #expect(MessagesRouteDiagnostic.normalizeService("mms") == "SMS")
        #expect(MessagesRouteDiagnostic.normalizeService("") == nil)
        #expect(MessagesRouteDiagnostic.normalizeService(nil) == nil)
    }

    @Test("Every assessment carries the delivery caveat")
    func caveatAlwaysPresent() {
        let cases = [
            MessagesRouteDiagnostic.assess(address: "a", observations: []),
            MessagesRouteDiagnostic.assess(
                address: "a",
                observations: [
                    MessagesRouteObservation(handle: "a", lastOutgoingService: "iMessage")
                ]
            ),
        ]
        for assessment in cases {
            #expect(assessment.deliveryCaveat == MessagesRouteDiagnostic.deliveryCaveat)
        }
    }

    // MARK: chat.db query

    /// A database with the handle and message columns the route query reads.
    private static func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-route-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        let schema = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT,
                uncanonicalized_id TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, date INTEGER,
                is_from_me INTEGER, service TEXT);

            INSERT INTO handle VALUES (1, '+15551234567', 'iMessage', '(555) 123-4567');
            INSERT INTO handle VALUES (2, 'someone@example.com', 'iMessage', NULL);
            INSERT INTO handle VALUES (3, '+15559999999', 'SMS', NULL);

            -- Two incoming and one outgoing for handle 1, newest outgoing is iMessage.
            INSERT INTO message VALUES (1, 1, 700000000000000000, 0, 'iMessage');
            INSERT INTO message VALUES (2, 1, 710000000000000000, 1, 'SMS');
            INSERT INTO message VALUES (3, 1, 720000000000000000, 1, 'iMessage');
            -- Handle 3 is registered but has never been messaged.
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle, schema, nil, nil, &error) == SQLITE_OK)
        if let error { sqlite3_free(error) }
        return url
    }

    @Test("The route query reports registration, traffic and the latest outgoing service")
    func readsRouteColumns() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let observations = try MessagesDatabaseReader(path: url.path)
            .routeObservations(matching: ["+15551234567"])

        #expect(observations.count == 1)
        let observation = try #require(observations.first)
        #expect(observation.handle == "+15551234567")
        #expect(observation.registeredService == "iMessage")
        #expect(observation.messageCount == 3)
        // The most recent outgoing message is the iMessage one, not the SMS.
        #expect(observation.lastOutgoingService == "iMessage")
        #expect(observation.lastMessageDate != nil)
    }

    @Test("A registered address with no messages reports zero traffic, not an error")
    func registeredWithNoTraffic() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let observations = try MessagesDatabaseReader(path: url.path)
            .routeObservations(matching: ["+15559999999"])
        let observation = try #require(observations.first)
        #expect(observation.messageCount == 0)
        #expect(observation.lastOutgoingService == nil)

        let assessment = MessagesRouteDiagnostic.assess(
            address: "+15559999999",
            observations: observations
        )
        #expect(assessment.confidence == .registered)
    }

    @Test("An address Messages has never seen produces no observations")
    func unknownAddress() throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let observations = try MessagesDatabaseReader(path: url.path)
            .routeObservations(matching: ["nobody@example.org"])
        #expect(observations.isEmpty)
    }
}
