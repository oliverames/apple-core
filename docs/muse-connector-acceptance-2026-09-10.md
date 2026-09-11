# Muse connector acceptance, September 10, 2026

Author: Oliver Ames

Tracking: https://github.com/oliverames/apple-core/issues/6

## Task list

- [x] Recheck public discovery and unauthenticated boundaries.
- [x] Run hosted isolation and routing regression tests.
- [x] Receive Muse tool inventory, schema validation, and service checks.
- [x] Exercise session lifecycle and error handling through Muse.
- [x] Exercise safe disposable writes and verify cleanup where available.
- [x] Record operation-level exclusions and track confirmed defects.
- [x] Consolidate parallel capability reviews for Notes/Mail, personal apps,
  and system surfaces in `docs/research/`.

## Sweep outcome

The full sweep completed on September 10, 2026, after the wrapper probes were
stopped and replaced with a single-session harness that sends DELETE in a
`finally` block. Both the report and the handoff brief are published in
https://gist.github.com/oliverames/6aaadd7531c34edf38a57e9f76d31ab1 and
tracked in issue #16.

Of 128 tools, 60 passed, 68 were not exercised with a stated reason each, and
none failed. All 128 passed schema validation. The Mail template fixture and a
Documents UUID-folder filesystem fixture both passed with verified cleanup.
Every owned session was deleted with HTTP 202, and no user session was touched.

Two defects came out of the sweep. The wrapper session leak is issue #14, found
when repeated probes drove `initialize` to HTTP 503 `Too many active sessions`.
The inconsistent not-found contract in `mail_get_template` and
`filesystem_stat` is filed separately. Both harness defects found during the
run were in the harness, not in the server.

The capability reviews are in `docs/research/`, and their findings are filed as
issues rather than left in the documents.

## Current evidence

Local public-origin probes returned discovery 200, unauthenticated MCP 401
with both `muse-mcp-client/1` and `Python-urllib/3.11`, invalid bearer 401, and
bogus token grant 400. The authorize landing page returns 200 before connection
selection by design. No credential was used in these probes.

All 20 hosted tests passed with local Miniflare fixtures. These cover enrollment,
isolated device routing, malformed credentials, forwarding restrictions,
bounded bodies, authorization routing, quota/pause behavior, and store ownership
validation. This does not establish live OAuth refresh or revocation through Muse.

The previous real Muse authorization and code exchange passed on September 10,
as recorded in `oauth-connection-id-2026-09-10.md`. Its persisted client source
matched Muse's running file by checksum and passed two local session tests.
Those earlier results are distinguished from this broader acceptance sweep.

Additional live unauthenticated probes rejected hostile-origin approval (403),
malformed Connection ID (400), and a JavaScript redirect URI at registration
(400). No live registration was created by these negative probes.

Forty unchanged Swift tests passed in a temporary Swift package containing
`OAuthSupport.swift`, `ClientIDMetadataDocument.swift`, and the existing
OAuth support, OAuth regression, and client metadata test suites. They exercise
refresh rotation, client/resource binding, revocation, persistence failures,
registration churn and metadata validation. No Apple Core app was launched on
the development Mac. Expected simulated persistence failures were logged by
the negative tests. These are isolated tests, not live Muse refresh/revocation.

Muse's first progress report: 26 of 128 tools probed, no failures. Identity
confirmed as Home Server, macOS 26.6.2 build 25G83. Only tools are advertised,
so resources and prompts have no advertised surface to exercise.
