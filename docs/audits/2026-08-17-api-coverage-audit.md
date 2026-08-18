# Apple Core API coverage audit

Date: 2026-08-17
Scope: the 11 shipping service surfaces, plus the absent filesystem surface
and MCP tool surfacing. Verified against the source, not assumed.

Current totals: 77 tools in the standard build (4 more WeatherKit tools are
entitlement-gated and excluded).

| Surface | Tools | Coverage verdict |
| --- | --- | --- |
| Mail | 26 | Broad |
| Notes | 19 | Broad |
| Reminders | 6 | Good; recurrence, priority and alarms present |
| Calendar | 5 | Good; recurrence, alarms and availability present |
| Maps | 5 | Reasonable |
| Contacts | 4 | Thin |
| Messages | 3 | Thin |
| Capture | 3 | Reasonable; video handling present |
| Location | 2 | Thin |
| Shortcuts | 2 | Reasonable; input passing present |
| Utilities | 1 | Placeholder |
| Filesystem | 0 | Absent |

## Corrected assumptions

Three gaps assumed at the start turned out to be already covered, and are
recorded so they are not "fixed" again:

- Calendar already handles `EKRecurrenceRule`, `EKAlarm` and event
  availability.
- Reminders already handles recurrence, priority and alarms.
- Capture already handles video, and Shortcuts already passes input.

## Confirmed gaps

### Contacts — done
- Was the thinnest mature surface: create and update with no inverse, no
  groups, no photos, no fetch by identifier.
- Added `contacts_get`, `contacts_delete`, `contacts_groups`,
  `contacts_group_members` and `contacts_photo`.
- Still open: creating and editing groups, and setting a contact photo. Both
  are writes to structures the surface can now read, and neither is blocked.

### Location
- Reverse geocoding was assumed missing and is not: `location_reverse_geocode`
  exists. It was shipped as `location_reverse-geocode`, the only hyphenated
  name among 81 tools, which is why a first pass did not find it. Renamed to
  use an underscore like every other tool.
- Remaining gap: no heading, altitude, or region monitoring. Low value for an
  MCP surface; not planned.

### Messages
- No attachment handling, no tapbacks/reactions, no unread state.
- Blocked, not merely unbuilt. The surface reads through the third-party
  `iMessage` module from `loopwork-ai/madrid`, which does not expose these
  fields. Closing the gap means either contributing upstream or querying
  `chat.db` directly alongside madrid. That is a real design decision about
  taking on a second read path, so it is not something to slip in at the end
  of an afternoon.

### Utilities — done
- Was one tool, `utilities_beep`. Now six: added `utilities_notify`,
  `utilities_clipboard_read`, `utilities_clipboard_write`,
  `utilities_open_url` and `utilities_system_info`.
- `utilities_open_url` accepts only http, https, mailto, facetime, sms and
  tel. Every registered URL handler on a Mac is a far larger surface than
  "show the user a page", and an allowlist is the difference.
- Notification authorization is requested on first use rather than on enable,
  so a session that never posts one never prompts.

### Filesystem — done
- Built as `FilesystemService` with five tools, bounded by an allowlist that
  starts empty. Read and write are tracked per shared folder.
- Containment is enforced on symlink-resolved canonical paths in
  `Shared/FilesystemAccess.swift`, with tests covering `..` traversal, a
  symlink pointing out of a shared folder, and the sibling-prefix case where
  "Documents-private" must not match the root "Documents".
- Follows the Access setting like every other surface, per the decision taken
  when it was specified.

## Next

1. Messages: decide whether to contribute upstream to madrid or add a direct
   `chat.db` read path. Blocked on that decision, not on effort.
2. Contacts: group creation and membership editing, and setting a photo.
3. A documentation-driven second pass. This audit was written from the source,
   which finds what is missing against what is there — it does not find what
   neither the code nor the reader thought of. Apple's framework references,
   the local `apple-notes-mcp` project, and the `remctl` reminders CLI are all
   better sources for that, and the result will be larger than this list.
6. MCP surfacing: annotations are already present and correct (`readOnlyHint`,
   `openWorldHint`, human titles) on the tools sampled. Two naming defects
   found; one fixed, one needs a decision.

## MCP surfacing findings

