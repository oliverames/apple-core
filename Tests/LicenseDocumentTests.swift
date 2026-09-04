// SPDX-License-Identifier: GPL-3.0-or-later
//
// License envelope tests: sign/verify round-trip through the same codec
// Shared/LicenseDocument.swift defines, plus every rejection path the
// gate can hit. The codec's JSONEncoder configuration is private, so the
// tests sign with the identical encoder settings (ISO-8601 dates, sorted
// keys) that Scripts/sign_license.swift uses.

import CryptoKit
import Foundation
import Testing

@Suite("License document envelope")
struct LicenseDocumentTests {
    private static let signingKey = Curve25519.Signing.PrivateKey()
    private static var publicKeyData: Data { signingKey.publicKey.rawRepresentation }

    private static let document = LicenseDocument(
        licenseID: "8f2c1d90-test-4a7b",
        product: "apple-core",
        plan: "personal",
        licensedTo: "buyer@example.com",
        issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
        expiresAt: nil
    )

    private static func envelope(
        _ document: LicenseDocument,
        signingKey: Curve25519.Signing.PrivateKey = signingKey
    ) throws -> String {
        try LicenseDocumentCodec.encode(document, signingKey: signingKey)
    }

    @Test("Sign/verify round-trip")
    func roundTrip() throws {
        let envelope = try Self.envelope(Self.document)
        let result = LicenseDocumentCodec.verify(envelope, publicKey: Self.publicKeyData)
        guard case .success(let verified) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(verified == Self.document)
        #expect(verified.isValid())
    }

    @Test("A tampered payload is rejected")
    func tamperedPayload() throws {
        let envelope = try Self.envelope(Self.document)
        let lines = envelope.split(separator: "\n").map(String.init)
        var payload = Data(base64Encoded: lines[1])!
        // Flip one byte in the middle of the payload.
        payload[payload.count / 2] ^= 0xFF
        let tamperedPayload = payload.base64EncodedString()
        let tampered = "\(lines[0])\n\(tamperedPayload)\n\(lines[2])\n"
        let result = LicenseDocumentCodec.verify(
            tampered,
            publicKey: Self.publicKeyData
        )
        #expect(
            result == .failure(.invalidSignature)
                || result == .failure(.malformed)
        )
    }

    @Test("File import accepts bounded UTF-8 envelopes, not arbitrary files")
    func importBounds() throws {
        let envelope = try Self.envelope(Self.document)
        #expect(LicenseDocumentCodec.importedEnvelope(from: Data(envelope.utf8)) == envelope)
        let windowsEnvelope = envelope.replacingOccurrences(of: "\n", with: "\r\n")
        let imported = try #require(LicenseDocumentCodec.importedEnvelope(from: Data(windowsEnvelope.utf8)))
        #expect(imported == envelope)
        #expect(LicenseDocumentCodec.verify(imported, publicKey: Self.publicKeyData) == .success(Self.document))
        #expect(LicenseDocumentCodec.importedEnvelope(from: Data("not a license".utf8)) == nil)
        #expect(LicenseDocumentCodec.importedEnvelope(from: Data([0xFF, 0xFE])) == nil)
        #expect(
            LicenseDocumentCodec.importedEnvelope(
                from: Data((envelope + String(repeating: "x", count: LicenseDocumentCodec.maximumImportBytes)).utf8)
            ) == nil
        )
    }

    @Test("A signature from a different key is rejected")
    func wrongKey() throws {
        let attackerKey = Curve25519.Signing.PrivateKey()
        let envelope = try Self.envelope(Self.document, signingKey: attackerKey)
        #expect(
            LicenseDocumentCodec.verify(envelope, publicKey: Self.publicKeyData)
                == .failure(.invalidSignature)
        )
    }

    @Test("A moved signature does not verify against different payload bytes")
    func signatureReplay() throws {
        let envelope = try Self.envelope(Self.document)
        let lines = envelope.split(separator: "\n").map(String.init)
        // Sign a different document, then swap in the first signature.
        let other = try Self.envelope(
            LicenseDocument(
                licenseID: "other",
                product: "apple-core",
                plan: "personal",
                licensedTo: nil,
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
        let otherLines = other.split(separator: "\n").map(String.init)
        let frankenvelope = "\(otherLines[0])\n\(otherLines[1])\n\(lines[2])\n"
        #expect(
            LicenseDocumentCodec.verify(
                frankenvelope,
                publicKey: Self.publicKeyData
            ) == .failure(.invalidSignature)
        )
    }

    @Test("Junk is rejected as malformed, not as a signature failure")
    func junkInput() {
        #expect(
            LicenseDocumentCodec.verify("hello world", publicKey: Self.publicKeyData)
                == .failure(.malformed)
        )
        #expect(
            LicenseDocumentCodec.verify("", publicKey: Self.publicKeyData)
                == .failure(.malformed)
        )
        #expect(
            LicenseDocumentCodec.verify(
                "APPLE-CORE-LICENSE-1\n\n",
                publicKey: Self.publicKeyData
            ) == .failure(.malformed)
        )
    }

    @Test("A license for another product is rejected")
    func wrongProduct() throws {
        let document = LicenseDocument(
            licenseID: "x",
            product: "some-other-product",
            plan: "personal",
            licensedTo: nil,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: nil
        )
        let envelope = try Self.envelope(document)
        #expect(
            LicenseDocumentCodec.verify(
                envelope,
                publicKey: Self.publicKeyData
            ) == .failure(.wrongProduct("some-other-product"))
        )
    }

    @Test("An expired license is rejected, a valid-dated one is not")
    func expiry() throws {
        let past = LicenseDocument(
            licenseID: "expired",
            product: "apple-core",
            plan: "personal",
            licensedTo: nil,
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let envelope = try Self.envelope(past)
        #expect(
            LicenseDocumentCodec.verify(envelope, publicKey: Self.publicKeyData)
                == .failure(.expired(Date(timeIntervalSince1970: 1_000_000_000)))
        )

        let future = LicenseDocument(
            licenseID: "future",
            product: "apple-core",
            plan: "personal",
            licensedTo: nil,
            issuedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 60 * 60 * 24)
        )
        let futureEnvelope = try Self.envelope(future)
        let futureResult = LicenseDocumentCodec.verify(futureEnvelope, publicKey: Self.publicKeyData)
        guard case .success = futureResult else {
            Issue.record("valid-dated license failed verification")
            return
        }
    }

    @Test("A license with no expiry never expires")
    func noExpiry() throws {
        let envelope = try Self.envelope(Self.document)
        // Far-future "now": a perpetual license still verifies.
        let farFuture = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365 * 50)
        let noExpiryResult = LicenseDocumentCodec.verify(envelope, publicKey: Self.publicKeyData, now: farFuture)
        guard case .success = noExpiryResult else {
            Issue.record("perpetual license failed verification far in the future")
            return
        }
    }
}
