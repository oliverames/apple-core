# Coverage Audit — Apple Core vs the field

**Date:** 2026-07-20
**Methodology:** Tool inventories were read directly from source: Apple Core's `App/Services/*.swift`, the local clone of `sweetrb/apple-notes-mcp` (`~/Developer/Projects/apple-notes-mcp/src/index.ts`), and the installed plugin cache of `sweetrb/apple-mail-mcp` v2.8.12 (`~/.claude/plugins/cache/apple-mail-mcp/`). Alternative-server data came from GitHub API reads (`gh api repos/...`, `gh search repos`) and web-search cross-checks on 2026-07-20. Star counts drift daily and index sites lag, so they are given as approximate ranges spanning the values observed across sources on audit day; treat them as adoption signals, not exact figures. Where a project's tool list could not be verified from source or a fetched README, that is stated rather than guessed.

**Framing note (per DONORS.md):** BUILD_PLAN.md §3.1's deep Mail design is based on `imdinu/apple-mail-mcp` (Python, disk-first `.emlx` + FTS5). That remains the **indexing-architecture reference**. This audit treats `sweetrb/apple-mail-mcp` (TypeScript, 46 tools counted in v2.8.12 source) as the **tool-surface parity bar** — the two are complementary, not competing picks.

---

## 1. Notes — vs sweetrb/apple-notes-mcp

Reference: `sweetrb/apple-notes-mcp` — roughly 55-70★, actively pushed in July 2026. **36 tool registrations** verified from `src/index.ts` in the local clone. Apple Core: **8 tools** in `App/Services/Notes.swift` (`notes_list_folders`, `notes_list`, `notes_search`, `notes_get`, `notes_create`, `notes_append`, `notes_update`, `notes_delete`).

| sweetrb tool | Status in Apple Core | Priority |
|---|---|---|
| create-note | Covered (`notes_create`, text or HTML body) | — |
| search-notes | Covered (`notes_search`, title/body/all scopes) | — |
| get-note-content / get-note-plaintext / get-note-by-id / get-note-details | Covered (`notes_get` returns HTML + plaintext + metadata + bodyHash) | — |
| get-note-metadata | Covered (subset of `notes_get`) | — |
| update-note | Covered (`notes_update`, last-writer-wins; concurrency TODO noted in source) | — |
| append-to-note | Covered (`notes_append`) | — |
| delete-note | Covered (`notes_delete`) | — |
| list-notes | Covered (`notes_list`) | — |
| list-folders | Covered (`notes_list_folders`) | — |
| get-note-markdown | **Missing** (only HTML/plaintext) | High |
| move-note | **Missing** | High |
| create-folder / delete-folder | **Missing** | High |
| list-accounts / show-account / get-default-location | **Missing** (folder listing includes account names, but no account tools) | Medium |
| list-attachments / save-attachment / fetch-attachment / show-attachment | **Missing** | High |
| batch-delete-notes / batch-move-notes | **Missing** | Medium |
| get-checklist-state | **Missing** | Medium |
| list-shared-notes | **Missing** | Low |
| get-sync-status | **Missing** | Low |
| get-notes-stats | **Missing** | Low |
| export-notes-json | **Missing** | Medium |
| get-selected-notes | **Missing** (GUI-context tool) | Low |
| show-note / show-folder | **Missing** (open in Notes.app UI) | Low |
| get-note-link | **Missing** (deep link) | Medium |
| health-check / doctor | **Missing** (no Notes-specific diagnostics; a `--doctor` pattern is planned per DONORS §4) | Medium |

**Coverage: 12/36 sweetrb tools fully covered ≈ 33%.** The functional core (CRUD + search) is solid; gaps are folder management, move, attachments, markdown output, batch ops, and diagnostics.

---

## 2. Mail — vs sweetrb/apple-mail-mcp

Reference: `sweetrb/apple-mail-mcp` — roughly 33-50★ depending on snapshot, actively pushed in July 2026. **46 unique tool registrations** counted in the v2.8.12 source in the plugin cache. Apple Core: **5 read-only tools** in `App/Services/Mail.swift` (`mail_list_accounts`, `mail_list_mailboxes`, `mail_list_messages`, `mail_get_message`, `mail_search`), an explicitly scaffolded first slice.

