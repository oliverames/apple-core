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
