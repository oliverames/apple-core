// SPDX-License-Identifier: GPL-3.0-or-later
//
// License gate for the Apple Core binary.
//
// Apple Core's source is GPL-3.0-or-later; the official signed binary is
// conveyed under EULA.md with license-key activation (docs/licensing.md).
// This gate enforces the EULA's activation term at the serving layer: an
// unlicensed installation answers every MCP session-creating request with
// HTTP 402, while the unauthenticated surfaces (landing page, icons, OAuth
// discovery metadata) stay reachable so the Settings pane and the first-run
// flow keep working.
//
// Two activation paths feed one gate. A Gumroad license key is verified
// with Gumroad at activation and re-checked about daily, with a 14-day
// offline grace (GumroadLicense.swift). A signed Ed25519 envelope
// (Shared/LicenseDocument.swift) is verified offline and never contacts
// anyone; it is the path for licenses Oliver signs directly.

import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

/// A Keychain witness binds the offline cache to bytes written after a live
/// verification. Editing or copying JSON alone cannot create an entitlement.
public struct GumroadReceiptTrust: Sendable {
    public var read: @Sendable (URL) -> Data?
    public var write: @Sendable (Data?, URL) throws -> Void

    public static let keychain = GumroadReceiptTrust(
        read: { url in
            var query = keychainQuery(url)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        },
        write: { data, url in
            let query = keychainQuery(url)
            guard let data else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
                return
            }
            let attributes = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    )

