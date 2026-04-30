# icloud-mcp (MrGo2) — Review
**URL:** https://github.com/MrGo2/icloud-mcp
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Carlos Lorenzo (GitHub: MrGo2)
- **License:** MIT (declared in README and package.json; no LICENSE file checked into repo)
- **Last commit:** 2026-01-13 (commits in last 90 days: 0)
- **Activity signal:** Dormant. Total of 4 commits, all on 2026-01-13. Reached "v2.0.0" with the dual-mode addition then went quiet.

## Stack
- **Language / runtime:** Node.js (>=18), CommonJS, no TypeScript
- **MCP transport(s):** stdio only; hand-rolled JSON-RPC over `readline` line-buffered stdin (does not use `@modelcontextprotocol/sdk`)
- **Build / install path:** `git clone` then `npm install`; entry point is `node index.js`
- **Distribution:** Source-only on GitHub. No npm publish, no npx shim, no Docker, no MCPB bundle.

## Apple surfaces covered
- Mail.app / iCloud Mail (AppleScript local + IMAP/SMTP cloud)
- Calendar.app / iCloud Calendar (AppleScript local + CalDAV cloud via `tsdav` + `ical.js`)
- Contacts.app / iCloud Contacts (AppleScript local + CardDAV cloud via `tsdav`)
- Reminders.app (AppleScript only)
- Notes.app (AppleScript only; create + read, no edit)
- Messages.app (AppleScript only; send-only, no read)
- Safari.app (AppleScript only; tabs and URLs)
- iCloud Drive: not covered (README explicitly punts to "requires CloudKit")
- iCloud Photos / Find My / iCloud Mail aliases / Keychain: not covered

## Tool inventory
31 tools in local mode, 17 in cloud mode. Grouped:
- Auth (2): about, check-auth-status
- Email (6): list-emails, read-email, send-email, search-emails, mark-as-read, list-folders
- Calendar (5): list-events, list-calendars, create-event, update-event, delete-event
- Contacts (5): list-contacts, search-contacts, read-contact, create-contact, delete-contact
- Reminders (7, local): list-reminder-lists, list-reminders, create/update/complete/delete-reminder, search-reminders
- Notes (5, local): list-note-folders, list-notes, read-note, create-note, search-notes
- Messages (1, local): send-message
- Safari (4, local): list-safari-tabs, get-current-safari-url, open-safari-url, close-safari-tab

## How it talks to Apple / iCloud
The hallmark of this server is its dual-mode design, picked at startup via `USE_LOCAL_MODE` env var, with auto-fallback to cloud on non-darwin platforms. **Local mode**: every "local-client.js" shells out to `osascript` via `child_process.spawn`, piping the script through stdin (the `f75422f` fix). It mixes classic AppleScript (`tell application "Mail"…`) for writes and JXA (`Application('Notes')`) for reads that need JSON. **Cloud mode**: standard internet protocols against documented Apple endpoints — `imap.mail.me.com:993` via the `imap` package with `mailparser`, `smtp.mail.me.com:587` with `nodemailer`, and `caldav.icloud.com` / `contacts.icloud.com` via `tsdav` with `ical.js` for VEVENT parsing. There is no pyicloud-style reverse-engineered web API, no CloudKit Web Services, and no SQLite peeking into `~/Library` caches.

## Permissions / TCC model
Local mode rides macOS Automation TCC: first call to each app triggers the system prompt; user has to grant in System Settings > Privacy & Security > Automation. No bundle identifier is set (it runs as `node`, so the prompt names "node" or the parent terminal). Cloud mode uses iCloud app-specific passwords stored in plain text in a `.env` file via `dotenv`; no Keychain integration, no encryption at rest, and `check-auth-status` echoes the email address back. 2FA is sidestepped entirely by the app-specific-password mechanism, which is the sanctioned Apple path.

## Testing posture
None. No `test/`, `__tests__/`, `*.test.js`, jest/mocha config, or CI workflow file (`.github/`). The only "test" affordance is `npm run test-mode` which sets `USE_TEST_MODE=true` (the flag is logged but not actually wired into any tool path) and `npm run inspect` which spawns `@anthropics/inspector`.

## Notable strengths (worth stealing)
- Clean dual-mode topology: `<surface>/index.js` dispatches between `local-client.js` (AppleScript) and `<protocol>-client.js` (IMAP/CalDAV/CardDAV) per service. Easy mental model.
- `utils/applescript.js` is small and reusable: `runAppleScript`, `runJXA`, `runJXAWithJSON`, plus `escapeAppleScript`/`escapeJXA` and a typed `AppleScriptError` that maps known stderr substrings to `PERMISSION_DENIED` / `APP_NOT_RUNNING` / `NOT_FOUND` codes.
- Stdin-based `osascript` invocation (rather than `osascript -e`) cleanly handles multi-line scripts and avoids argv length limits — worth copying.
- Use of `tsdav` plus `ical.js` is the right call for CalDAV/CardDAV instead of hand-rolling XML, and re-uses cached `DAVClient` per process.
- Sensible non-darwin fallback: requesting local mode on Linux silently degrades to cloud mode rather than crashing.

## Gotchas / things to avoid
- App-specific passwords sit in `.env` plain text with no Keychain or 1Password fallback. `getCredentials()` reads straight from `process.env` and there is no rotation path.
- `escapeAppleScript`/`escapeJXA` are simple `String.replace` chains; they will not safely handle every Unicode edge case or AppleScript's quirky character handling. Treat as a defense, not a guarantee, against script-injection from tool arguments.
- Hand-rolled JSON-RPC framing in `index.js` is line-buffered with naive accumulation — any embedded newline inside a JSON string body could desync the parser. Adopt the official `@modelcontextprotocol/sdk` instead of cloning.
- Hardcoded Spanish-locale defaults: `TIMEZONE: 'Europe/Madrid'`, `DATE_FORMAT: 'es-ES'`. Will silently produce wrong dates for non-Spain users unless overridden.
- Notes "create" composes HTML inline by string concatenation (`<h1>${title}</h1><br>${body}`) after only basic escaping — fertile ground for HTML injection that survives into the user's Notes database.
- "Cloud mode" name is misleading: it is just iCloud's standard email/CalDAV/CardDAV. There is no iCloud Drive, Photos, Find My, Reminders-via-CalDAV, or CloudKit, despite the repo name.

## License compatibility for our combined project
MIT is fully compatible with both MIT and Apache-2.0 downstream relicensing; only requirement is preserving Carlos Lorenzo's copyright notice if any source is reused.

## Verdict
A tidy reference implementation of the AppleScript-vs-iCloud-protocol split, valuable mainly for its `utils/applescript.js` patterns and the surface-by-surface dual-client folder layout. As a runtime, it is dormant, lacks tests, has weak credential hygiene, and is narrower than its name suggests — synthesize the architectural ideas, do not adopt the codebase.
