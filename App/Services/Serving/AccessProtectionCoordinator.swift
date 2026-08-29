// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ties the Access client to the stored Cloudflare settings and the Keychain.
//
// Kept out of `CloudflareAccess.swift` on purpose: that file is compiled into
// the test target so the path-scoping rules can be tested without a network,
// and it must not drag `CloudflareSettings` or the Keychain in with it.

import Foundation

/// Applies the Access intent held in `CloudflareSettings`.
///
/// Enabling and disabling both run through here so the stored application ID
/// stays honest: turning protection off deletes the application rather than
/// orphaning it in the account, and turning it on reuses the recorded ID
/// instead of creating a second application over the same page.
public enum AccessProtectionCoordinator {
    public struct Outcome: Sendable, Equatable {
        public let applicationID: String
        public let message: String
    }

    public static func apply(
        settings: CloudflareSettings,
        apiToken: String? = AccessTokenStore.read(),
        session: URLSession = .shared
    ) async throws -> Outcome {
        guard !settings.accountId.isEmpty else { throw CloudflareAccessError.missingAccountID }
        guard let apiToken, !apiToken.isEmpty else { throw CloudflareAccessError.missingAPIToken }

        let client = CloudflareAccessClient(
            accountID: settings.accountId,
            apiToken: apiToken,
            session: session
        )

        guard settings.accessProtectAuthorizePage else {
            guard !settings.accessApplicationID.isEmpty else {
                return Outcome(applicationID: "", message: "The authorization page is not protected.")
            }
            try await client.deleteApplication(id: settings.accessApplicationID)
            return Outcome(
                applicationID: "",
                message: "Cloudflare Access removed from the authorization page."
            )
        }

        let spec = try AccessProtectionSpec(
            hostname: settings.hostname,
            allowedEmails: settings.accessAllowedEmails
        )
        let id = try await client.ensureApplication(for: spec)
        return Outcome(
            applicationID: id,
            message: "Cloudflare Access now protects \(spec.protectedDomain)."
        )
    }
}