| Capability group (sweetrb tools) | Status | Priority |
|---|---|---|
| list-accounts, list-mailboxes, list-messages, get-message | Covered | — |
| search-messages | **Partial** — Apple Core matches subject/sender substring within one mailbox only; no body/FTS, no cross-mailbox search | High |
| get-thread, resolve-message-id, get-unread-count | **Missing** | High |
| mark-as-read / mark-as-unread / flag-message / unflag-message | **Missing** | High |
| move-message, delete-message | **Missing** | High |
| send-email, reply-to-message, forward-message, create-draft, send-serial-email | **Missing** (BUILD_PLAN targets IMAP/SMTP send in v2.0) | High |
| batch-* (mark read/unread, flag/unflag, move, delete — 6 tools) | **Missing** | Medium |
| list-attachments, save-attachment, fetch-attachment | **Missing** | High |
| create/delete/rename-mailbox | **Missing** | Medium |
| Rules: create/list/delete/enable/disable-rule | **Missing** | Medium |
| Templates: save/get/list/delete/use-template | **Missing** | Low |
| search-contacts | Covered elsewhere (`contacts_search`) | — |
| get-mail-stats, get-sync-status, health-check, doctor | **Missing** | Medium |

**Coverage: ~5/46 ≈ 11%** (by tool count; by everyday read workflows, closer to a third). This is by design — Mail.swift documents itself as the scaffold for the BUILD_PLAN §3.1 build-out — but the gap to the parity bar is the largest in the project.

---

## 3. Calendar

Apple Core (`Calendar.swift`): `calendars_list`, `events_fetch`, `events_create` — **no update, no delete**, inherited from iMCP.

Best-in-class today: **FradSer/mcp-server-apple-events** — roughly 160-170★, pushed early July 2026, active. Full CRUD verb-dispatcher for events and reminders, extended RRULE recurrence, alarms incl. geofenced, span semantics (tool shape documented in DONORS.md review; not re-verified from source today). Already the DONORS.md §3 pick; **still the right donor, and more mature than at the 2026-04-30 snapshot**. No newer challenger with meaningful adoption surfaced (next candidates observed at ≤11★: shadowfax92/apple-calendar-mcp, harriscarl/apple-eventkit-mcp, l22-io/orchard-mcp at ~9★).

| Gap | Priority |
|---|---|
| events_update / events_delete | High |
| Recurrence editing with span (`this-event` / `future-events`) | High |
| Alarms (relative/absolute/location) | Medium |
| Attendee/RSVP visibility | Low (EventKit write access to attendees is limited) |

**Coverage vs FradSer bar: roughly half (read + create, no mutate).**

## 4. Reminders

Apple Core (`Reminders.swift`): `reminders_lists`, `reminders_fetch`, `reminders_create` — no update, complete, or delete.

Best-in-class: same **FradSer/mcp-server-apple-events** (Reminders + Calendar unified; FradSer also maintains the older `mcp-server-apple-reminders`). Full CRUD, subtasks, cross-source-move AppleScript fallback per DONORS review. Dedicated alternatives are small (shadowfax92/apple-reminders-mcp ~29★ but no pushes since March 2025; dbmcco/apple-reminders-mcp ~26★).

| Gap | Priority |
|---|---|
| reminders_update (incl. mark complete) | High — completing a reminder is the single most common write |
| reminders_delete | High |
| Subtasks | Medium |
| Due-date/priority filtering beyond current fetch params | Medium |

## 5. Contacts

Apple Core (`Contacts.swift`): `contacts_me`, `contacts_search`, `contacts_update`, `contacts_create` — already ahead of most of the field (iMCP was read-only; Apple Core added create/update).

Field survey: no strong standalone donor exists. `lu-wo/apple-contacts-mcp` (~4★, pushed June 2026) and `s-morgan-jeffries/apple-contacts-mcp` (0★) are the only dedicated servers found; broad servers (apple-mcp, icloud-mcp) offer search + create only. **Apple Core is at or above the field bar here.**

| Gap | Priority |
|---|---|
| contacts_delete | Low |
| Group management | Low |
| Photo read/write | Low |

## 6. Messages

Apple Core (`Messages.swift`): `messages_fetch` only — read via chat.db, **no send**.

