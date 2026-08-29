// SPDX-License-Identifier: GPL-3.0-or-later
//
// Durable trust is keyed on `trustKey`. These cover the two ways that key can
// go wrong: forgetting a client that was trusted, and remembering one that
// should have stopped being trusted.

import Foundation
import Testing

@Suite("Authenticated principal trust keys")
struct AuthenticatedPrincipalTests {
    private static func bearer(_ token: String) -> AuthenticatedPrincipal {
        .sharedBearer(tokenFingerprint: OAuthSupport.tokenFingerprint(token))
    }

    @Test("The shared token can be trusted at all")
    func sharedTokenCanBeTrusted() {
        // The regression this guards: `canBeTrusted` was false for the shared
        // token, so the dialog hid "always allow" and every reconnect asked
        // again with no way to stop it.
        #expect(Self.bearer("s3cret-token").canBeTrusted)
    }

    @Test("The same token always produces the same trust key")
    func sharedTokenKeyIsStable() {
        // Trust is useless if the key moves. The old subject was a fresh UUID
        // per connection, which could never match a stored entry.
        #expect(Self.bearer("s3cret-token").trustKey == Self.bearer("s3cret-token").trustKey)
    }

    @Test("Rotating the token revokes the trust granted to the old one")
    func rotatingTheTokenChangesTheKey() {
        #expect(Self.bearer("old-token").trustKey != Self.bearer("new-token").trustKey)
    }

    @Test("The trust key never contains the token itself")
    func keyDoesNotLeakTheToken() {
        // The key is written to preferences in the clear, so it must not be a
        // way to read the live secret back out.
        let token = "a-very-secret-token"
        #expect(!Self.bearer(token).trustKey.contains(token))
    }

    @Test("An OAuth client's trust key is its bare client ID")
    func oauthKeyIsUnprefixed() {
        // Entries persisted under `trustedOAuthClientsV2` before the shared
        // token could be trusted stored the raw client ID. Prefixing it here
        // would silently un-trust every client already approved.
        let principal = AuthenticatedPrincipal.oauth(
            clientID: "ames_abc123",
            registeredName: "Claude"
        )
        #expect(principal.trustKey == "ames_abc123")
    }

    @Test("The shared token still has no OAuth client ID")
    func sharedTokenHasNoOAuthClientID() {
        // `oauthClientGate` keys session generations on `trustedClientID`. If
        // the shared token started reporting one, the gate would not recognise
        // it and would refuse the session outright.
        #expect(Self.bearer("s3cret-token").trustedClientID == nil)
    }

    @Test("An OAuth client keeps reporting its client ID to the session gate")
    func oauthKeepsItsClientID() {
        let principal = AuthenticatedPrincipal.oauth(
            clientID: "ames_abc123",
            registeredName: "Claude"
        )
        #expect(principal.trustedClientID == "ames_abc123")
    }

    @Test("Two different principals are never the same trust subject")
    func principalsDoNotCollide() {
        let bearerKey = Self.bearer("ames_abc123").trustKey
        let oauthKey = AuthenticatedPrincipal.oauth(
            clientID: "ames_abc123",
            registeredName: "Claude"
        ).trustKey
        // A token whose fingerprint happened to read like a client ID must not
        // inherit that client's approval.
        #expect(bearerKey != oauthKey)
    }

    @Test("The shared token is labelled as covering every client that has it")
    func sharedTokenIsHonestlyLabelled() {
        let principal = Self.bearer("s3cret-token")
        #expect(principal.trustDisplayName == "Any client with the shared token")
        #expect(principal.alwaysTrustTitle.contains("shared token"))
    }
}