    private static func keychainQuery(_ url: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: "com.oliverames.applecore.gumroad-receipt",
            kSecAttrAccount as String: url.standardizedFileURL.path,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// The Ed25519 public key whose private half signs Apple Core licenses.
/// The private key lives in Oliver's login Keychain and 1Password, exactly
/// like the Sparkle EdDSA key; only this public half ships in the binary.
public enum AppleCoreLicensePublicKey {
    /// Raw Ed25519 public key bytes, base64.
    public static let base64 = "qBn20Q2xAdkaU3U/wonWVTSTrbphkWCgnDldhI6RAsk="
    public static var raw: Data { Data(base64Encoded: base64) ?? Data() }
}

/// A plain-language activation failure, for display in Settings. Wraps a
/// message rather than enumerating causes because every cause already has
/// exactly one user-facing sentence in `activate`.
public struct LicenseActivationError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public actor LicenseGate {
    /// Cache signature verification, but compare the file bytes on every
    /// request so deletion and replacement take effect without a relaunch.
    private var cached: (document: LicenseDocument, source: Data)?
    private static let log = Logger(subsystem: "com.oliverames.applecore", category: "license")

    private let licenseURL: URL
    private let gumroadRecordURL: URL
    private let verifier: GumroadLicense.Verifier
    private let publicKey: Data
    private let receiptTrust: GumroadReceiptTrust
    private var reverifyInFlight = false
    private var lastReverifyAttempt: Date?
    private var activationGeneration = UUID()
    private var revokedKeys: Set<String> = []

    public init(
        licenseURL: URL,
        gumroadRecordURL: URL? = nil,
        verifier: @escaping GumroadLicense.Verifier = GumroadLicense.liveVerifier,
        publicKey: Data = AppleCoreLicensePublicKey.raw,
        receiptTrust: GumroadReceiptTrust = .keychain
    ) {
        self.licenseURL = licenseURL
        self.gumroadRecordURL =
            gumroadRecordURL
            ?? licenseURL.deletingLastPathComponent().appendingPathComponent("gumroad-license.json")
        self.verifier = verifier
        self.publicKey = publicKey
        self.receiptTrust = receiptTrust
    }

    /// Reads and verifies the license file. Returns nil when there is no
    /// file or it does not verify. Signature verification is cached only
    /// while the exact file bytes and the document's validity are unchanged.
    public func validatedDocument(now: Date = Date()) -> LicenseDocument? {
        let data = try? Data(contentsOf: licenseURL)
        if let cached, data == cached.source, cached.document.isValid(on: now) {
            return cached.document
        }
        cached = nil

        if let data,
            let text = String(data: data, encoding: .utf8)
        {
            switch LicenseDocumentCodec.verify(text, publicKey: publicKey, now: now) {
            case .success(let document):
                cached = (document, data)
                return document
            case .failure(let error):
                Self.log.notice("License rejected: \(String(describing: error), privacy: .public)")
                cached = nil
            }
        }
        guard let data = try? Data(contentsOf: gumroadRecordURL),
            let record = readGumroadRecord(from: data)
        else { return nil }
        let trusted = receiptTrust.read(gumroadRecordURL) == Data(SHA256.hash(data: data))
        if !trusted || record.needsReverification(now: now) || !record.isEntitled(now: now) {
            scheduleReverification(now: now)
        }
        guard trusted, record.isEntitled(now: now) else { return nil }
        // Not cached: the record is the cache, and re-reading a small file
        // per session keeps a background re-check visible immediately.
        return record.document
    }

    // MARK: - Gumroad keys

    private func readGumroadRecord(from snapshot: Data? = nil) -> GumroadLicenseRecord? {
        guard let data = snapshot ?? (try? Data(contentsOf: gumroadRecordURL)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var record = try? decoder.decode(GumroadLicenseRecord.self, from: data) else { return nil }
        if revokedKeys.contains(record.key) { record.cachedValid = false }
        return record
    }

    private func writeGumroadRecord(_ record: GumroadLicenseRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let fm = FileManager.default
        try fm.createDirectory(at: gumroadRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: gumroadRecordURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: gumroadRecordURL.path)
        try receiptTrust.write(Data(SHA256.hash(data: data)), gumroadRecordURL)
    }

    /// Asks Gumroad about a pasted key and records the answer. Nothing is
    /// written unless Gumroad says the key is entitled, so a bad paste
    /// cannot knock an activated installation back to unlicensed.
    public func activateGumroadKey(_ raw: String, now: Date = Date()) async
        -> Result<LicenseDocument, LicenseActivationError>
    {
        guard let key = GumroadLicense.normalizeKey(raw), GumroadLicense.looksLikeKey(key) else {
            return .failure(LicenseActivationError("This does not look like a Gumroad license key."))
        }
        let generation = UUID()
        activationGeneration = generation
        let response = await verifier(GumroadLicense.verifyRequestBody(licenseKey: key))
        guard activationGeneration == generation else {
            return .failure(LicenseActivationError("The license changed while this key was being checked. Try again."))
        }
        switch response {
        case .failure(let error):
            return .failure(
                LicenseActivationError(
                    "Apple Core could not reach Gumroad to check this key: \(error.localizedDescription)"
                )
            )
        case .success(let data):
            switch GumroadLicense.verifyResponse(data) {
            case nil:
                return .failure(
                    LicenseActivationError("Gumroad answered with something Apple Core did not understand.")
                )
            case .revoked:
                // An authoritative rejection of the installed key closes its
                // cache immediately. A typo or another key cannot revoke it.
                if var record = readGumroadRecord(), record.key == key {
                    record.cachedValid = false
                    revokedKeys.insert(key)
                    try? receiptTrust.write(nil, gumroadRecordURL)
                    try? writeGumroadRecord(record)
                }
                return .failure(
                    LicenseActivationError(
                        "Gumroad does not recognise this key for Apple Core, or the purchase was refunded or disabled."
                    )
                )
            case .valid(let purchase):
                let record = GumroadLicenseRecord(
                    key: key,
                    email: purchase.email,
                    saleID: purchase.saleID,
                    purchasedAt: purchase.purchasedAt,
                    lastVerifiedAt: now
                )
                do {
                    try writeGumroadRecord(record)
                } catch {
                    return .failure(
                        LicenseActivationError("Apple Core could not save the license: \(error.localizedDescription)")
                    )
                }
                revokedKeys.remove(key)
                cached = nil
                Self.log.notice("Activated Gumroad key \(record.maskedKey, privacy: .public)")
                return .success(record.document)
            }
        }
    }

    /// Routes a paste to the right path by its shape.
    public func activate(input: String, now: Date = Date()) async -> Result<LicenseDocument, LicenseActivationError> {
        if GumroadLicense.looksLikeKey(input) {
            return await activateGumroadKey(input, now: now)
        }
        return activate(input, now: now)
    }

    private func scheduleReverification(now: Date) {
        guard !reverifyInFlight else { return }
        if let lastReverifyAttempt, now.timeIntervalSince(lastReverifyAttempt) < 60 { return }
        lastReverifyAttempt = now
        Task { await self.reverifyGumroadKey(now: now) }
    }

    /// Re-asks Gumroad about the recorded key. A reachable "no" closes the
    /// gate; an unreachable Gumroad changes nothing and the grace window
    /// decides.
    public func reverifyGumroadKey(now: Date = Date()) async {
        guard !reverifyInFlight else { return }
        reverifyInFlight = true
        defer { reverifyInFlight = false }
        guard let originalData = try? Data(contentsOf: gumroadRecordURL),
            var record = readGumroadRecord(from: originalData)
        else { return }
        let generation = activationGeneration
        guard case .success(let data) = await verifier(GumroadLicense.verifyRequestBody(licenseKey: record.key)),
            let verdict = GumroadLicense.verifyResponse(data)
        else {
            Self.log.notice(
                "Gumroad unreachable; retaining cached entitlement for \(record.maskedKey, privacy: .public)"
            )
            return
        }
        // Settings and the HTTP server share this actor. Its generation
        // rejects stale replies after an activation/deactivation, and the
        // byte comparison also notices external edits made during the await.
        guard activationGeneration == generation,
            originalData == (try? Data(contentsOf: gumroadRecordURL))
        else { return }
        switch verdict {
        case .valid(let purchase):
            record.lastVerifiedAt = now
            record.cachedValid = true
            revokedKeys.remove(record.key)
            if let email = purchase.email { record.email = email }
            if let saleID = purchase.saleID { record.saleID = saleID }
        case .revoked:
            record.cachedValid = false
            revokedKeys.insert(record.key)
            try? receiptTrust.write(nil, gumroadRecordURL)
            cached = nil
            Self.log.notice("Gumroad revoked key \(record.maskedKey, privacy: .public)")
        }
        do {
            try writeGumroadRecord(record)
        } catch {
            // A failed write must not undo a revocation in this process.
            Self.log.error("Could not persist Gumroad verification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called from Settings after a successful paste-in activation writes
    /// the file, so the running server picks the change up on the next
    /// request instead of after a relaunch.
    public func invalidate() {
        cached = nil
    }

    /// A human-readable activation state for the Settings pane and the
    /// landing page, distinguishing "not activated" from "activated but
    /// broken" so support conversations do not start from a guess.
    public enum ActivationState: Sendable, Equatable {
        case notActivated
        case active(LicenseDocument)
        case rejected(String)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    public func activationState(now: Date = Date()) -> ActivationState {
        if let document = validatedDocument(now: now) { return .active(document) }
        guard let data = try? Data(contentsOf: licenseURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return gumroadActivationState(now: now)
        }
        switch LicenseDocumentCodec.verify(text, publicKey: publicKey, now: now) {
        case .success(let document):
            return .active(document)
        case .failure(.expired):
            return .rejected("This license has expired.")
        case .failure(.wrongProduct):
            return .rejected("This license is for a different product.")
        case .failure(.invalidSignature):
            return .rejected("This license file is damaged or was not issued for Apple Core.")
        case .failure(.malformed):
            return .rejected("This is not an Apple Core license file.")
        }
    }

    private func gumroadActivationState(now: Date) -> ActivationState {
        guard let record = readGumroadRecord() else { return .notActivated }
        guard let data = try? Data(contentsOf: gumroadRecordURL),
            receiptTrust.read(gumroadRecordURL) == Data(SHA256.hash(data: data))
        else {
            return .rejected("Connect to the internet to verify this Mac's license, or paste your Gumroad key again.")
        }
        if !record.cachedValid {
            return .rejected("Gumroad reports this license key was refunded, disputed, or disabled.")
        }
        return .rejected(
            "This license key has not been re-verified with Gumroad for 14 days. Connect to the internet and activate it again."
        )
    }

    /// Verifies and persists a pasted license envelope. Returns the
    /// verified document on success, or a plain-language reason on failure.
    /// Writing only after verification means a bad paste can never knock
    /// an activated installation back to the unlicensed state.
    public func activate(
        _ text: String,
        now: Date = Date(),
        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) -> Result<LicenseDocument, LicenseActivationError> {
        switch LicenseDocumentCodec.verify(text, publicKey: publicKey, now: now) {
        case .success(let document):
            do {
                try FileManager.default.createDirectory(
                    at: licenseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try write(Data(text.utf8), licenseURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: licenseURL.path)
                activationGeneration = UUID()
                cached = (document, Data(text.utf8))
                return .success(document)
            } catch {
                return .failure(
                    LicenseActivationError("Apple Core could not save the license file: \(error.localizedDescription)")
                )
            }
        case .failure(.expired):
            return .failure(LicenseActivationError("This license has expired."))
        case .failure(.wrongProduct):
            return .failure(LicenseActivationError("This license is for a different product."))
        case .failure(.invalidSignature):
            return .failure(LicenseActivationError("This license file is damaged or was not issued for Apple Core."))
        case .failure(.malformed):
            return .failure(LicenseActivationError("This is not an Apple Core license file."))
        }
    }

    /// Moves the license file to the Trash. Returns false when there was
    /// nothing to remove. Never throws: deactivation is cosmetic and the
    /// worst case is an unreadable file, which the gate already treats as
    /// not activated.
    @discardableResult
    public func deactivate() -> Bool {
        activationGeneration = UUID()
        cached = nil
        try? receiptTrust.write(nil, gumroadRecordURL)
        let fm = FileManager.default
        var removed = false
        for url in [licenseURL, gumroadRecordURL] where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Trash can fail when the volume has no Trash; removing the
                // file is the correct fallback for a re-activatable artifact.
                try? fm.removeItem(at: url)
            }
            removed = true
        }
        return removed
    }
}
