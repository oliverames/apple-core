import Foundation
import Testing

@Suite("Gumroad license policy")
struct GumroadLicenseTests {
    @Test("A Gumroad key is four groups of eight, case-insensitive, whitespace-tolerant")
    func keyShape() {
        #expect(GumroadLicense.looksLikeKey("6F0E4C97-B72A4E69-A11BF6C4-AF6517E7"))
        #expect(GumroadLicense.looksLikeKey("  6f0e4c97-b72a4e69-a11bf6c4-af6517e7\n"))
        #expect(
            GumroadLicense.normalizeKey(" 6f0e4c97-b72a4e69-a11bf6c4-af6517e7 ")
                == "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7"
        )
        #expect(!GumroadLicense.looksLikeKey("APPLE-CORE-LICENSE-1"))
        #expect(!GumroadLicense.looksLikeKey("6F0E4C97-B72A4E69-A11BF6C4"))
        #expect(!GumroadLicense.looksLikeKey(""))
        #expect(GumroadLicense.normalizeKey("6F0E4C97 B72A4E69") == nil)
    }

    @Test("The verify request names the product, the key, and does not count a use")
    func requestBody() {
        let body = String(
            decoding: GumroadLicense.verifyRequestBody(licenseKey: "AAAA-BBBB", productID: "p+q=="),
            as: UTF8.self
        )
        #expect(body == "increment_uses_count=false&license_key=AAAA-BBBB&product_id=p%2Bq%3D%3D")
    }

    @Test("An entitled purchase is valid and carries email, sale id, and date")
    func validResponse() {
        let json = """
            {"success": true, "uses": 1, "purchase": {"email": "buyer@example.com", "sale_id": "abc123",
             "sale_timestamp": "2026-09-03T14:00:00Z", "refunded": false, "chargebacked": false,
             "product_name": "Apple Core License"}}
            """
        let verdict = GumroadLicense.verifyResponse(Data(json.utf8))
        guard case .valid(let purchase)? = verdict else {
            Issue.record("expected valid, got \(String(describing: verdict))")
            return
        }
        #expect(purchase.email == "buyer@example.com")
        #expect(purchase.saleID == "abc123")
        #expect(purchase.productName == "Apple Core License")
        #expect(purchase.purchasedAt == ISO8601DateFormatter().date(from: "2026-09-03T14:00:00Z"))
    }

    @Test("Refunds, chargebacks, lapsed subscriptions, and unknown keys are all revoked")
    func revokedResponses() {
        for json in [
            #"{"success": false, "message": "That license does not exist for the provided product."}"#,
            #"{"success": true, "purchase": {"refunded": true}}"#,
            #"{"success": true, "purchase": {"chargebacked": true}}"#,
            #"{"success": true, "purchase": {"disputed": true}}"#,
            #"{"success": true, "purchase": {"subscription_ended_at": "2026-01-01T00:00:00Z"}}"#,
            #"{"success": true, "purchase": {"subscription_cancelled_at": "2026-01-01T00:00:00Z"}}"#,
            #"{"success": true, "purchase": {"subscription_failed_at": "2026-01-01T00:00:00Z"}}"#,
        ] {
            #expect(GumroadLicense.verifyResponse(Data(json.utf8)) == .revoked, Comment(rawValue: json))
        }
    }

    @Test("A body that is not the verify document is nil, never a verdict")
    func unparseableResponse() {
        #expect(GumroadLicense.verifyResponse(Data("<html>502</html>".utf8)) == nil)
        #expect(GumroadLicense.verifyResponse(Data(#"{"error": "x"}"#.utf8)) == nil)
        for json in [
            #"{"success": true}"#,
            #"{"success": true, "purchase": null}"#,
            #"{"success": true, "purchase": []}"#,
            #"{"success": 1, "purchase": {}}"#,
            #"{"success": "true", "purchase": {}}"#,
            #"{"success": null}"#,
            #"{"success": true, "purchase": {"refunded": "true"}}"#,
        ] {
            #expect(GumroadLicense.verifyResponse(Data(json.utf8)) == nil, Comment(rawValue: json))
        }
    }

    @Test("Entitlement survives offline only inside the grace window, and asks again after a day")
    func recordEntitlement() {
        let verified = Date(timeIntervalSince1970: 1_800_000_000)
        let record = GumroadLicenseRecord(
            key: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7",
            email: "b@x",
            lastVerifiedAt: verified
        )
        #expect(record.isEntitled(now: verified.addingTimeInterval(13 * 86_400)))
        #expect(!record.isEntitled(now: verified.addingTimeInterval(15 * 86_400)))
        #expect(!record.needsReverification(now: verified.addingTimeInterval(3600)))
        #expect(record.needsReverification(now: verified.addingTimeInterval(25 * 3600)))
        var revoked = record
        revoked.cachedValid = false
        #expect(!revoked.isEntitled(now: verified))
    }

    @Test("The synthesized document masks the key and names the plan")
    func recordDocument() {
        let verified = Date(timeIntervalSince1970: 1_800_000_000)
        let record = GumroadLicenseRecord(
            key: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7",
            email: "b@x",
            lastVerifiedAt: verified
        )
        let document = record.document
        #expect(document.licenseID == "gumroad:…AF6517E7")
        #expect(document.plan == "gumroad")
        #expect(document.product == LicenseDocumentCodec.expectedProduct)
        #expect(document.licensedTo == "b@x")
        #expect(document.expiresAt == nil)
        #expect(document.isValid(on: verified.addingTimeInterval(10 * 365 * 86_400)))
        #expect(!record.maskedKey.contains("6F0E4C97"))
    }

    @Test("The record round-trips through JSON with ISO 8601 dates")
    func recordRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = GumroadLicenseRecord(
            key: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7",
            email: "b@x",
            saleID: "s1",
            purchasedAt: Date(timeIntervalSince1970: 1_799_000_000),
            lastVerifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let decoded = try decoder.decode(GumroadLicenseRecord.self, from: encoder.encode(record))
        #expect(decoded == record)
    }
}
