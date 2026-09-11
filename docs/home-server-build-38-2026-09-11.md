# Home Server beta build 38 installation, September 11, 2026

Author: Oliver Ames

Supersedes the build 35 record in `home-server-build-35-2026-09-11.md`, which
remains accurate for that install. Builds 36, 37 and 38 followed on the same
day, each carrying fixes found by testing the previous one through Muse.

## Why four builds in one day

| Build | Carried | Found by |
|---|---|---|
| 35 | The September 11 capability work | — |
| 36 | #48 `notes_create` reporting failure on a note it created, #46 index refresh outliving its client | Live testing of 35 |
| 37 | The coverage work, 186 tools, and the three defects it uncovered | Donor comparison audit |
| 38 | #51 a contacts read aborting the process | Live testing of 37 |

Build 37 crashed Home Server during testing: `CNContactFormatter` raises an
Objective-C exception rather than returning nil when a contact lacks the keys
it needs, and that exception crossing a Swift frame terminates the app. Every
MCP call then returned 503 because the app was gone, not because the tunnel was
down. That is recorded in #51.

## Verified after installation, 2026-09-11

| Check | Result |
|---|---|
| Installed bundle | 2.0.0, build 38 |
| `AppleCorePrerelease` | `beta.1` |
| SHA-256 matched on both machines | `846e486f…0ebf1d` |
| Gatekeeper on the staged copy | accepted, Notarized Developer ID |
| Stapled ticket | validated |
| App running | pid 21264 |
| Local discovery | HTTP 200 |
| Unauthenticated MCP | HTTP 401, correctly refused |
| Public discovery endpoint | HTTP 200 |
| Sparkle running against Apple Core | none, the prerelease gate holds |

## Not published

No appcast item, no R2 upload, no tag, no GitHub release. The public appcast's
newest item is still build 27. `AppleCorePrerelease` keeps Sparkle from
starting at all in this build, so it cannot reach the public feed.

## Open state a future session needs

**The mail index is absent.** It was deliberately cleared before installing
build 37, because the reconciler skips files whose size and modification date
are unchanged, so only a fresh file re-parses the bodies that had been stored
still base64 encoded (#50). Build 37 then crashed before any refresh ran, and
build 38 has not been asked for one.

So `mail_index_status` currently reports empty, and `mail_index_search` will
refuse with `INDEX_BUILDING` after starting a pass rather than answer from a
stale index. Rebuilding takes roughly twenty minutes for this Mac's 11 GB
store, which produced 48,307 messages on the build 35 pass. Nothing is lost;
it simply has to run once.

The previous bundle is retained at `/tmp/Apple Core.app.build37.bak` for
rollback. Existing settings, licence and credentials were not touched.

## Still unverified through a client

`mail_redirect` sends real mail on first use and its JXA half has never
executed. It needs a throwaway account before anyone relies on it. The same
applies, less dangerously, to the other Mail tools added in the coverage pass:
their pure logic is unit tested, their scripting halves are not.
