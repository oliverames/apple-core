# Read-only acceptance matrix, September 9, 2026

Author: Oliver Ames

The current callable direct-beta surface has 128 tools. Matching their names against source annotations yields 73 read-only-labelled operations. Six source Weather operations are not advertised by this connection and are excluded. This is an inventory and prerequisite map, not a claim that all operations passed.

Earlier service smoke results are in home-server-acceptance-2026-09-08.md. The September 9 isolated Swift run passed 37 existing tests for service policy, filesystem boundaries and OAuth. Hosted fixtures are tracked separately. A live matrix pass should record client, argument fixture, assertion, result and timestamp for each operation without storing personal payloads here.

Some read-only annotations describe absence of record mutation, not absence of recording, sounds, sensor access, UI changes or temporary files. Those operations are held explicitly below. Do not silently include them in an unattended read-only sweep.

| Operation | Source | Current status | Safe assertion or prerequisite |
|---|---|---|---|
| `calendar_list` | [Calendar.swift](../App/Services/Calendar.swift#L231) | Not executed in this matrix pass | Synthetic calendar/event IDs with known dates and attendees; compare returned fields. Live calendar selection required. |
| `calendar_events_fetch` | [Calendar.swift](../App/Services/Calendar.swift#L267) | Not executed in this matrix pass | Synthetic calendar/event IDs with known dates and attendees; compare returned fields. Live calendar selection required. |
| `calendar_event_attendees` | [Calendar.swift](../App/Services/Calendar.swift#L787) | Not executed in this matrix pass | Synthetic calendar/event IDs with known dates and attendees; compare returned fields. Live calendar selection required. |
| `capture_take_picture` | [Capture.swift](../App/Services/Capture.swift#L144) | Held: observable side effect | Camera activation and recording require explicit fixture/approval. readOnlyHint does not mean side-effect-free. |
| `capture_record_audio` | [Capture.swift](../App/Services/Capture.swift#L373) | Held: observable side effect | Microphone recording requires explicit fixture/approval. readOnlyHint does not mean side-effect-free. |
| `capture_take_screenshot` | [Capture.swift](../App/Services/Capture.swift#L472) | Held: observable side effect | Screen capture requires approved target and can expose private UI. |
| `capture_list_windows` | [Capture.swift](../App/Services/Capture.swift#L728) | Not executed in this matrix pass | Requires explicit capture fixture and permission. Do not record camera, microphone or screenshots for generic smoke coverage. |
| `contacts_me` | [Contacts.swift](../App/Services/Contacts.swift#L175) | Not executed in this matrix pass | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `contacts_search` | [Contacts.swift](../App/Services/Contacts.swift#L195) | PASS bounded smoke, 2026-09-09 06:44 EDT | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `contacts_get` | [Contacts.swift](../App/Services/Contacts.swift#L379) | Not executed in this matrix pass | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `contacts_groups` | [Contacts.swift](../App/Services/Contacts.swift#L465) | Not executed in this matrix pass | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `contacts_group_members` | [Contacts.swift](../App/Services/Contacts.swift#L487) | Not executed in this matrix pass | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `contacts_photo` | [Contacts.swift](../App/Services/Contacts.swift#L614) | Not executed in this matrix pass | Synthetic iCloud card/group/photo fixture; confirm account and fields without modifying the original contact. |
| `filesystem_roots` | [Filesystem.swift](../App/Services/Filesystem.swift#L66) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_list` | [Filesystem.swift](../App/Services/Filesystem.swift#L97) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_read` | [Filesystem.swift](../App/Services/Filesystem.swift#L158) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_search` | [Filesystem.swift](../App/Services/Filesystem.swift#L309) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_stat` | [Filesystem.swift](../App/Services/Filesystem.swift#L389) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_read_binary` | [Filesystem.swift](../App/Services/Filesystem.swift#L646) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_search_content` | [Filesystem.swift](../App/Services/Filesystem.swift#L696) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_recent` | [Filesystem.swift](../App/Services/Filesystem.swift#L764) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `filesystem_hash` | [Filesystem.swift](../App/Services/Filesystem.swift#L834) | Not executed in this matrix pass | Explicit shared fixture root with known text/binary files, hashes and dates. Compare content and boundary errors. |
| `location_current` | [Location.swift](../App/Services/Location.swift#L139) | Prerequisite: intended host location | May request authorization and current-location sensor access. Use explicit location test scope. |
| `location_geocode` | [Location.swift](../App/Services/Location.swift#L231) | PASS direct beta, 2026-09-09 06:43 EDT | Public address/coordinates fixture, compare resolution and coordinate bounds. Geocoder/network prerequisite. |
| `location_reverse_geocode` | [Location.swift](../App/Services/Location.swift#L329) | PASS direct beta, 2026-09-09 06:43 EDT | Public address/coordinates fixture, compare resolution and coordinate bounds. Geocoder/network prerequisite. |
| `mail_list_accounts` | [Mail.swift](../App/Services/Mail.swift#L849) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_list_mailboxes` | [Mail.swift](../App/Services/Mail.swift#L869) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_list_messages` | [Mail.swift](../App/Services/Mail.swift#L896) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_get_message` | [Mail.swift](../App/Services/Mail.swift#L938) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_search` | [Mail.swift](../App/Services/Mail.swift#L981) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_selected` | [Mail.swift](../App/Services/Mail.swift#L1200) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. Selection-dependent UI state must be explicitly prepared. |
| `mail_get_thread` | [Mail.swift](../App/Services/Mail.swift#L1369) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_get_unread_count` | [Mail.swift](../App/Services/Mail.swift#L1411) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_get_stats` | [Mail.swift](../App/Services/Mail.swift#L1443) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_list_attachments` | [Mail.swift](../App/Services/Mail.swift#L1471) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_list_templates` | [Mail.swift](../App/Services/Mail.swift#L1697) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `mail_get_template` | [Mail.swift](../App/Services/Mail.swift#L1717) | Not executed in this matrix pass | Dedicated fixture mailbox/messages/attachments/templates with known threading and flags. Do not mark read or fetch new mail. |
| `maps_search` | [Maps.swift](../App/Services/Maps.swift#L41) | PASS direct beta, 2026-09-09 06:43 EDT | Public place and route fixture, validate result fields and distance/time plausibility. MapKit/network prerequisite. |
| `maps_directions` | [Maps.swift](../App/Services/Maps.swift#L135) | PASS direct beta, 2026-09-09 06:43 EDT | Public place and route fixture, validate result fields and distance/time plausibility. MapKit/network prerequisite. |
| `maps_explore` | [Maps.swift](../App/Services/Maps.swift#L305) | PASS bounded smoke, 2026-09-09 06:44 EDT | Public place and route fixture, validate result fields and distance/time plausibility. MapKit/network prerequisite. |
| `maps_eta` | [Maps.swift](../App/Services/Maps.swift#L403) | PASS direct beta, 2026-09-09 06:43 EDT | Public place and route fixture, validate result fields and distance/time plausibility. MapKit/network prerequisite. |
| `maps_generate` | [Maps.swift](../App/Services/Maps.swift#L507) | Not executed in this matrix pass | Public place and route fixture, validate result fields and distance/time plausibility. MapKit/network prerequisite. |
| `messages_fetch` | [Messages.swift](../App/Services/Messages.swift#L104) | Not executed in this matrix pass | Supplied synthetic chat database/attachment fixture. Do not search personal conversations merely for coverage. |
| `messages_list_chats` | [Messages.swift](../App/Services/Messages.swift#L334) | Not executed in this matrix pass | Supplied synthetic chat database/attachment fixture. Do not search personal conversations merely for coverage. |
| `messages_attachments` | [Messages.swift](../App/Services/Messages.swift#L385) | Not executed in this matrix pass | Supplied synthetic chat database/attachment fixture. Do not search personal conversations merely for coverage. |
| `messages_unread` | [Messages.swift](../App/Services/Messages.swift#L437) | Not executed in this matrix pass | Supplied synthetic chat database/attachment fixture. Do not search personal conversations merely for coverage. |
| `notes_list_folders` | [Notes.swift](../App/Services/Notes.swift#L896) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_list` | [Notes.swift](../App/Services/Notes.swift#L916) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_search` | [Notes.swift](../App/Services/Notes.swift#L949) | PASS bounded smoke, 2026-09-09 06:44 EDT | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get` | [Notes.swift](../App/Services/Notes.swift#L998) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_selected` | [Notes.swift](../App/Services/Notes.swift#L1202) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. Selection-dependent UI state must be explicitly prepared. |
| `notes_list_shared` | [Notes.swift](../App/Services/Notes.swift#L1398) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_health_check` | [Notes.swift](../App/Services/Notes.swift#L1427) | PASS bounded smoke, 2026-09-09 06:44 EDT | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_doctor` | [Notes.swift](../App/Services/Notes.swift#L1441) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get_link` | [Notes.swift](../App/Services/Notes.swift#L1455) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get_metadata` | [Notes.swift](../App/Services/Notes.swift#L1481) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get_checklist_state` | [Notes.swift](../App/Services/Notes.swift#L1502) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get_sync_status` | [Notes.swift](../App/Services/Notes.swift#L1529) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_get_markdown` | [Notes.swift](../App/Services/Notes.swift#L1543) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_list_accounts` | [Notes.swift](../App/Services/Notes.swift#L1689) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_stats` | [Notes.swift](../App/Services/Notes.swift#L1710) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_export` | [Notes.swift](../App/Services/Notes.swift#L1732) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_list_attachments` | [Notes.swift](../App/Services/Notes.swift#L1765) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. |
| `notes_fetch_attachment` | [Notes.swift](../App/Services/Notes.swift#L1859) | Not executed in this matrix pass | Dedicated fixture folder and note IDs with known HTML, Markdown, checklist and attachments. Verify returned content. This read stages a temporary file and removes it afterward; verify cleanup with fixture. |
| `reminders_lists` | [Reminders.swift](../App/Services/Reminders.swift#L77) | Not executed in this matrix pass | Synthetic reminder list/section fixture with known dates/completion. Compare fields without completing tasks. |
| `reminders_sections` | [Reminders.swift](../App/Services/Reminders.swift#L113) | Not executed in this matrix pass | Synthetic reminder list/section fixture with known dates/completion. Compare fields without completing tasks. |
| `reminders_fetch` | [Reminders.swift](../App/Services/Reminders.swift#L151) | Not executed in this matrix pass | Synthetic reminder list/section fixture with known dates/completion. Compare fields without completing tasks. |
| `shortcuts_list` | [Shortcuts.swift](../App/Services/Shortcuts.swift#L21) | Not executed in this matrix pass | Installed harmless fixture shortcut/folder. Inspect metadata only; do not run a shortcut. |
| `shortcuts_folders` | [Shortcuts.swift](../App/Services/Shortcuts.swift#L50) | PASS bounded smoke, 2026-09-09 06:44 EDT | Installed harmless fixture shortcut/folder. Inspect metadata only; do not run a shortcut. |
| `shortcuts_view` | [Shortcuts.swift](../App/Services/Shortcuts.swift#L123) | Held: observable side effect | Opens Shortcuts UI. Excluded from unattended read-only pass. |
| `utilities_beep` | [Utilities.swift](../App/Services/Utilities.swift#L13) | Held: observable side effect | Plays audible sound. Excluded from silent read-only smoke pass. |
| `utilities_clipboard_read` | [Utilities.swift](../App/Services/Utilities.swift#L92) | Held: sensitive clipboard | Use isolated supplied clipboard fixture. Never dump an arbitrary current clipboard. |
| `utilities_system_info` | [Utilities.swift](../App/Services/Utilities.swift#L164) | Not executed in this matrix pass | Verify bounded system metadata against host identity; do not expose clipboard contents. |

## Public-data live checks

Five direct-beta operations passed using the Vermont State House and a nearby
public walking destination. Forward and reverse geocoding agreed on Montpelier
and the supplied coordinates. Search returned the State House. Directions
returned a 583-metre route with a 458-second estimate. ETA returned the same
458-second interval and preserved both input coordinates. No current device
location, personal record, camera, microphone or clipboard was read. These five
checks do not stand in for the remaining 68 rows or other clients.

## Additional bounded live smoke checks

Direct beta: Contacts and Notes title searches for unique nonexistent markers
returned empty arrays. Notes health reported healthy Apple Events access.
Shortcuts returned a folder array. Maps exploration returned a public library
within the allowed 2,000-metre radius. A 3,000-metre request was correctly
rejected by the documented runtime validation before the valid request.
These empty-search and metadata checks are narrower than fixture-content tests.

ChatGPT Work separately passed forward/reverse geocoding, State House search,
Notes health and the empty Contacts search. After deployment of hosted version
b4f657e6-9922-4cc0-81ab-cd68bfeb882c, both routes again passed Notes health.
Thus ten distinct direct-beta operations have bounded live results in this
pass, five also checked through Work. Other rows remain explicitly unexecuted.
