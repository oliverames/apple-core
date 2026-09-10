# Hosted OAuth Connection ID, September 10, 2026

Author: Oliver Ames

Tracking: https://github.com/oliverames/apple-core/issues/12

## Diagnosis and changes

The hosted setup view already contained a Connection ID, but Settings > Access rendered that view only when self-hosted Cloudflare was enabled or running. Hosted-only configurations could hide the entire section. The Access pane now includes hosted mode, offers a separate Copy Connection ID button, and explains when to use the token. Selecting This Mac only also stops hosted access. Self-hosted authorization-page protection controls are hidden in hosted mode.

The hosted authorize page now gives the Settings path and explains that existing tokens contain the Connection ID before the tilde. It continues accepting only a 32-character lowercase hexadecimal ID. Accepting a full credential in this GET form would put it in the request URL.

## Verification and delivery

- All 20 hosted tests passed, including routed parameter preservation and rejection of a full token without forwarding it.
- Debug app and CLI compilation passed with signing disabled. No app was launched or installed on the development Mac.
- Worker deployment: `d0c9fff0-c72e-432a-918d-ca55223a76be`.
- The public authorize page returned the new copy, ID-only pattern, and Continue button after deployment.
- Home Server reports Apple Core 2.0.0 build 33. The updated Mac UI is source-only pending a signed build and installation.

## Token endpoint observation

A bogus grant POST from Home Server returned HTTP 400 with `invalid_grant`. A local probe using `Python-urllib/3.11` produced the same response, and unauthenticated MCP returned 401. These establish Worker reachability from those routes, not successful code exchange or reachability from the reporter's Linux proxy.

The initial Python urllib GET to the browser authorization page returned 403. A curl GET succeeded. The browser route remains protected separately from machine-to-machine endpoints, consistent with the September 9 diagnosis. No security rules were changed.

A recent one-hour Home Server unified-log search found no OAuth request evidence. It does not prove absence of requests. The previous diagnosis records disabled Worker observability and unavailable historical telemetry. No historical connector token request was recovered in this investigation. A fresh real connector attempt with a live Worker tail remains necessary to distinguish client proxy blocking from downstream failure.

## Follow-up

Issue #12 tracks signed Mac delivery and UI acceptance, real connector code exchange with tracing, and optional age-based expiry. Existing client retention removes inactive records only above the 256-client capacity, preserving live tokens and authorization codes. No existing registrations were deleted. Hosted registration is stateless, while native approval rendering adopts client metadata.

## Completed installation and Muse acceptance

Build 34, source commit `f52d095`, was signed with Developer ID and installed over SSH at `/Applications/Apple Core.app` on Home Server on September 10, 2026. Apple accepted notary submission `beeb390f-4a4a-4155-9532-5af223f06ae5`. The receiving host verified the ZIP checksum, strict signature, Gatekeeper acceptance and stapled ticket. The previous app was moved to Trash. The running executable and bundle both identify the installed build.

ZIP SHA-256: `c344716d820775ba18f370ece4d516c5c98bc44133229c324e8dc51d9a5c6e97`.

The Xcode result reports 207 tests passed, including 222 executed cases with parameterized runs, zero failures and zero skips. The 20 hosted tests passed before deployment. Bundled third-party notices match all 14 pinned dependencies and four source donors. No stable updater feed or public binary was published.

Immediately after restart and before new consent, semantic hashes matched for every field in `config.json`, `oauth_clients.json`, `oauth_tokens.json`, and `mail_templates.json`. New Muse consent subsequently added the intended trust and credential state. Screen Sharing verified the installed Access pane displays hosted connection status, a separately labeled Connection ID and Copy Connection ID button.

Safari was already signed into Muse. The original connector and its first replacement failed inside Muse before opening Apple Core authorization. Muse reported recreating the definition under `custom.apple-core`. That attempt succeeded. The exact cause of the earlier Muse setup failure was not exposed, so recreating the name is a successful recovery, not a proven root cause.

A sanitized live Worker tail correlated the successful browser flow: registration 201, authorization page 200, approval POST 303, and code exchange POST `/oauth/token` 200 at approximately 16:26 EDT. Subsequent authenticated MCP calls returned 200. The Linux proxy error did not recur on the actual connector exchange.

Muse reported these live results through its new connector:

- Initialization negotiated protocol `2025-06-18` and identified `Apple Core 2.0.0-beta.1`. This is expected: the bundle extension appends the checked-in prerelease label to marketing version 2.0.0. The installed build number is 34.
- `tools/list` exposed 128 tools.
- `notes_health_check` returned healthy and confirmed Notes.app is reachable through Apple Events.
- `utilities_system_info` identified Home Server, macOS 26.6.2 build 25G83 and eight cores.
- A second `notes_health_check` from a fresh `bin/apple-core-mcp` process also passed.

Muse diagnosed its initial tools/list 400 as its shared client failing to forward the `Mcp-Session-Id` returned during initialization. Muse repaired its local `_shared/bin/mcp.py` and reported two passing isolated tests in `_shared/tests/test_mcp_session.py`. Those files are on the Muse VM, not this checkout. Muse confirmed the directory has no Git repository, so upstream issue filing and repository persistence for that client fix remain blocked by missing ownership. Do not claim this Apple Core commit contains that separate fix.

No personal note bodies were read and no Apple app data writes were used for acceptance. Age-based client expiry remains optional follow-up in https://github.com/oliverames/apple-core/issues/13. This acceptance completes the installation and real Muse OAuth/MCP work from issues #11 and #12.

## Muse client repository ownership resolved

Later on September 10, Oliver approved Apple Core as the repository for the Muse
integration helper. `Integrations/Muse/bin/mcp.py` now preserves the full client
exported through Muse, including its session-header fix. The Muse platform's
credential module remains an external runtime dependency. Installation and
single-endpoint process constraints are documented alongside the helper.

Python compilation and both isolated regression tests passed locally. Removing
the resend behavior in an in-memory mutation made the session test fail as
expected. CI now includes these tests. The final test transport uses a reserved
`.invalid` endpoint and patches the client's actual transport object.

Muse confirmed its live file matches SHA-256
`d6c015d1f8eac0e46d29a603684aa8397a8e3e35de7460613017e5c64e49e27d`,
the checksum of the committed client source. Fresh-process acceptance again
returned 128 tools and a healthy Notes.app result. The already-installed helper
matches this source, so no replacement or credential change was necessary.
This resolves the earlier missing-ownership blocker without a Mac app release.