Good: every tool sampled carries `annotations` with a human-readable title and
correct `readOnlyHint` / `openWorldHint`. That is what makes a tool list
legible in Claude and other clients, and it is already right.

Defect 1, fixed: `location_reverse-geocode` was the only hyphenated tool name
of 81. Renamed to `location_reverse_geocode`.

Defect 2, fixed on Oliver's instruction: Calendar is the only surface whose tools do not
share one prefix. It ships `calendars_list` plus `events_fetch`,
`events_create`, `events_update`, `events_delete`, so its five tools sort into
two unrelated places in an alphabetical tool list and neither sorts near
"calendar". Every other surface uses a single prefix matching its name.

Renamed to `calendar_list`, `calendar_events_fetch`,
`calendar_events_create`, `calendar_events_update`, `calendar_events_delete`.

This is a breaking change. Anything calling `calendars_list` or `events_*`
must be updated, and it will fail with "tool not found" rather than
misbehaving quietly. Worth checking any agent skills or saved automations that
drive the Calendar surface.

After both fixes, all 96 tools use underscores and every surface has exactly
one prefix matching its name.

---

# Second pass: documentation and reference-implementation driven

The first pass above was written from our own source, which only finds what is
missing against what is already there. This pass compares each surface against
a reference implementation or Apple's own framework, which finds the things
nobody had thought of. It is a longer list, as expected.

## The structural finding

Three surfaces have their richest data in Apple's private CoreData/SQLite
stores rather than in the public frameworks:

- **Reminders.** EventKit exposes no subtasks, sections, tags, or attachments.
  `remctl` gets all of them by reading the iCloud Reminders CoreData store
  (`Data-*.sqlite`) directly and writing through EventKit with an AppleScript
  fallback.
- **Messages.** Attachments, tapbacks and unread state are all in `chat.db`.
- **Notes.** Checklist state and some metadata are similarly not in the
  scripting interface.

This reframes the Messages item in the first pass. Apple Core **already reads
`chat.db` directly** — the surface has a file picker for it and a stored
security bookmark. So a direct store read is not a new architectural
departure; it is an established pattern in this codebase that one surface
uses and the others do not. That makes the Reminders and Messages gaps a
matter of applying an existing pattern rather than adopting a new one.

The read-only, defensive posture that pattern needs is already written down in
`remctl`: open the store read-only, tolerate schema drift across macOS
releases, and degrade to the public framework when the store cannot be read.

## Reminders — the largest gap in the app

Six tools today: lists, fetch, create, update, complete, delete. `remctl`
exposes all of the following, none of which Apple Core has:

- Subtasks, sections, and hashtag tags
- List groups (create, rename, add/remove child lists)
- Smart lists and saved templates
- Flagged and urgent views, and a due-today/overdue view
- Attachments, including image attachments
- Deep links to a specific reminder
- Sharees, for assignment inside a shared list
- Statistics

Priority, recurrence and alarms are already covered, as the first pass found.

## Notes — about ten gaps against apple-notes-mcp

Nineteen tools today. `apple-notes-mcp`, which is the reference for this
surface, additionally exposes:

- Plaintext extraction, distinct from the markdown we already emit
- A deep link to a note
- The notes currently selected in Notes.app
- Checklist state
- Note metadata, separate from full content
- Sync status, and a list of shared notes
- Reveal-in-app for a note, folder, or account
- The default save location
- Inline attachment fetch, as opposed to saving to disk
- Health-check and doctor diagnostics

## Calendar and Contacts, against the frameworks

- **Calendar**: no attendees or invitation handling (`EKParticipant`), no
  calendar creation or deletion, no free/busy query, no event attachments, no
  moving an event between calendars.
- **Contacts**: group creation and membership editing, and setting a photo,
  remain open — the surface can now read both.

## Recommended order

1. Reminders subtasks, sections and tags, via a read-only store read modelled
   on `remctl`. Biggest single gain in the app.
2. Notes plaintext, deep link, selected notes, checklist state. All cheap.
3. Messages attachments and unread, extending the existing `chat.db` access.
4. Calendar attendees and calendar management.
5. Contacts group and photo writes.

Every item here is additive. Nothing above is blocked on a decision except the
choice of how defensively to read the private stores, and `remctl` is a
working answer to that.