Best-in-class: **carterlasalle/mac_messages_mcp** — roughly 270-300★ depending on snapshot, pushed mid-July 2026, active. 11 tools verified from its README (fetched 2026-07-20): recent messages, fuzzy body search, contact fuzzy-match, group-chat listing, attachment search/fetch (HEIC→PNG), iMessage-availability check, DB/AddressBook diagnostics, and **send** (direct + group, SMS/RCS fallback). This is a **better tool-surface donor than the DONORS.md picks for Messages** (Dhravya/apple-mcp is dormant — the supermemoryai copy sits above 3,000★ but has had no pushes since August 2025). Dhravya's hybrid read-db/send-AppleScript pattern remains valid; mac_messages_mcp implements the same pattern with more depth and is alive.

| Gap | Priority |
|---|---|
| messages_send (AppleScript send, direct + group) | High |
| Group-chat listing / chat-id addressing | High |
| Full-text/fuzzy search over history | Medium |
| Attachment listing/fetch | Medium |
| iMessage availability + phone normalization | Medium |

## 7. Maps

Apple Core (`Maps.swift`): `maps_search`, `maps_directions`, `maps_explore`, `maps_eta`, `maps_generate` — MapKit-native.

Field survey: essentially no competition. Best externals found via GitHub search: `romanvrable/apple-maps-mcp` (~1★, URL-scheme + Apple Maps Server API) and two 0★ repos. **Apple Core's MapKit implementation already leads the field**; no donor change warranted.

## 8. Shortcuts

Apple Core (`Shortcuts.swift`): `shortcuts_list`, `shortcuts_run`.

Field survey: the field is thin — `as2811-project/Apple-Shortcuts-MCP` (~4★), `pravj/Apple-Shortcuts-MCP` (~1★, shortcut *creation*). Apple Core matches the practical bar (list + run with input). Shortcut creation/signing is a separate problem space. **At parity; no action needed.**

## 9. iMCP-inherited extras (Location, Weather, Capture)

`location_current`, `location_geocode`; `weather_current/daily/hourly/minute`; `capture_take_picture/record_audio/take_screenshot`. These come from mattt/iMCP (well over 1,000★; last pushed May 2026, slowing) and have no meaningful dedicated-MCP competition found. No gaps to close for parity.

---

## DONORS.md drift observed (vs the 2026-04-30 snapshot)

- **adamzaidi/icloud-mcp appears unavailable on GitHub as of this audit**: both `gh api repos/adamzaidi/icloud-mcp` and a direct HTTPS request to the repo URL returned HTTP 404 at audit time (2026-07-20), consistent with a mid-2026 deletion or privatization; cached search indexes still list the repo, so re-check before concluding permanence. Its lifted patterns (three-phase safe move, doctor, connect-gate) are documented in DONORS/BUILD_PLAN, but the upstream may no longer be available for reference. Preserve any local notes/clone.
- **Dhravya/apple-mcp** API-redirects to supermemoryai/apple-mcp; still dormant (no pushes since August 2025) despite its large star count.
- **FradSer/mcp-server-apple-events** and **sweetrb's two servers** all remain actively maintained (pushes in July 2026). **imdinu/apple-mail-mcp** remains active (pushed early July 2026) — the indexing-architecture reference stands.
- New donor recommendation: **carterlasalle/mac_messages_mcp** for the Messages tool surface (see §6).

---

## Prioritized backlog — to reach the parity bar

Ordered by user value:

1. **Mail state changes + triage** — mark read/unread, flag/unflag, move, delete (single + batch). Highest-frequency daily workflows; pure AppleScript, no indexer needed.
2. **Mail send/reply/forward/draft** — completes the surface (BUILD_PLAN v2.0 already plans this; consider an AppleScript draft-based interim before IMAP/SMTP lands).
3. **Reminders update/complete/delete and Calendar events_update/delete** — small EventKit additions (FradSer's verb-dispatcher pattern), closes the biggest everyday gap outside Mail.
4. **Messages send + group chats** — `messages_send`, chat listing, availability check (lift patterns from carterlasalle/mac_messages_mcp: AppleScript send, phone normalization).
5. **Notes folder ops + move + markdown** — create/delete-folder, move-note, batch-move/delete, `notes_get` markdown output.
6. **Attachments** — Notes list/save attachments; Mail list/save attachments.
7. **Cross-mailbox / body search for Mail** — arrives naturally with the imdinu-style FTS5 index (BUILD_PLAN §3.1).
8. **Diagnostics** — per-surface `doctor`/health-check (already planned via adamzaidi's pattern; note the upstream availability caveat above).
9. **Low-value tail** — Notes shared-notes/stats/deep-links, Mail rules and templates, Contacts delete/groups.
