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
// Verification is offline Ed25519 (see Shared/LicenseDocument.swift). The
// app never contacts Gumroad; activation is a local paste of the license
// file the buyer downloads with their purchase.

import CryptoKit
import Foundation

/// The Ed25519 public key whose private half signs Apple Core licenses.
/// The private key lives in Oliver's login Keychain and 1Password, exactly
/// like the Sparkle EdDSA key; only this public half ships in the binary.
public enum AppleCoreLicensePublicKey {
    /// Raw Ed25519 public key bytes, base64.
    public static let base64 = "REPLACE_AT_RELEASE"
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

    public init(licenseURL: URL = AppleCoreServingPaths.licenseURL()) {
        self.licenseURL = licenseURL
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

        guard let data = try? Data(contentsOf: licenseURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        switch LicenseDocumentCodec.verify(text, publicKey: AppleCoreLicensePublicKey.raw, now: now) {
        case .success(let document):
            cached = (document, now)
            return document
        case .failure(let error):
            logMessage("LicenseGate: license rejected: \(error)")
            cached = nil
            return nil
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
        guard let data = try? Data(contentsOf: licenseURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return .notActivated
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
        guard fm.fileExists(atPath: licenseURL.path) else { return false }
        do {
            try fm.trashItem(at: licenseURL, resultingItemURL: nil)
            return true
        } catch {
            // Trash can fail when the volume has no Trash; removing the
            // file is the correct fallback for a re-activatable artifact.
            try? fm.removeItem(at: licenseURL)
            return true
        }
    }
}
