#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// License signer for the Apple Core binary (docs/licensing.md).
//
// The Ed25519 private key lives in the login Keychain under
// "Apple Core License EdDSA Private Key" (mirroring the Sparkle key's
// storage discipline; the private half is backed up in 1Password under
// the "Apple Core License EdDSA Private Key" Secure Note in the
// Development vault). This tool never prints the private key. The public
// half must be baked into App/Services/Serving/LicenseGate.swift
// (AppleCoreLicensePublicKey.base64) before any signed license will
// verify in the app.
//
// Subcommands:
//   genkey                       create the Keychain key (or print its public half)
//   pubkey                       print the Keychain key's public half, base64
//   sign <json> [output.txt]     sign a license JSON payload -> envelope file
//   verify <envelope.txt>        check an envelope against the Keychain key
//
// The license JSON is the LicenseDocument payload exactly (see
// Shared/LicenseDocument.swift): license_id, product, plan, licensed_to,
// issued_at, expires_at. `sign` reads it, re-encodes it canonically
// (sorted keys, ISO-8601 dates), signs the exact bytes, and writes the
// three-line envelope. Run it from the repo root.

import CryptoKit
import Foundation
import Security

let keychainService = "com.oliverames.applecore.license-signing"
let keychainAccount = "license-signing-key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign_license: \(message)\n".utf8))
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func storePrivateKey(_ key: Curve25519.Signing.PrivateKey) {
    let data = key.rawRepresentation
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        fail("Keychain write failed (status \(status)). Delete the existing item first if you meant to replace it.")
    }
}

struct LicensePayload: Codable {
    var licenseID: String
    var product: String
    var plan: String
    var licensedTo: String?
    var issuedAt: Date
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case licenseID = "license_id"
        case product
        case plan
        case licensedTo = "licensed_to"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

func canonicalDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func signEnvelope(payloadJSON: Data, key: Curve25519.Signing.PrivateKey) throws -> String {
    // Canonicalize through the same model the app decodes with, so the
    // signed bytes are exactly what a license file's payload line says.
    let payload = try canonicalDecoder().decode(LicensePayload.self, from: payloadJSON)
    guard payload.product == "apple-core" else {
        throw NSError(
            domain: "sign_license",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "refusing to sign a license for product \(payload.product)"]
        )
    }
    let encoded = try canonicalEncoder().encode(payload)
    let signature = try key.signature(for: encoded)
    return [
        "APPLE-CORE-LICENSE-1",
        encoded.base64EncodedString(),
        Data(signature).base64EncodedString(),
    ].joined(separator: "\n") + "\n"
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else {
    fail("usage: sign_license.swift genkey | pubkey | sign <json> [output] | verify <envelope>")
}

switch subcommand {
case "genkey":
    if loadPrivateKey() != nil {
        print("A signing key already exists in the Keychain. Use `pubkey` to see its public half.")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    storePrivateKey(key)
    print("Created the signing key in the login Keychain (service \(keychainService)).")
    print("Public key (base64), to bake into LicenseGate.swift:")
    print(key.publicKey.rawRepresentation.base64EncodedString())
    print("Back up the private half in 1Password before issuing any licenses.")

case "pubkey":
    guard let key = loadPrivateKey() else {
        fail("No signing key in the Keychain. Run `genkey` first.")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count >= 2 else { fail("sign needs a payload JSON path") }
    let inputURL = URL(fileURLWithPath: arguments[1])
    guard let payloadJSON = try? Data(contentsOf: inputURL) else {
        fail("could not read \(inputURL.path)")
    }
    guard let key = loadPrivateKey() else {
        fail("No signing key in the Keychain. Run `genkey` first.")
    }
    do {
        let envelope = try signEnvelope(payloadJSON: payloadJSON, key: key)
        if arguments.count >= 3 {
            let outputURL = URL(fileURLWithPath: arguments[2])
            try Data(envelope.utf8).write(to: outputURL, options: .atomic)
            print("Wrote \(outputURL.path)")
        } else {
            print(envelope, terminator: "")
        }
    } catch {
        fail("\(error.localizedDescription)")
    }

case "verify":
    guard arguments.count >= 2 else { fail("verify needs an envelope path") }
    let envelopeURL = URL(fileURLWithPath: arguments[1])
    guard let text = try? String(contentsOf: envelopeURL, encoding: .utf8) else {
        fail("could not read \(envelopeURL.path)")
    }
    guard let key = loadPrivateKey() else {
        fail("No signing key in the Keychain; nothing to verify against.")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count == 3, lines[0] == "APPLE-CORE-LICENSE-1",
        let payload = Data(base64Encoded: lines[1]),
        let signature = Data(base64Encoded: lines[2])
    else {
        fail("not a license envelope")
    }
    guard key.publicKey.isValidSignature(signature, for: payload) else {
        fail("SIGNATURE INVALID")
    }
    if let document = try? canonicalDecoder().decode(LicensePayload.self, from: payload) {
        print("Signature valid. license_id=\(document.licenseID) plan=\(document.plan)")
    } else {
        fail("Signature valid but payload does not decode as a LicenseDocument.")
    }

default:
    fail("unknown subcommand \(subcommand)")
}
