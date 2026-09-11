# Home Server beta build 35 installation, September 11, 2026

Author: Oliver Ames

Tracking: https://github.com/oliverames/apple-core/issues/45

## What was installed

Apple Core 2.0.0 build 35, carrying the September 11 capability work: binary
file writes, the local mail index and its search, reminder subtask hierarchy
through ReminderKit, contact account targeting, Full Disk Access as an optional
permission, place identity, and the capture and maps corrections.

Signed with Developer ID, notarized (submission
`83a23349-b69d-46f2-a11e-619398e90c6f`, Accepted), stapled, and validated
before transfer. The zip's SHA-256 matched byte for byte on both machines:
`c0c72b3e25187437cf3cde38767550a008965ff44d2199ec9b384efb9e988939`.

## Not published

This build was deliberately not released. No appcast item, no R2 upload, no tag
and no GitHub release. The public appcast's newest item remains build 27.

The app carries `AppleCorePrerelease`, and `startUpdaterIfNeeded()` returns
false for a prerelease, so Sparkle never starts in this build and it cannot
reach the public feed. Confirmed after installation: no Sparkle process is
running against Apple Core.

## A staged downgrade was found and removed

Home Server was holding a Sparkle installer parked since September 5 at
08:36, six days, with a fully staged **Apple Core 1.7.2** and its zip in
`~/Library/Caches/com.oliverames.applecore/org.sparkle-project.Sparkle/Installation/`.
Had it ever completed, the machine would have silently downgraded from the
2.0.0 beta to a public 1.7.2 build.

The cause, which the August 30 occurrence left unestablished: Sparkle stages an
update and then waits for the app to quit before swapping the bundle. Home
Server is headless and always on, so nobody ever quits the menu-bar app and the
wait never ends. The installer outlived two app replacements, since nothing
reaps an updater left behind by a previous version. The prerelease gate does
not help, because this installer was started by an earlier non-beta build.

Both processes were killed and the staged installation removed before
installing. That is a workaround on one machine; the fix is tracked in #45.

An identical parked pair exists for **Skylight Bridge**, a different app, which
confirms this is a property of the machine rather than of Apple Core. It was
left untouched.

## Verification after installation

| Check | Result |
|---|---|
| Installed bundle version | 2.0.0, build 35 |
| `AppleCorePrerelease` | `beta.1` |
| Gatekeeper on the staged copy | accepted, `source=Notarized Developer ID` |
| Stapled ticket on the staged copy | validated |
| App running | pid 14939 |
| Listening | 127.0.0.1:8756 |
| Local discovery | HTTP 200 |
| Unauthenticated MCP request | HTTP 401, correctly refused |
| Public discovery endpoint | HTTP 200 |
| Sparkle running against Apple Core | none |
| Both cloudflared tunnels | running |

The previous bundle is retained at `/tmp/Apple Core.app.build34.bak` on Home
Server for rollback. Existing settings and credentials were not touched.

## Not verified

No tool was exercised through a client. The 152-tool surface, and in particular
today's new tools, have not been called against this installation. That is the
next acceptance step and needs a connected client.
