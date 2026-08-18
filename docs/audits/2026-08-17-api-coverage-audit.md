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

### Contacts (thinnest of the mature surfaces)
- No delete. `contacts_create` and `contacts_update` exist with no inverse.
- No group support at all: no `CNGroup` read, create, or membership change.
- No contact images (`imageData` / `thumbnailImageData`).
- No fetch by identifier; search is the only lookup path.

### Location
- Reverse geocoding was assumed missing and is not: `location_reverse_geocode`
  exists. It was shipped as `location_reverse-geocode`, the only hyphenated
  name among 81 tools, which is why a first pass did not find it. Renamed to
  use an underscore like every other tool.
- Remaining gap: no heading, altitude, or region monitoring. Low value for an
  MCP surface; not planned.

### Messages
- No attachment handling, sending or reading.
- No tapbacks/reactions.
- No unread state.

### Utilities
- One tool, `utilities_beep`. Effectively a placeholder. Candidates that need
  no new TCC grant: notifications, clipboard read/write, open URL, system and
  battery info, frontmost app.

### Filesystem
- Absent entirely. This is the highest-risk surface in the app and the one
  with a real security decision attached, since it is the only surface whose
  scope is not already bounded by a macOS TCC grant. Needs an explicit
  allowlist of roots plus read/write separation before implementation.

## Next

1. Contacts: delete, groups, images, fetch-by-identifier.
2. Location: reverse geocode.
3. Messages: attachments, unread.
4. Utilities: promote from placeholder.
5. Filesystem: design the scoping model first, then build.
6. MCP surfacing: annotations are already present and correct (`readOnlyHint`,
   `openWorldHint`, human titles) on the tools sampled. Two naming defects
   found; one fixed, one needs a decision.

## MCP surfacing findings

Good: every tool sampled carries `annotations` with a human-readable title and
correct `readOnlyHint` / `openWorldHint`. That is what makes a tool list
legible in Claude and other clients, and it is already right.

Defect 1, fixed: `location_reverse-geocode` was the only hyphenated tool name
of 81. Renamed to `location_reverse_geocode`.

Defect 2, needs a decision: Calendar is the only surface whose tools do not
share one prefix. It ships `calendars_list` plus `events_fetch`,
`events_create`, `events_update`, `events_delete`, so its five tools sort into
two unrelated places in an alphabetical tool list and neither sorts near
"calendar". Every other surface uses a single prefix matching its name.

The fix is to rename to `calendar_list`, `calendar_events_fetch`,
`calendar_events_create`, `calendar_events_update`, `calendar_events_delete`.
That is a breaking change for anything already calling the old names, which is
why it is recorded here rather than applied: Oliver has agent skills and
automations that may reference them. Pre-launch is the cheapest moment to do
it.
