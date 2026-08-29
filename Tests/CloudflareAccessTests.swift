// SPDX-License-Identifier: GPL-3.0-or-later
//
// The invariant worth testing here is a negative one: no path through this
// code may produce an Access application that covers the MCP endpoint or the
// two OAuth endpoints clients call without a browser. Everything else is
// payload shape.

import Foundation
import Testing

@Suite("Cloudflare Access protection scope")
struct CloudflareAccessTests {
    private static func spec(
        hostname: String = "applecore.example.com",
        path: String = AccessProtectionSpec.authorizePath,
        emails: [String] = ["owner@example.com"]
    ) throws -> AccessProtectionSpec {
        try AccessProtectionSpec(hostname: hostname, path: path, allowedEmails: emails)
    }

    @Test("The protected domain always carries a path")
    func domainCarriesPath() throws {
        // A bare hostname here is the whole failure mode: Access over the host
        // covers /mcp, and every MCP client stops connecting.
        let spec = try Self.spec()
        #expect(spec.protectedDomain == "applecore.example.com/oauth/authorize")
        #expect(spec.protectedDomain.contains("/"))
    }

    @Test("An empty path is refused outright")
    func emptyPathRefused() {
        #expect(throws: AccessProtectionSpec.SpecError.emptyPath) {
            _ = try Self.spec(path: "")
        }
        #expect(throws: AccessProtectionSpec.SpecError.emptyPath) {
            _ = try Self.spec(path: "   /  ")
        }
    }

    @Test("A hostname with no host is refused")
    func emptyHostnameRefused() {
        #expect(throws: AccessProtectionSpec.SpecError.emptyHostname) {
            _ = try Self.spec(hostname: "  ")
        }
    }

    @Test("A policy with nobody in it is refused")
    func emptyPolicyRefused() {
        // An allow policy with no principals locks the owner out of the very
        // page they need to authorize anything.
        #expect(throws: AccessProtectionSpec.SpecError.noAllowedEmails) {
            _ = try Self.spec(emails: [])
        }
        #expect(throws: AccessProtectionSpec.SpecError.noAllowedEmails) {
            _ = try Self.spec(emails: ["  ", ""])
        }
    }

    @Test("Paths covering machine endpoints are flagged")
    func machineEndpointsFlagged() throws {
        for path in ["mcp", "oauth/register", "oauth/token"] {
            #expect(try Self.spec(path: path).wouldBlockMachineEndpoints, "\(path) should be flagged")
        }
    }

    @Test("A parent path that swallows a machine endpoint is flagged")
    func parentPathFlagged() throws {
        // "oauth" would sit above /oauth/register and /oauth/token.
        #expect(try Self.spec(path: "oauth").wouldBlockMachineEndpoints)
    }

    @Test("The authorization page itself is not flagged")
    func authorizePathAllowed() throws {
        #expect(try !Self.spec().wouldBlockMachineEndpoints)
    }

    @Test("A scheme or trailing path in the hostname is stripped")
    func hostnameNormalised() throws {
        let spec = try Self.spec(hostname: "HTTPS://AppleCore.Example.com/mcp")
        #expect(spec.hostname == "applecore.example.com")
        #expect(spec.protectedDomain == "applecore.example.com/oauth/authorize")
    }

    @Test("Leading and trailing slashes are stripped from the path")
    func pathNormalised() throws {
        #expect(try Self.spec(path: "/oauth/authorize/").path == "oauth/authorize")
    }

    @Test("Emails are lowercased and blanks dropped")
    func emailsNormalised() throws {
        let spec = try Self.spec(emails: [" Owner@Example.com ", "", "  ", "other@example.com"])
        #expect(spec.allowedEmails == ["owner@example.com", "other@example.com"])
    }

    @Test("The application payload is a path-scoped self-hosted app")
    func applicationPayloadShape() throws {
        let payload = CloudflareAccessClient.applicationPayload(for: try Self.spec())
        #expect(payload["domain"] as? String == "applecore.example.com/oauth/authorize")
        #expect(payload["type"] as? String == "self_hosted")
        #expect(payload["app_launcher_visible"] as? Bool == false)
    }

    @Test("The policy payload allows exactly the listed emails")
    func policyPayloadShape() throws {
        let spec = try Self.spec(emails: ["a@example.com", "b@example.com"])
        let payload = CloudflareAccessClient.policyPayload(for: spec)
        #expect(payload["decision"] as? String == "allow")
        let include = payload["include"] as? [[String: [String: String]]]
        #expect(include?.count == 2)
        #expect(include?.first?["email"]?["email"] == "a@example.com")
    }
}
