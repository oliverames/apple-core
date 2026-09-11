# Personal-app MCP coverage review

Author: Oliver Ames  
Reviewed: September 10, 2026  
Scope: Calendar, Reminders, Contacts, Messages, and Shortcuts. Research only. No application data, code, or configuration changed.

Apple Core already matches or exceeds the ordinary CRUD capabilities of most broad Apple MCP servers. The best additions are richer Reminders organization, remote retrieval of Messages attachments, and safer Contacts discovery. Advanced private-API features deserve separate feasibility work, not automatic adoption because another server advertises them.

## Evidence and benchmark selection

Local implementation inspected: `App/Services/Calendar.swift`, `Reminders.swift`, `Contacts.swift`, `Messages.swift`, and `Shortcuts.swift`. Historical context inspected: `NOTICE`, `docs/planning/DONORS.md`, and the FradSer and supermemory donor reviews. Historical donor claims were not treated as current evidence.

The following maintenance dates came from fresh GitHub repository and latest-default-branch-commit API responses. Stars indicate adoption, not reliability. No benchmark was installed or executed against live personal data. “Reference” means a useful design comparison, not independently proven production quality.

| Reference | Latest default-branch commit | Fresh maintenance/adoption evidence | Best comparison use |
|---|---|---|---|
| [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events/commit/b538b19dff6f3d8b68b642711944405ee787b690) | August 26, 2026 | Active, 200 stars. Current README documents v1.5.0, test/coverage commands and an `event` backend migration. | Calendar and Reminders native API behavior, limitations, list management. |
| [rex/mcp-apple-reminders](https://github.com/rex/mcp-apple-reminders/commit/b9b12fb5d834a5b63b5d98f47cdc8754f2c4945b) | September 7, 2026 | Active, zero stars at inspection. Large specialized catalog, limited adoption evidence. | Maximum observed Reminders feature breadth, including private ReminderKit. |
| [carterlasalle/mac_messages_mcp](https://github.com/carterlasalle/mac_messages_mcp/commit/ee5512c3e3333d999ce02a448a09bf70be7b12c8) | September 3, 2026 | Active, 326 stars. Documents isolated SQLite fixtures and mocked AppleScript tests. | Messages attachment access, search and diagnostics. Already an attributed donor. |
| [JonathanRReed/Apple-MCPs](https://github.com/JonathanRReed/Apple-MCPs/commit/9d0d86dea31589303ab4c4c53be659f2de00729c) | September 6, 2026 | Active, 12 stars. Repository documents protocol CI and focused app servers. | Contacts duplicate suggestions, pagination, recipient resolution, per-app health. |
| [griches/apple-mcp](https://github.com/griches/apple-mcp/commit/461524625402548f7729db9f7a3758264b7644be) | March 17, 2026 | Unarchived, 120 stars, nearly six months without default-branch changes. | Simple Contacts group deletion and reminder list lifecycle. |
| [recursechat/mcp-server-apple-shortcuts](https://github.com/recursechat/mcp-server-apple-shortcuts/commit/910a56d4965c1a39d4afb9890f21580f02f3f71d) | December 22, 2024 | Unarchived, 347 stars, long inactive interval. | Historical Shortcuts baseline, not a maintenance leader. |
| [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | August 11, 2025 | Archived, 3,130 stars. | Historical checklist only. Its popularity does not make it a current maintenance benchmark. |

These are selected benchmarks, not proof that any repository is globally the “most robust.” April donor reviews are now materially stale: FradSer changed backends and dropped several write fields, while supermemory is archived.

## Calendar

| Area | Apple Core today | Gap or conclusion | Priority and verification |
|---|---|---|---|
| Event lifecycle | Seven tools cover calendar listing, event search/create/update/delete, and attendee reads. Rich alarms, recurrence, availability, and occurrence targeting exist. | Ordinary CRUD, recurrence, and alarms are already implemented. Do not re-add them under different tool names. | Preserve current breadth with recurring-series, daylight-saving, and read-only-calendar fixture tests. |
| Single-event retrieval | No dedicated event-get tool. Fetch uses date/calendar/query filters. | Add exact-ID retrieval with optional occurrence date, following the single-event workflow present in [JonathanRReed's catalog](https://github.com/JonathanRReed/Apple-MCPs/blob/9d0d86dea31589303ab4c4c53be659f2de00729c/Apple-Calendar-MCP/src/apple_calendar_mcp/tools.py). | P2. Verify stale IDs, recurring occurrence identity, deleted records, and bounded output. |
| Invitations | Attendees are readable, not writable through the current EventKit route. | FradSer now documents an AppleScript invitation route, separate from EventKit. This is a real capability candidate, not evidence of missing EventKit support. | P3 feasibility. Requires GUI/Automation permission and can notify external people. Test with dedicated accounts and unambiguous event identity. |
| Calendar lifecycle | Calendars can be listed but not created, renamed, or deleted. | Product opportunity, but not a clear parity loss against the selected leading Calendar catalogs. | P3. Establish demand before expanding destructive account-level operations. |

FradSer's [migration document](https://github.com/FradSer/mcp-server-apple-events/blob/b538b19dff6f3d8b68b642711944405ee787b690/docs/migration-to-event-cli.md) explicitly lists lost alarm, recurrence, structured-location, availability, and move writes. Apple Core should not copy that regression. Its separate invitation path needs Calendar.app and refuses ambiguous matches or combined updates. Any analogous Apple Core work should preserve those distinctions. FradSer's occurrence-delete limitation is about its own lookup/backend route and does not establish a defect in Apple Core's explicit occurrence resolution.

## Reminders

| Area | Apple Core today | Concrete opportunity | Priority and verification |
|---|---|---|---|
| Lists | Lists and sections readable. No list create/rename/delete tools. | Add source-aware list creation and rename. Add deletion only with explicit empty/nonempty behavior. [FradSer list lifecycle](https://github.com/FradSer/mcp-server-apple-events/blob/b538b19dff6f3d8b68b642711944405ee787b690/README.md) is a useful baseline. | P1. Duplicate names across accounts, default/read-only lists, sync verification, and nonempty deletion fixtures. |
| Core reminders | Fetch, create, update, complete/uncomplete, delete, relative alarms, recurrence, and same-account moves exist. | Existing recurrence and move functionality exceeds some current donor paths. | No parity work needed for these basics. |
| Retrieval and filtering | Query searches titles. No dedicated ID getter, pagination parameter, completion-date range, or notes search. | Exact-ID get, notes-inclusive search, and bounded pagination. Completion-range and priority filters support useful review workflows. | P1/P2. Empty/missing due dates, large lists, completion boundaries, stable page ordering. |
| URL and location | Create/update expose neither native URL nor geofenced alarms. | Add native URL and location-alarm fields using public API where available. | P1. Validate URI handling, arrival/departure, alarm replacement/clear behavior, permission denial. |
| Native advanced features | Sections readable. Native subtask/tag/section/attachment writes absent. | Evaluate an explicitly optional advanced backend, or begin with read-only hierarchy/tag enrichment. | P3 research. macOS version compatibility and sync behavior must be demonstrated before enabling writes. |

The [rex capability catalog](https://github.com/rex/mcp-apple-reminders/blob/b9b12fb5d834a5b63b5d98f47cdc8754f2c4945b/docs/TOOLS.md) documents 58 tools, including URL/location alarms, list operations, bulk outcomes, subtasks, tags, sections, templates, and attachments. Many advanced writes use private ReminderKit. Its `set_parent` is explicitly deferred despite appearing in the tool list. Thus tool count overstates implemented capabilities. Bulk completion with individual outcomes is useful P2 work. Workflow-specific `Claude-*` list tools should not become Apple Core product conventions.

Apple Core documents native subtask API exclusions in the source header. FradSer's checklist subtasks live inside reminder notes. Do not present that convention as native hierarchy or silently rewrite the user's notes to imitate it.

## User-requested Reminders CLI comparison

The user called the reference “Remindersctl.” This review inferred **remindctl** from local provenance: the restore-Mac snapshot lists `steipete/tap/remindctl`, and the computer-history skill records `/opt/homebrew/bin/remindctl` on August 27. Search found no separate authoritative project matching the exact spelling. Oliver confirmed the identification on September 11, 2026. The current repository is [openclaw/remindctl](https://github.com/openclaw/remindctl), formerly referenced through steipete. **viticci/remctl is a different project**, also worth comparison.

| CLI | Current maintenance evidence | Additional Apple Core opportunities | Implementation choice |
|---|---|---|---|
| [openclaw/remindctl](https://github.com/openclaw/remindctl/blob/1b71fb003087a6930b809379a7f36760df1ec133/README.md) | September 7, 2026 commit `1b71fb0`, unarchived, 362 stars. Documents a 90% coverage gate and release harness. | List-ID targeting, native URL, title/notes/URL search, detail lookup, export, deep links, diagnostics, location alarms. | Public EventKit functionality fits Apple Core's existing native service. Prefer implementing the missing operations there, rather than requiring another executable. |
| [viticci/remctl](https://github.com/viticci/remctl/blob/a579db5281ab7562e3942e2410adeaa310c1235f/README.md) | September 4, 2026 commit `a579db5`, unarchived, 423 stars. Signed-host release documents current macOS 27 verification and a macOS 26 validation limitation. | Native hierarchy, sections, tags, assignment, attachments, smart lists, templates and richer read metadata. | Useful advanced-backend feasibility reference. Private writes are explicitly experimental. Its signed host and separate permissions make simple executable bundling insufficient. |

The public CLI preserves other alarm classes when editing absolute alarms and offers exact list-ID selection when names are ambiguous. Apple Core should adopt these semantics before adding friendly name matching. It mirrors URLs into a managed notes line, which Apple Core should not copy silently. Its documented exclusion of sections, tags, attachments and urgent state confirms the distinction between public and private API coverage.

RemCTL's default architecture reads SQLite but saves mutations through EventKit or opt-in ReminderKit, never direct database writes. Its EventKit fallback has lower fidelity and a different identifier type. An optional integration would need explicit capability reporting and ID translation. Ordinary JSON import is not lossless restore and can partially succeed, so export/import should include honest fidelity and per-item outcomes.

### Wrapper feasibility and focused verification

An MCP wrapper around either CLI is technically plausible because both offer machine-readable output. It should use a pinned, identified executable and structured argument arrays, bounded subprocess execution, explicit target account/list IDs, and parseable results. CLI success must not be interpreted as proof that every downstream sync completed. Apple Core's existing native permission boundary is simpler for public EventKit additions.

A dedicated follow-up should compare **native read enrichment versus optional RemCTL integration** using isolated databases and a test iCloud account. Cover identifier stability, partial failures, missing Full Disk Access, duplicate list names, shared-list assignment ambiguity, and macOS 26/27 differences. Test modern features individually, especially section moves, parent changes, grocery sorting, and templates. Avoid a generic “58 tools equals parity” acceptance test.

## Contacts

| Area | Apple Core today | Concrete opportunity | Priority and verification |
|---|---|---|---|
| Record lifecycle | Search/get/create/update/delete, me, photo read, groups, group membership, group creation. | Core coverage is already broad. Photo retrieval is not missing. | Preserve identifiers and linked-contact behavior. |
| Account targeting | Creation uses default container. | Known issue [#9](https://github.com/oliverames/apple-core/issues/9). Resolve account/container discovery and explicit target selection before broader writes. | P1, existing tracked work. Verify iCloud target and cross-container groups. |
| Discovery | Search by name, phone, email. No bounded directory pagination or explicit duplicate-candidate tool. | Add paginated directory and read-only duplicate suggestions. [JonathanRReed Contacts source](https://github.com/JonathanRReed/Apple-MCPs/blob/9d0d86dea31589303ab4c4c53be659f2de00729c/AppleContacts-MCP/src/apple_contacts_mcp/tools.py) exposes both and recipient resolution. | P1/P2. International numbers, shared household emails, linked records, ambiguity. Never auto-merge suggestions. |
| Group lifecycle | Create/list/add/remove supported. No rename/delete. | Complete group rename/delete while preserving members. [griches catalog](https://github.com/griches/apple-mcp/blob/461524625402548f7729db9f7a3758264b7644be/README.md) includes group deletion. | P2. Confirm deleting a group never deletes its contacts. |
| Rich writes | Writable schema omits nickname, relationships, URL/social fields, image and note content. Some richer fields are fetched. | Extend public writable fields incrementally. Photo update is useful. Notes needs separate entitlement/API verification. | P2/P3. Preserve unrelated labeled values. Assess Contacts note entitlement before promising support. |

Recipient resolution should return ranked candidates and ambiguity, not confidently choose a person from a weak name match. Automatic merging or rewriting account ownership is outside this recommendation.

## Messages

| Area | Apple Core today | Concrete opportunity | Priority and verification |
|---|---|---|---|
| Basics | Five tools cover fetch, chats, attachment metadata, unread, and text send. Direct SMS/iMessage and existing group sends exist. | Do not count group sending or unread discovery as missing. | Keep sends separate from reads. |
| Thread targeting | Fetch filters participants/date/text, without `chat_id`. | Add exact conversation targeting so a group chat can be read without conflating chats with overlapping participants. | P1. Same participants in multiple conversations, renamed group, pagination. |
| Attachments | Metadata only, no returned attachment identifier/content retrieval. | Add stable attachment IDs and bounded fetch-by-ID, with date/contact/MIME filters. | P1. Missing/cloud-only files, symlink/root boundaries, size caps, remote image/document content. |
| Search and diagnostics | Literal content search and service activation. | Approximate search and a purpose-built Messages access/route diagnostic. | P2. Distinguish likely iMessage routing from guaranteed delivery. |
| Additional sends | No file-send or scheduled-send tool. | Optional future work, not a verified high-value donor gap from this review. | P3. External side effects and duplicate-send retry risks require separate design. |

[mac_messages_mcp's current README](https://github.com/carterlasalle/mac_messages_mcp/blob/ee5512c3e3333d999ce02a448a09bf70be7b12c8/README.md) provides the closest comparison: attachment metadata search and selected attachment retrieval are separate, alongside fuzzy message search, group reads/sends, access diagnostics, and likely service availability. Apple Core should reuse that separation and review its isolated fixture testing approach. A Home Server path alone is not a usable attachment result for Muse's remote client.

## Shortcuts

| Area | Apple Core today | Gap or conclusion | Priority and verification |
|---|---|---|---|
| Main operations | List shortcuts, list folders, run, view. Text/file input and typed file output already exist. | Matches the main operations of JonathanRReed's focused Shortcuts server. No demonstrated broad functional deficit. | Avoid adding redundant run variants. |
| Diagnostics | No dedicated Shortcuts health tool. | Add availability, permission/input/output failure distinctions, and a bounded harmless diagnostic shortcut fixture. | P2. Silent success, interactive shortcuts, timeout, binary output and inaccessible shared folders. |
| Shortcut creation/export | Not exposed. | No sufficiently verified maintained reference in this review establishes safe creation/export parity. | P3 research only. Do not advertise unsupported CLI operations. |

[Apple's command-line guide](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac) documents listing, execution, viewing, file input/output, and signing. Existing Apple Core already covers the ordinary agent execution path. [JonathanRReed's Shortcuts source](https://github.com/JonathanRReed/Apple-MCPs/blob/9d0d86dea31589303ab4c4c53be659f2de00729c/AppleShortcuts-MCP/src/apple_shortcuts_mcp/tools.py) adds health and state refresh around the same four core operations.

## Recommended sequence

1. Complete Contacts account targeting under existing issue #9. Add bounded Contacts directory reads and explicit Messages chat targeting.
2. Add Messages selected-attachment retrieval, then richer attachment filters. Verify actual remote client content delivery.
3. Add reminder list creation/rename, exact-ID retrieval, native URL, and location alarms. Keep deletion behavior explicit.
4. Add read-only Contacts duplicate suggestions, reminder search/pagination improvements, and app-specific health results.
5. Run isolated feasibility work for native Reminders hierarchy and Calendar invitations. Private APIs and external invitations need separate acceptance criteria.

These are candidate enhancements, not reproduced bugs. No new issues were filed by this research subtask. The coordinating review should deduplicate and track selected work before implementation. Any design or code adoption must follow current `NOTICE` attribution and licensing rules, rather than the older donor document's conflicting licensing language.

## Remaining focused research

The strongest resolved comparisons are Messages versus mac_messages_mcp and Reminders versus remindctl/RemCTL. Contacts duplicate suggestions need an algorithm and fixture review before selecting a donor implementation. Calendar invitations need an isolated scripting proof, because documentation alone cannot establish reliable delivery. Shortcuts authoring/export remains weakly evidenced and should get a dedicated primary-source search only if product demand justifies it. No live donor performance comparison was performed, so this report makes no speed or reliability ranking.
