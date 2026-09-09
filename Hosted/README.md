# Apple Core hosted access

Private beta implementation for Apple Core 2.0. Home Server direct build 32
has passed service smoke checks through the requested clients. Full operation
and onboarding acceptance remains open. See ../docs/read-only-acceptance-2026-09-09.md.
Do not advertise general availability until acceptance passes.

## Security boundary

The advertised resource is `https://mcp.applecore.app/mcp`. Every installation
has a separate relay identity. The Mac makes an outbound TLS connection; users
never receive the operator's Cloudflare credentials. Existing self-hosted
Cloudflare tunnels remain supported.

Hosted access must preserve the Mac's OAuth PKCE verification, per-client
approval, token revocation, session ownership, and enabled-service controls.
Routing identifiers alone must never authorize a request. The relay credential
must be separate from the token that grants access to Apple data.

Beta enrollment uses expiring, single-use invitations. Direct-distribution
hosting billing remains deferred. The separate Store release now includes a
USD 2.99 monthly subscription milestone; see STORE_SUBSCRIPTIONS.md. Existing
direct app licensing remains separate.

The operator and Cloudflare process traffic in transit; this is not an
end-to-end encrypted channel between the MCP client and the Mac. Do not retain
request bodies, response bodies, authorization headers, authorization codes,
or setup codes in logs or persistent relay storage.

## Operation

Install development dependencies with `npm ci` in this directory, and run
`npm test`. The suite runs a deployment build, protocol tests, and real
Cloudflare-runtime tests with two isolated mock Macs. It covers concurrent
invitation redemption, replay, wrong-device credentials, duplicate sockets,
header filtering, metadata signatures, code and token routing, and revocation.
The Mac's existing OAuth tests separately cover authorization policy; a mocked
relay test is not a substitute for the real-client acceptance checks below.

Deploy with `npx wrangler deploy`. The operator's Cloudflare credentials stay
in the deployment environment. `ADMIN_SECRET` and `METADATA_SECRET` are Worker
secrets, with their operator copy stored in the Development vault item
**Apple Core Hosted Beta**. Do not rotate the metadata key casually: existing
registered client metadata URLs depend on it.

To issue an invitation, provide the admin secret through a secret manager as
`APPLE_CORE_HOSTED_ADMIN_SECRET`, then run `node admin.mjs invite`. The result
is a sensitive setup code valid for 30 minutes and one redemption. Deliver it
privately. `node admin.mjs revoke TENANT_ID` disconnects that installation and
invalidates its relay credential. Operator revocation does not delete Apple
data or the Mac's local client registrations.

In Apple Core, turn off an existing remote connection before changing
providers. Choose **Hosted by Apple Core**, paste the invitation, and connect.
The app stores its per-device credential inside its private configuration
directory (directory mode 0700, file mode 0600), with a hardware ownership
check so a copied config does not start a second connector on another Mac.
Turning hosted access off stops its outbound connection and keeps its setup
for reconnection. Self-hosted tunnel settings remain stored separately.

Add `https://mcp.applecore.app/mcp` to the client. OAuth asks for the app's
Connection ID and Apple Core token. The copied hosted token also works with
bearer-capable clients. OAuth approval occurs on the Mac; the hosted layer
only wraps codes and tokens with a routing identifier. Editing that identifier
does not bypass the destination Mac's token or session checks.

## Beta limitations

- Four in-flight requests per Mac, 1 MiB request bodies, 8 MiB responses, and a
  90-second request deadline. Oversized responses terminate the connection;
  they are never returned as truncated successful results.
- Streamable HTTP POST and DELETE are supported. Optional standalone GET SSE
  subscriptions and the older `/sse` transport are not implemented in hosting.
  POST responses are buffered at the edge until complete. Large captures may
  exceed the beta response limit.
- Hosting is not an always-on copy of the Mac: an offline or sleeping Mac
  returns an unavailable response. The app reconnects with bounded backoff.
- Billing, public signup, customer recovery, and self-service credential
  rotation are not included. A revoked or lost setup currently needs operator
  assistance before enrolling again.
- Existing self-hosted OAuth clients need reconnection when switching to the
  shared hosted issuer. The app does not migrate their token grants.
- `AppleCorePrerelease` in `App/Info.plist` labels this build `2.0.0-beta.1`
  and prevents it from consuming the stable Sparkle feed. Install betas
  manually; remove that key deliberately when preparing the stable release.

## Release acceptance

- Existing configurations decode without changing self-hosted behavior.
- Onboarding explains hosted and own-Cloudflare options, including the need
  for the Mac to remain running and connected.
- Enrollment expires, is single-use, and rejects replay and revoked devices.
- A second tenant cannot use another tenant's credentials or sessions.
- OAuth tests cover PKCE, redirect binding, resource binding, expiry,
  refresh rotation, replay, and revocation.
- Disconnects terminate outstanding requests and reconnect safely.
- Request and response sizes, concurrency, and connection time are bounded.
- Public branding routes serve the app icon without exposing tenant data.
- Build, unit tests, signed beta packaging, and notarization pass.
- Install on home-server and verify its version and existing permissions.
- Connect ChatGPT Work and Codex through their actual authorization flows.
- Run read-only checks for each enabled service and report unavailable
  permissions separately from failures. Never invoke write tools as probes.
- Keep the beta out of the stable Sparkle feed and Gumroad download.

## Usage containment

The configured beta policy allows each installation 2,000 admitted forwarding
attempts per UTC day and 20,000 per UTC month. MCP and OAuth forwarding share
these atomic counters. Failures after admission still count. Day and month
windows reset independently. This is a per-installation allowance, not an
aggregate account limit, authenticated-success counter or dollar cap.

`node admin.mjs usage TENANT_ID` returns only UTC windows, counts, limits and
pause state. `pause TENANT_ID` stops new ordinary forwarded work, and
`resume TENANT_ID` restores it without clearing counters. Administrator commands
use the existing secret-manager environment variable. Usage and pause state
persist across Worker deployments. Missing or invalid quota configuration
rejects ordinary forwarded work with 503. Exhaustion returns 429.

Set the Worker variable `HOSTED_PAUSED` to `true` and deploy to stop new public
pairing, relay connection and ordinary forwarding work before object access.
Discovery and authenticated administration remain available. Previously
admitted work may finish. Per-installation pause also leaves its socket open
and hibernatable. Neither kind of pause deletes records or resets credentials.

OAuth grant revocation remains available while paused or exhausted, under the
existing edge rate, request size, concurrency and deadline bounds. Revocation
does not consume ordinary forwarding quota. This deliberate recovery exception,
bridge traffic, rejected incoming requests, Durable Object storage and other
Cloudflare services can still incur costs. The explicit 50 ms Worker CPU limit
caps per-request CPU, not monthly spending or relay wall time.

Only one operator-managed tester is currently intended. Before issuing further
invitations, add aggregate admission/tenant limits and verify actual metered
usage. Do not multiply this installation allowance across new testers and
claim the same budget. The chosen operating budget and account billing figures
are recorded privately. The public Google Form never provisions access.

The tests cover atomic concurrent admission, tenant independence, UTC rollover,
pause/resume without counter reset, missing configuration, invalid/expired
invitations, global pause and revocation recovery. Test-only expiry/storage
controls are confined to a separate entry point and absent from the production
bundle. Passing fixtures are not evidence of a deployed quota.
