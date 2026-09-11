# Notes and Mail MCP capability review

Author: Oliver Ames  
Verified: September 10, 2026  
Apple Core source: `98c48c3a69bba62ad627ab5757c27f9243a4b01c`

## Recommendation

Prioritize attachment-safe Notes mutation and complete Mail search before adding more tools. Notes already covers most of its donor’s everyday functions. Mail has gained substantial write and organization coverage since the July audit, but still relies on mailbox-scoped scripting for reads. Tool counts alone substantially understate Apple Core’s coverage because individual tools combine read/unread and batch operations.

This is a source and primary-documentation comparison, not a live-data test. Upstream functionality below is documented by its maintainer unless explicitly identified as Apple Core source evidence. Upstream performance claims were not independently benchmarked.

## Comparison set and current maintenance evidence

GitHub repository API metadata was fetched on September 10, 2026. All five repositories were unarchived. Latest push is an activity signal, not proof of reliability or release support. These are strong comparison candidates, not a claim to have exhaustively ranked every MCP.

| Reference | Latest push, UTC | Stars at observation | Why compare |
|---|---|---:|---|
| [sweetrb/apple-notes-mcp](https://github.com/sweetrb/apple-notes-mcp) | September 10, 2026 | 115 | Actual Notes tool-surface donor, with documented attachment-write guards and rich diagnostics. |
| [sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) | September 10, 2026 | 72 | Broad Mail tool reference, optional IMAP/SMTP paths, diagnostics and rules. |
| [imdinu/apple-mail-mcp](https://github.com/imdinu/apple-mail-mcp) | August 23, 2026 | 63 | Existing disk-first Mail indexing architecture reference. |
| [patrickfreyer/apple-mail-mcp](https://github.com/patrickfreyer/apple-mail-mcp) | August 4, 2026 | 207 | Larger adoption signal among this comparison set, consolidated cross-account search and body/date filtering. |
| [parasxos/apple-mail-mcp](https://github.com/parasxos/apple-mail-mcp) | September 8, 2026 | 26 | Emerging read-only database and verified-send architecture reference. Its benchmark and scheduling claims need separate evaluation. |

`NOTICE` explicitly identifies sweetrb’s Notes project as the design donor, including checklist protobuf knowledge. The Mail comparison has two distinct references: sweetrb for breadth and imdinu for indexing. `NOTICE` requires clean-room use of the GPL Mail reference for the signed distribution. Historical planning text contains older conflicting implementation language, so use the current notice and licensing policy when implementing.

## Notes

Source: `App/Services/Notes.swift`, `Shared/NotesDatabaseReader.swift`, and the [current donor tool reference](https://github.com/sweetrb/apple-notes-mcp#tool-reference).

| Capability | Current Apple Core | Gap and priority |
|---|---|---|
| CRUD, title/body search, folders, accounts, native move, batch move/delete | Implemented. Search scopes are all/title/body. Native move preserves the original note rather than recreating it. | Do not re-add the July audit’s now-implemented gaps. |
| Attachments | List, save, fetch base64 and reveal are implemented. Saves avoid overwrites. | **P0, known issue [#4](https://github.com/oliverames/apple-core/issues/4):** append and body replacement lack the donor’s attachment-state refusal. This is a safety gap, not missing attachment tools. |
| Optimistic update concurrency | `notes_update` accepts `expected_hash`, checks a snapshot and uses the guarded update script. | Implemented. Append has no equivalent argument. Include stale append and unknown attachment state in #4 acceptance tests. |
| Markdown and checklists | Both Markdown conversion and database checklist-state reading exist. Markdown explicitly renders checklists as ordinary list items. | **P1:** combine existing state into Markdown `[x]`/`[ ]` output. Test duplicate labels, nested lists and Unicode offsets. |
| Account targeting | Account listing includes `isDefault`, default folder name and ID. Folder creation and move support account selection. | **P1:** create/search/list use folder names without an account selector. Add account/folder identity to those operations and reject ambiguous names. A separate default-location tool is unnecessary because the data already exists. |
| Metadata, deep links, shared-note listing, sync counts, health/doctor, exports and GUI reveal | Implemented. Sync output explicitly distinguishes unknown columns and local-only notes. | Preserve this truthful heuristic contract. Do not market counts as verified iCloud delivery. |
| Rich attachment rendering | The HTML converter handles a limited set of tags and attachment placeholders. | **P2:** evaluate faithful table and attachment-aware export with isolated image, table, PDF and scanned-note fixtures. Do not promise writable tables, tags, pinning or collaboration controls without a supported path. |

The donor currently refuses unsafe attachment-bearing body rewrites and exposes account-aware note operations. It also annotates Markdown with checklist state when database access is available. Those are more useful parity targets than matching its tool names one for one.

## Mail

Source: `App/Services/Mail.swift`. Current code implements accounts/mailboxes, reads, search, read/flag/move/delete batches, selection, refresh, send/draft/reply/forward, approximate threads, counts/stats, attachment list/save, mailbox CRUD and templates. Contacts lookup is already covered by Apple Core’s Contacts surface.

| Capability | Current Apple Core | Gap and priority |
|---|---|---|
| Search completeness | `mail_search` requires account and mailbox, matches subject or sender substrings, and returns a capped array. | **P1, known issue [#3](https://github.com/oliverames/apple-core/issues/3):** body and cross-mailbox search, dates, attachment filters, pagination and explicit completeness metadata. Compare imdinu’s disk-first index and patrickfreyer’s consolidated search contract. |
| Reliable large-mailbox reads | JXA reads with operation timeouts. | **P1:** implement the planned read-only local index and reconciliation. Report unavailable/undownloaded content and stale index state. Measure completeness as well as latency. |
| Send/draft attachments and body fidelity | Shared compose schema supports recipients, account, subject and plain-text body. No attachment or HTML input. | **P1:** add bounded attachment sending and draft inspection. Verify MIME content and received attachment bytes using isolated messages. sweetrb documents path/base64 attachments and an optional SMTP path. |
| Conversation identity | `mail_get_thread` explicitly groups normalized subjects in the same mailbox. | **P1:** use Message-ID/References and include Sent/Inbox across mailbox boundaries. Subject grouping should remain a disclosed fallback. sweetrb documents header-based threading for IMAP IDs. |
| Remote attachment retrieval | Mail lists attachments and saves them on the server. Unlike Notes, Mail has no inline fetch tool. | **P1:** bounded base64 or MCP resource retrieval so remote clients can actually consume saved bytes. Include MIME type, size limits and temporary-file cleanup. |
| Health and sync troubleshooting | Counts/stats and check-for-new-mail exist. No Mail-specific health, doctor or sync-status registration. | **P2:** diagnose permission, account reachability and incomplete local download state. Avoid equating a refresh command with completed sync. |
| Mail rules and smart mailboxes | No registered rule or smart-mailbox tools. | **P2:** read-only rule inspection first. sweetrb documents rule operations and smart mailboxes. Any writes require account-specific fixtures and an assessment of private storage formats. |
| Batches, templates, mailbox management | Implemented under combined tools, including per-ID batch results. | No parity gap merely because upstream has more individual tool names. |

[imdinu’s README](https://github.com/imdinu/apple-mail-mcp#performance) describes `.emlx` reads, FTS5 body indexing and a benchmark against six servers. Treat its timings as maintainer measurements. The relevant design lesson is avoiding repeated scripting scans while explicitly reconciling moved, deleted and partially downloaded messages.

The [sweetrb Mail documentation](https://github.com/sweetrb/apple-mail-mcp#configuring-email-imap--smtp) provides a second route through server-side IMAP and clean SMTP. Do not automatically introduce that route: it adds credential management, identity mapping, duplicate prevention and Sent-folder behavior. First evaluate whether local disk reads solve the Apple Core use case.

## Implementation order and verification

1. Finish #4 using disposable text, table, image and attachment fixtures. Verify counts, bytes and rendered content before and after writes. Refuse unknown attachment state.
2. Finish #3 with a synthetic mailbox corpus containing old messages, repeated subjects, moves, deletes and partial downloads. Report search coverage and bounded pagination.
3. Add remote Mail attachment retrieval and compose attachments. Use a dedicated test identity and controlled recipient for any send verification.
4. Add identity-aware Notes targeting and checklist-aware Markdown using existing database readers.
5. Evaluate true Mail threading and diagnostics before expanding into rules or scheduling.

No user notes or messages were changed, no additional issues were filed, and no application source was modified by this review. The listed additions are proposals. Known bugs remain tracked in #3 and #4.
