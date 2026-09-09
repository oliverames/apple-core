# Home Server acceptance, September 8, 2026

Author: Oliver Ames

The direct-distribution Apple Core 2.0.0 build 32 is installed at
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

Claude.ai's old Apple Core connector at `https://applecore.amesvt.com/mcp`
was removed at Oliver's request. Its replacement, Apple Core Hosted Beta,
uses `https://mcp.applecore.app/mcp`, required OAuth, and Anthropic's hosted
client metadata. Authorization identified Home Server. After refreshing the
tools list, Claude exposed 73 read-only and 55 write/delete tools. Existing
default approval requirements were preserved.

The actual Claude chat verified Home Server's identity and repeated the twelve
service checks above against build 31. Eleven passed; Mail again returned
`APP_NOT_RUNNING`. The first capture check used an incorrect bundle identifier,
so it was repeated with `com.oliverames.applecore`; the corrected call matched
one Apple Core window. No media was captured. The test conversation is
https://claude.ai/chat/86ce6881-c398-422d-89b4-eaf7c906978f.

ChatGPT's disconnected Apple Core Beta duplicate was uninstalled. Only Apple
Core Hosted Beta remains installed. Its developer definition is retained.
Before build 32, the hosted entry remained connected but exposed no actions after refresh.
A fresh Work test launched from its Try in chat button explicitly selected
that plugin and requested only System Information. Work reported its tools
unavailable and did not execute the call. Evidence:
https://chatgpt.com/c/6aa073a4-67f0-83e9-9ebf-024866afcb15.
This is a failed Work acceptance check, not a successful Home Server read.
The same test in Chat mode also exposed no callable tools:
https://chatgpt.com/c/6aa07449-98d4-83ea-b1ae-282d65e92ac3.
Inspection of the actual Refresh request found HTTP 424 with JSON-RPC error
`-32603`: “The data couldn’t be read because it isn’t in the correct format.”
The pinned Swift MCP SDK decodes experimental client capabilities as strings,
whereas ChatGPT supplies a structured value. This matches upstream issue
https://github.com/modelcontextprotocol/swift-sdk/issues/262.
The compatibility adapter now filters unsupported experimental values only
during initialization. Two isolated regression tests passed, covering preservation
of other initialization fields and unchanged unrelated or malformed requests.
Build 32 was signed and notarized under submission
`4d1ae31c-fc97-4e07-8cea-1246e9a952fc`, which Apple accepted. Its transferred ZIP
SHA-256 is `65fddf2b2a291935f5da23333ef2059165c6975c33f5558ba3df30678df2a759`.
The checksum, signature, Gatekeeper assessment, and stapled ticket passed on
Home Server. The installed bundle reports build 32 and its direct app is running.
ChatGPT Refresh then successfully discovered all 128 tools. This verifies that
the adapter resolves the discovery failure against the actual installed app.
The subsequent actual ChatGPT Work test identified Home Server and passed eleven
of the twelve service checks. Mail returned `INVALID_ARGUMENT`, a different
reported code from earlier client checks, and requires further diagnosis.
The Work test is https://chatgpt.com/c/6aa07723-2794-83ea-99ba-ceada9d8bcfd.
Oliver granted permission to terminate Mail's stale Home Server process and
reopen Mail. The restart has not occurred. The subsequent SSH attempt failed
because the local Mac was locked and its credential agent could not sign.
Do not ask again for the already granted restart permission. Resume after
unlocking the local Mac and restoring SSH authorization. Track the remaining
work in https://github.com/oliverames/apple-core/issues/5.

Oliver sidelined App Store development and submission to focus on the main
shipping app and hosted beta. The Store test app is closed, with its repository,
installed files, and data preserved. Store work is deferred, not completed.
The active acceptance work remains incomplete until Mail and the outstanding
client connection checks pass.

## Mail recovery follow-through, September 8 at 10:11 p.m. Eastern

The previously approved recovery was performed through Screen Sharing. The
server reported that Mail was not open anymore despite listing its process in
Force Quit Applications. Mail was selected and Force Quit was confirmed.
Subsequent connector calls succeeded, establishing recovery without a reboot.

Fresh `mail_list_accounts` calls passed through the direct Codex connector,
the ChatGPT Work connector, and the existing Claude.ai verification chat linked
above. Each returned two accounts. One is enabled and one disabled, which is
configuration evidence rather than a reason to change account settings. No
messages were read or sent, and no account setting was changed.

This resolves the Mail service-access failure. It does not expand the earlier
smoke checks into exhaustive testing. The independent SSH attempt still failed
at credential-agent signing after the workstation was unlocked. SSH is a
separate administration limitation, not a remaining Mail connector failure.
Other client/enrollment acceptance remains tracked in the repository issues.
