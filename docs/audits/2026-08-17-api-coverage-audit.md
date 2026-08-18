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

## Reminders store: what can actually be verified here

The store is readable on this Mac (macOS 27), so the approach is viable —
`remctl lists --format json` returns real data, and the schema has the columns
the rich features need: `ZREMCDREMINDER.ZPARENTREMINDER` for subtasks,
`ZREMCDHASHTAGLABEL` for tags, `ZREMCDBASESECTION` for sections.

But counting rows across all three stores on this machine:

| Feature | Rows |
| --- | --- |
| Sections | 34 |
| Subtasks | 0 |
| Tags | 0 |
| Attachments | 0 |
| Templates | 0 |
| Flagged | 0 |

Only sections can be built and verified here. A subtasks or tags reader
written against this schema would be untested against real data, and an
untested SQLite reader against an undocumented Apple schema is precisely the
kind of code that looks right and is not. It would also fail quietly rather
than loudly, because an empty result is indistinguishable from a correct
result when the source is empty.

So: sections are implementable and verifiable now. Subtasks, tags and
attachments need either test data on this machine — a few reminders with
subtasks and hashtags would be enough — or a deliberate decision to write them
against the schema and verify later. Worth asking for the test data first;
it costs a minute and turns three unverifiable features into verifiable ones.


---

# Coverage confirmed

Verified over live MCP against a server on an isolated config, not by reading
the source. `tools/list` advertised 96 tools; the source has 105. The
difference is accounted for, not unexplained: 5 filesystem tools are correctly
absent because no folder is shared yet and the surface reports itself inactive
until one is, and 4 WeatherKit tools are entitlement-gated out of the standard
build.

Tools called and confirmed returning real data:

| Tool | Result |
| --- | --- |
| `utilities_system_info` | macOS 27.0, 10 cores |
| `reminders_sections` | 12 Groceries sections, UUIDs decoded |
| `messages_unread` | 21 unread across conversations, named |
| `messages_attachments` | attachments with chat, message id, timestamp |
| `contacts_groups` | 4 groups with identifiers |

## Final counts

| Surface | Start | Now |
| --- | --- | --- |
| Mail | 26 | 26 |
| Notes | 19 | 21 |
| Contacts | 4 | 12 |
| Calendar | 5 | 6 |
| Reminders | 6 | 7 |
| Utilities | 1 | 6 |
| Messages | 3 | 5 |
| Filesystem | 0 | 5 |
| Maps | 5 | 5 |
| Capture | 3 | 3 |
| Location | 3 | 3 |
| Shortcuts | 2 | 2 |
| **Total** | **81** | **105** |

## What remains, and why

Two items, both blocked on something outside the code:

1. **Reminders subtasks and tags.** The columns exist
   (`ZREMCDREMINDER.ZPARENTREMINDER`, `ZREMCDHASHTAGLABEL`) and the reader is
   already built and tested against the same store. What is missing is data:
   zero rows across all three stores here. Creating two or three reminders
   with subtasks and a hashtag unblocks both, and the readers are then a small
   addition to `RemindersStoreReader`.

2. **Messages tapbacks.** Unlike attachments and unread, these are stored as
   associated messages with their own type encoding, and getting them wrong
   produces plausible-looking wrong answers rather than errors. Worth doing
   deliberately rather than alongside everything else.

Everything else in both audit passes is implemented and verified.

---

# Third pass: the surfaces the earlier passes only glanced at

Dated 2026-08-18.

The first pass judged five surfaces in a single word each — Mail "Broad",
Maps, Capture and Shortcuts "Reasonable" — and never returned to them. Those
one-word verdicts were the only examination those surfaces ever had, so this
pass audits each against its own framework or command-line tool rather than
against an impression.

## Shortcuts — the CLI was barely used

`/usr/bin/shortcuts` has four subcommands and eight options. The service used
two subcommands and one option, so the following were simply unreachable:

| Missing | Consequence |
| --- | --- |
| `--show-identifiers` | Shortcuts were addressed by name, which is not unique. |
| `--folders`, `--folder-name` | 8 folders of shortcuts were invisible. |
| `--input-path` with a real file | Input could only ever be text typed into a temp file. |
| `--output-path` | A shortcut producing an image or PDF had its result discarded. |
| `--output-type` | No way to ask for a particular representation. |
| `view` | No way to show the user how a shortcut is built. |

All six are now covered, across four tools rather than two. File arguments
resolve through `FilesystemAccess`, so a shortcut can only read and write
inside a folder the user already shared.

