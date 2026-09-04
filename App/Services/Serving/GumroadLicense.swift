// SPDX-License-Identifier: GPL-3.0-or-later
//
// Gumroad license keys as a second way to activate the signed binary.
//
// The buyer pastes the key Gumroad generated for their purchase into
// Settings → License. Apple Core asks Gumroad's verify endpoint whether the
// key is entitled, records the answer locally, and re-asks about once a day
// while the app runs. A Mac that cannot reach Gumroad keeps its entitlement
// for a grace period, so a network outage never switches a licensed server
// off. This mirrors Ping Warden's enforcement model; the decision logic is
// pure so it stays testable without a network.
//
// The Ed25519 envelope (Shared/LicenseDocument.swift) remains the other
// path, used for licenses Oliver signs directly.

import Foundation

public enum GumroadLicense {
    /// Gumroad product "Apple Core License" (permalink `applecore`).
    public static let productID = "H5iMAgmqjSc9_p61iSwApA=="
    public static let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    /// A cached entitlement survives without a successful re-check for
    /// this long, then the gate closes until Gumroad can be reached again.
    public static let offlineGraceInterval: TimeInterval = 14 * 24 * 3600
    /// How old a verification may be before the gate asks Gumroad again
    /// in the background.
    public static let reverifyInterval: TimeInterval = 24 * 3600

    public struct Purchase: Equatable, Sendable {
        public var email: String?
        public var saleID: String?
        public var purchasedAt: Date?
        public var productName: String?
    }

    public enum Verification: Equatable, Sendable {
        /// Entitled. Carries what Gumroad said about the purchase.
        case valid(Purchase)
        /// Gumroad answered and the key is not entitled: unknown for this
        /// product, disabled, refunded, or charged back.
        case revoked
    }

    /// Gumroad keys are four groups of eight uppercase hex-like
    /// characters. Anything else pasted into the license field is treated
    /// as an envelope.
    public static func looksLikeKey(_ raw: String) -> Bool {
        guard let key = normalizeKey(raw) else { return false }
        let groups = key.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 4 && groups.allSatisfy { $0.count == 8 }
    }

    public static func normalizeKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// Form body for `POST /v2/licenses/verify`. Uses are not counted:
    /// one license covers the Macs one person uses, so a second Mac must
    /// not read as a second seat.
    public static func verifyRequestBody(licenseKey: String, productID: String = productID) -> Data {
        let fields = [
            "product_id": productID,
            "license_key": licenseKey,
            "increment_uses_count": "false",
        ]
        return Data(
            fields.map { "\($0.key)=\(percentEncode($0.value))" }
                .sorted()
                .joined(separator: "&")
                .utf8
        )
    }

    /// Maps Gumroad's answer to a decision. Nil when the body is not the
    /// verify document at all, which callers treat as unreachable rather
    /// than as a verdict. A `success: false` body is authoritative: the
    /// API answered, and the key is not entitled.
    public static func verifyResponse(_ data: Data) -> Verification? {
        guard let response = try? JSONDecoder().decode(VerifyResponse.self, from: data) else {
            return nil
        }
        guard response.success else { return .revoked }
        guard let object = response.purchase else { return nil }
        if object.refunded == true || object.chargebacked == true || object.disputed == true
            || object.subscription_ended_at != nil || object.subscription_cancelled_at != nil
            || object.subscription_failed_at != nil
        {
            return .revoked
        }
        return .valid(
            Purchase(
                email: object.email,
                saleID: object.sale_id ?? object.id,
                purchasedAt: (object.sale_timestamp ?? object.created_at).flatMap(parseDate),
                productName: object.product_name
            )
        )
    }

    /// Typed decoding rejects numeric/string "success" values and malformed
    /// purchase fields instead of promoting an incomplete response to a license.
    private struct VerifyResponse: Decodable {
        let success: Bool
        let purchase: VerifiedPurchase?
    }

    private struct VerifiedPurchase: Decodable {
        let email: String?
        let sale_id: String?
        let id: String?
        let sale_timestamp: String?
        let created_at: String?
        let product_name: String?
        let refunded: Bool?
        let chargebacked: Bool?
        let disputed: Bool?
        let subscription_ended_at: String?
        let subscription_cancelled_at: String?
        let subscription_failed_at: String?
    }

    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The network half, kept behind a closure so the gate can be driven
    /// by a stub. Any HTTP status is passed through as data: Gumroad says
    /// "not entitled" with a 404 body, and that body is a verdict.
    public typealias Verifier = @Sendable (Data) async -> Result<Data, Error>

    public static let liveVerifier: Verifier = { body in
        var request = URLRequest(url: verifyURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}

/// What the gate writes after a successful activation and updates on each
/// re-check. Lives beside `license.txt`, mode 0600.
public struct GumroadLicenseRecord: Codable, Equatable, Sendable {
    public var key: String
    public var email: String?
    public var saleID: String?
    public var purchasedAt: Date?
    public var lastVerifiedAt: Date
    /// False once Gumroad has said the key is no longer entitled. The
    /// record is kept so the Settings pane can say why, rather than
    /// silently reverting to "not activated".
    public var cachedValid: Bool

    public init(
        key: String,
        email: String? = nil,
        saleID: String? = nil,
        purchasedAt: Date? = nil,
        lastVerifiedAt: Date,
        cachedValid: Bool = true
    ) {
        self.key = key
        self.email = email
        self.saleID = saleID
        self.purchasedAt = purchasedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.cachedValid = cachedValid
    }

    public func isEntitled(now: Date, grace: TimeInterval = GumroadLicense.offlineGraceInterval) -> Bool {
        cachedValid && now.timeIntervalSince(lastVerifiedAt) <= grace
    }

    public func needsReverification(now: Date, interval: TimeInterval = GumroadLicense.reverifyInterval) -> Bool {
        now.timeIntervalSince(lastVerifiedAt) > interval
    }

    /// The last eight characters, for display; the whole key is the
    /// buyer's credential and stays out of logs and status responses.
    public var maskedKey: String {
        "…" + key.suffix(8)
    }

    /// A document the rest of the app can show and report, in the same
    /// shape as a signed envelope's.
    public var document: LicenseDocument {
        LicenseDocument(
            licenseID: "gumroad:" + (saleID ?? maskedKey),
            product: LicenseDocumentCodec.expectedProduct,
            plan: "gumroad",
            licensedTo: email,
            issuedAt: purchasedAt ?? lastVerifiedAt,
            expiresAt: nil
        )
    }
}
