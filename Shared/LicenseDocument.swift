// SPDX-License-Identifier: GPL-3.0-or-later
//
// License document format for the Apple Core binary.
//
// Apple Core's source is GPL-3.0-or-later, while the official signed binary
// is conveyed under EULA.md with license-key activation (docs/licensing.md
// records the dual-license decision). A license file is a three-line
// envelope:
//
//   APPLE-CORE-LICENSE-1
//   <base64 payload bytes>
//   <base64 Ed25519 signature over the payload bytes>
//
// The signature covers the exact payload bytes, never a re-serialization of
// them, so no canonical JSON form is ever required and any encoder that
// produces those bytes can sign. Verification is offline: the app embeds
// the Ed25519 public key and never phones home.

import CryptoKit
import Foundation

/// The fields a license carries. Deliberately small: enough to identify a
/// purchase and display it, and nothing that could turn into a privacy
/// problem if the file is shared or leaked.
public struct LicenseDocument: Codable, Sendable, Equatable {
    public let licenseID: String
    /// Always `apple-core` for this product; verified on decode.
    public let product: String
    /// Tier name, e.g. `personal`. Informational for now.
    public let plan: String
    /// Buyer name or email, for display in Settings. Not verified against
    /// anything; it is a label, not an identity claim.
    public let licensedTo: String?
    public let issuedAt: Date
    /// Absent or nil means the license never expires.
    public let expiresAt: Date?

    public init(
        licenseID: String,
        product: String,
        plan: String,
        licensedTo: String?,
        issuedAt: Date,
        expiresAt: Date?
    ) {
        self.licenseID = licenseID
        self.product = product
        self.plan = plan
        self.licensedTo = licensedTo
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public enum CodingKeys: String, CodingKey {
        case licenseID = "license_id"
        case product
        case plan
        case licensedTo = "licensed_to"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }

    public func isValid(on date: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return date <= expiresAt
    }
}

public enum LicenseDocumentError: Error, Equatable, Sendable {
    /// The text is not a license envelope at all, or the payload is not
    /// decodable JSON, or a field has the wrong type.
    case malformed
    /// The envelope parses but the signature does not verify against the
    /// public key, or the key itself is unusable.
    case invalidSignature
    case wrongProduct(String)
    case expired(Date)
}

public enum LicenseDocumentCodec {
    public static let envelopeHeader = "APPLE-CORE-LICENSE-1"
    public static let expectedProduct = "apple-core"
    /// Keep a tampered envelope from making the app allocate and parse an
    /// arbitrary blob before the signature check runs.
    public static let maximumPayloadBytes = 8192
    /// Allows the base64 payload, header, and signature without reading arbitrary files into memory.
    public static let maximumImportBytes = 16 * 1024

    public static func importedEnvelope(from data: Data) -> String? {
        guard data.count <= maximumImportBytes,
            let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(envelopeHeader + "\n")
        else { return nil }
        return text
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Signs `document` with `signingKey` and returns the three-line
    /// envelope. The signature is over the exact encoded payload bytes.
    public static func encode(
        _ document: LicenseDocument,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let payload = try encoder.encode(document)
        let signature = try signingKey.signature(for: payload)
        return [
            envelopeHeader,
            payload.base64EncodedString(),
            Data(signature).base64EncodedString(),
        ].joined(separator: "\n") + "\n"
    }

    /// Verifies a pasted or on-disk envelope against `publicKey`. Signature
    /// first, parse second: a malformed-but-signed file fails the same way
    /// as any other bad input, and unsigned junk never reaches the JSON
    /// decoder.
    public static func verify(
        _ text: String,
        publicKey: Data,
        now: Date = Date()
    ) -> Result<LicenseDocument, LicenseDocumentError> {
        let lines =
            text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 3,
            lines[0] == envelopeHeader,
            let payload = Data(base64Encoded: lines[1]),
            let signature = Data(base64Encoded: lines[2]),
            !payload.isEmpty,
            payload.count <= maximumPayloadBytes,
            signature.count == 64
        else {
            return .failure(.malformed)
        }

        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
            key.isValidSignature(signature, for: payload)
        else {
            return .failure(.invalidSignature)
        }

        guard let document = try? decoder.decode(LicenseDocument.self, from: payload) else {
            return .failure(.malformed)
        }

        guard document.product == expectedProduct else {
            return .failure(.wrongProduct(document.product))
        }

        guard document.isValid(on: now) else {
            return .failure(.expired(document.expiresAt ?? now))
        }

        return .success(document)
    }
}
