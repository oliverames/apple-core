# Home Server acceptance, September 8, 2026

Author: Oliver Ames

The direct-distribution Apple Core 2.0.0 build 31 is installed at
`/Applications/Apple Core.app` on Home Server. Its signed, stapled bundle passed
Gatekeeper on that host. Hosted mode is enabled, and own-Cloudflare mode is
disabled. The intended connector address is `https://mcp.applecore.app/mcp`.

The following checks used the actual Codex `apple_core_beta` connector after
build 30 installation. System information identified the receiving machine as Home
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

Build 31 adds clearer service descriptions and the Files display name while
retaining the main app's sidebar and full service controls. Its signed export
passed signature and bundled-notice checks. Apple accepted notarization
submission `68a73d53-f6ac-4189-9718-8f84e8cff711`. The transferred ZIP SHA-256 was
`0047ddc0f75b93cbc7ae7adbfc5219970088cdce37e204d2e4e2e1d5573855a4`.
Gatekeeper and the stapled ticket passed on Home Server. The installed version
reports build 31, and only the direct app process is running. Screen Sharing
confirmed the updated settings interface. A fresh Codex system-information
call again identified Home Server after the update.

ChatGPT previously connected but exposed no actions. Successful ChatGPT Work
and Claude.ai connector operations remain required and unverified. Claude.ai
is signed out in Home Server Safari, and the user has been asked to sign in.

Oliver sidelined App Store development and submission to focus on the main
shipping app and hosted beta. The Store test app is closed, with its repository,
installed files, and data preserved. Store work is deferred, not completed.
The active acceptance work remains incomplete until Mail and the outstanding
client connection checks pass.
