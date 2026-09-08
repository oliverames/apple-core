# Home Server acceptance, September 8, 2026

Author: Oliver Ames

The direct-distribution Apple Core 2.0.0 build 30 is installed at
`/Applications/Apple Core.app` on Home Server. Its signed, stapled bundle passed
Gatekeeper on that host. Hosted mode is enabled, and own-Cloudflare mode is
disabled. The intended connector address is `https://mcp.applecore.app/mcp`.

The following checks used the actual Codex `apple_core_beta` connector after
installation. System information identified the receiving machine as Home
Server. Personal response content was not included in this report.

| Service | Read-only operation | Result |
| --- | --- | --- |
| Calendar | List calendars | Pass |
| Capture | List Apple Core windows only | Pass |
| Contacts | Search for a synthetic nonmatching name | Pass |
| Filesystem | List shared roots | Pass |
| Location | Current location | Pass |
| Mail | List accounts | Fail: `APP_NOT_RUNNING` |
| Maps | Search Burlington, Vermont | Pass |
| Messages | List one recent chat | Pass |
| Notes | List accounts | Pass |
| Reminders | List reminder lists | Pass |
| Shortcuts | List folders | Pass |
| Utilities | System information | Pass |

These are service-access smoke checks, not exhaustive verification of every
read operation. No write operation was tested against personal data. Mail
requires further diagnosis on Home Server without discarding unsaved drafts.

ChatGPT previously connected but exposed no actions. Successful ChatGPT Work
and Claude.ai connector operations remain required and unverified. The Store
variant has separate permissions and must pass its own runtime checks. Its
build 30 source merge does not mean that build is installed or submitted.

The overall work remains incomplete until those checks, subscription delivery,
remaining Store services, and actual Apple Review submission are complete.
