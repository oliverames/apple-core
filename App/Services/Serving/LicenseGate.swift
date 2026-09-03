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
    /// A cached, verified document plus the wall-clock moment it was
    /// checked, so an expiry that passes while the app is running is
    /// noticed on the next request without re-reading the file.
    private var cached: (document: LicenseDocument, verifiedAt: Date)?

    private let licenseURL: URL
    private let gumroadRecordURL: URL
    private let verifier: GumroadLicense.Verifier
    private var reverifyInFlight = false

    public init(
        licenseURL: URL = AppleCoreServingPaths.licenseURL(),
        gumroadRecordURL: URL? = nil,
        verifier: @escaping GumroadLicense.Verifier = GumroadLicense.liveVerifier
    ) {
        self.licenseURL = licenseURL
        self.gumroadRecordURL =
            gumroadRecordURL
            ?? licenseURL.deletingLastPathComponent().appendingPathComponent("gumroad-license.json")
        self.verifier = verifier
    }

    /// Reads and verifies the license file. Returns nil when there is no
    /// file or it does not verify. The result is cached until the file's
    /// mtime changes or an expiry boundary passes.
    public func validatedDocument(now: Date = Date()) -> LicenseDocument? {
        if let cached, let expires = cached.document.expiresAt, expires < now {
            self.cached = nil
        } else if let cached {
            return cached.document
        }

        if let data = try? Data(contentsOf: licenseURL),
            let text = String(data: data, encoding: .utf8)
        {
            switch LicenseDocumentCodec.verify(text, publicKey: AppleCoreLicensePublicKey.raw, now: now) {
            case .success(let document):
                cached = (document, now)
                return document
            case .failure(let error):
                logMessage("LicenseGate: license rejected: \(error)")
                cached = nil
            }
        }
        guard let record = readGumroadRecord(), record.isEntitled(now: now) else {
            return nil
        }
        if record.needsReverification(now: now) {
            scheduleReverification()
        }
        // Not cached: the record is the cache, and re-reading a small file
        // per session keeps a background re-check visible immediately.
        return record.document
    }

    // MARK: - Gumroad keys

    private func readGumroadRecord() -> GumroadLicenseRecord? {
        guard let data = try? Data(contentsOf: gumroadRecordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GumroadLicenseRecord.self, from: data)
    }

    private func writeGumroadRecord(_ record: GumroadLicenseRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let fm = FileManager.default
        try fm.createDirectory(at: gumroadRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: gumroadRecordURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: gumroadRecordURL.path)
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
        switch await verifier(GumroadLicense.verifyRequestBody(licenseKey: key)) {
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
                cached = nil
                logMessage("LicenseGate: activated Gumroad key \(record.maskedKey)")
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

    private func scheduleReverification() {
        guard !reverifyInFlight else { return }
        reverifyInFlight = true
        Task { await self.reverifyGumroadKey() }
    }

    /// Re-asks Gumroad about the recorded key. A reachable "no" closes the
    /// gate; an unreachable Gumroad changes nothing and the grace window
    /// decides.
    public func reverifyGumroadKey(now: Date = Date()) async {
        defer { reverifyInFlight = false }
        guard var record = readGumroadRecord() else { return }
        guard case .success(let data) = await verifier(GumroadLicense.verifyRequestBody(licenseKey: record.key)),
            let verdict = GumroadLicense.verifyResponse(data)
        else {
            logMessage("LicenseGate: Gumroad unreachable; keeping cached entitlement for \(record.maskedKey)")
            return
        }
        switch verdict {
        case .valid(let purchase):
            record.lastVerifiedAt = now
            record.cachedValid = true
            if let email = purchase.email { record.email = email }
            if let saleID = purchase.saleID { record.saleID = saleID }
        case .revoked:
            record.cachedValid = false
            cached = nil
            logMessage("LicenseGate: Gumroad reports key \(record.maskedKey) is no longer entitled")
        }
        try? writeGumroadRecord(record)
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
        guard let data = try? Data(contentsOf: licenseURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return gumroadActivationState(now: now)
        }
        switch LicenseDocumentCodec.verify(text, publicKey: AppleCoreLicensePublicKey.raw, now: now) {
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
        if record.isEntitled(now: now) {
            return .active(record.document)
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
        switch LicenseDocumentCodec.verify(text, publicKey: AppleCoreLicensePublicKey.raw, now: now) {
        case .success(let document):
            do {
                try FileManager.default.createDirectory(
                    at: licenseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try write(Data(text.utf8), licenseURL)
                cached = (document, now)
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
        cached = nil
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