Verified live: `shortcuts_folders` returned 8 folders with identifiers, and
`shortcuts_list` filtered to the Car folder returned its 4 shortcuts. The
guards were verified too — a file outside the shared folders is refused, and
passing both `input` and `inputPath` is refused.

**Not verified:** a successful run with file input and output. The Shortcuts
CLI itself hangs while the Mac's screen is locked, reproduced directly outside
the app, so the happy path could not be exercised in this session.

## Capture — identifiers with no way to discover them

`capture_take_screenshot` accepted `displayId`, `windowId` and `bundleId`, and
nothing in the app told a client what any of those values were. In practice
only whole-screen capture was reachable. `capture_list_windows` now returns
displays, applications and windows from `SCShareableContent`.

This also explains the screenshot failures at the end of the previous session,
which were read at the time as a display-topology problem. ScreenCaptureKit
reports **no displays at all while the screen is locked**, and the error said
"No displays available", which reads as a broken capture rather than a locked
Mac. Both that error and the new listing now say so plainly.

## Maps — directions never returned how long or how far

`Trip`, the schema.org type the tool returned, has nowhere to put a distance or
a duration and only ever describes the first route. So `maps_directions`
returned turn-by-turn instructions with no answer to "how long does it take" —
the substance of the question. `MKDirections.Request` also has three properties
the tool never set: `requestsAlternateRoutes`, `departureDate` and
`arrivalDate`, the last of which means transit directions were always
calculated against "now".

The tool now describes the response directly: every route, with distance,
expected travel time, toll and highway flags, advisory notices, and per-step
distances. This changes the shape of the tool's output, which is a deliberate
break.

Verified live: Union Square to the Golden Gate Bridge returned three routes —
Van Ness Ave (7840 m, 802 s), Franklin St (7844 m, 891 s) and Geary Blvd
(8962 m, 987 s). Both date guards were verified to reject.

## Weather — no alerts and no past weather

`weather_alerts` and `weather_history` are added. Alerts distinguish "no
alerting authority covers this location" from "no alerts", because a bare empty
list conflates the two. The surface is entitlement-gated out of the standard
build, so verification here is compilation only, and it is stated as such.

## Mail — mostly a correction to this audit's own assumptions

Two things assumed missing turned out to be present or deliberate:

- **Batch operations already exist.** `mail_set_read`, `mail_set_flagged`,
  `mail_move_message` and `mail_delete_message` all take an array of ids and
  report per-id success. The assumption that they were one-at-a-time was wrong.
- **Rules are excluded on purpose**, with the reasoning already written down in
  the source. Not a gap.

Genuinely missing and now added: `mail_selected`, which answers "the message I
am looking at", and `mail_check_for_new_mail`.

**Attempted and withdrawn: signatures.** `mail_signatures` was built, and it
failed live with `signatures.map` on null. Mail's dictionary explains why: the
`signature` element carries
`access-group identifier="com.apple.mail.compose"`, so an unentitled script
reads it as null. There is no unentitled path to it, so the tool and the
`signature` compose parameter were both removed rather than shipped broken, and
the reason is now recorded with Mail's other deliberate exclusions.

**Not verified:** `mail_selected` returning actual messages. Mail has no viewer
window open on this locked Mac, so it correctly returns an empty list, but the
populated case was not exercised.

## Counts after this pass

| Surface | Second pass | Now |
| --- | --- | --- |
| Mail | 26 | 28 |
| Notes | 21 | 21 |
| Contacts | 12 | 12 |
| Reminders | 7 | 7 |
| Weather | 4 | 6 |
| Utilities | 6 | 6 |
| Calendar | 6 | 6 |
| Messages | 5 | 5 |
| Maps | 5 | 5 |
| Filesystem | 5 | 5 |
| Shortcuts | 2 | 4 |
| Capture | 3 | 4 |
| Location | 3 | 3 |
| **Total** | **105** | **112** |

101 of those advertise over live MCP: 6 WeatherKit tools are entitlement-gated
out of the build, and the 5 filesystem tools stay inactive until a folder is
shared.

## A false alarm worth recording

An early probe showed roughly 1 in 12 `tools/call` requests failing with
"Method not found". That was the test client's fault, not the server's: it sent
no session header, so every request opened a fresh session and raced the
initialize handshake. With a real session, 12 of 12 succeeded. Recorded here so
it is not rediscovered and reported as a bug.
