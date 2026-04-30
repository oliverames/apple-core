# icloud-mcp (adamzaidi) — Review
**URL:** https://github.com/adamzaidi/icloud-mcp
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Adam Zaidi (sole author, active maintainer)
- **License:** MIT (declared in package.json and README; no LICENSE file in repo root)
- **Last commit:** 2026-04-02 (commits in last 90 days: 45)
- **Activity signal:** Very active. 20 most recent commits walk versions v1.5.x → v2.6.0 with steady feature growth (Gmail multi-account, JXA Reminders, CalDAV fixes, ReDoS security patch).

## Stack
- **Language / runtime:** Node.js v20+, ES modules
- **MCP transport(s):** stdio only (`StdioServerTransport` from `@modelcontextprotocol/sdk` ^1.27.1)
- **Build / install path:** `npm install -g icloud-mcp` then point Claude config at `node $(npm root -g)/icloud-mcp/index.js`; `--doctor` flag does a self-test (env vars, IMAP login, INBOX open) before wiring into Claude
- **Distribution:** Was on npm under name `icloud-mcp` through v2.5.1; the latest commit (`d0d3fcf`) flips `private: true` to block further publishes, so going forward it ships from source / `npx` against the GitHub repo

## Apple surfaces covered
- iCloud Mail (IMAP at imap.mail.me.com + SMTP at smtp.mail.me.com)
- iCloud Contacts (CardDAV at contacts.icloud.com, partition-host aware)
- iCloud Calendar (CalDAV at caldav.icloud.com, partition-host aware)
- iCloud Reminders (JXA bridge to Reminders.app — explicitly bypasses CloudKit)
- Plus generic IMAP/SMTP for Gmail and other providers via numbered `IMAP_ACCOUNT_N_*` env vars

## Tool inventory
README claims 65, v2.5.0 commit says 69, index.js handler list runs ~70+ across:
- Mail read/search (17): inbox/mailbox summaries, list_mailboxes, read_inbox, get_email, get_email_raw, get_emails_by_sender/date_range, search_emails, get_thread, count_emails, get_top_senders, get_unread_senders, get_storage_report, get_unsubscribe_info, list_attachments, get_attachment
- Mail send/draft (4): compose_email, reply_to_email, forward_email, save_draft
- Mail per-message write (4): flag_email, mark_as_read, delete_email, move_email
- Mail bulk (14): bulk_move/_by_sender/_by_domain, archive_older_than, bulk_delete/_by_sender/_by_subject, delete_older_than, bulk_mark_read/_unread, mark_older_than_read, bulk_flag/_by_sender, empty_trash
- Mailbox mgmt (3): create_mailbox, rename_mailbox, delete_mailbox
- Move tracking (2) + saved rules (5)
- Contacts CardDAV (6): list/search/get/create/update/delete_contact
- Calendar CalDAV (7): list_calendars, list_events, get/create/update/delete_event, search_events
- Reminders JXA (7): list_reminder_lists, list/get/create/update/complete/delete_reminder
- Digest state (2) + session log (3)

## How it talks to Apple / iCloud
Pure network protocols, no pyicloud-style web-auth scraping. Mail uses `imapflow` over TLS to imap.mail.me.com:993 (with a serialized 10ms connect-gate to dodge iCloud throttling) and `nodemailer` over STARTTLS to smtp.mail.me.com:587. Contacts/Calendar use raw `fetch` PROPFIND/REPORT/PUT/DELETE against contacts.icloud.com and caldav.icloud.com with Basic auth, doing well-known → principal → home-set discovery and caching the partition host (e.g. p137-contacts.icloud.com) per process. Reminders is the odd one out: CalDAV VTODO is broken on iCloud, so it shells `osascript -l JavaScript` and drives Reminders.app via JXA. Move manifests, rules, and digest state persist as JSON in `~/.icloud-mcp-*.json`.

## Permissions / TCC model
Mail/Contacts/Calendar are pure network and trigger zero TCC prompts. Reminders is the only TCC surface — first JXA call surfaces the macOS Automation prompt and `lib/reminders.js` catches "not allowed / Authorization / assistive access" stderr to print a one-line bootstrap command. No 2FA dance: the user supplies an Apple app-specific password via `IMAP_USER`/`IMAP_PASSWORD` env vars (reused for CardDAV/CalDAV Basic auth). Credentials live in the Claude config file; `.env` and `.mcp.json` are gitignored, and `.mcp.json.example` references shell variables only.

## Testing posture
Single-file integration suite at `tests/test.js` (~1,268 lines, 84 tests) that spawns the MCP server via stdio and exercises each tool end-to-end against a real iCloud account. Per-category timeouts (60s / 5min / 15min). No unit tests, no GitHub Actions workflow, no CI. Running tests requires real `IMAP_USER` / `IMAP_PASSWORD`.

## Notable strengths (worth stealing)
1. **Three-phase safe move** — copy → fingerprint-verify → single EXPUNGE, with persistent manifest at `~/.icloud-mcp-move-manifest.json`, plus `get_move_status`/`abandon_move` recovery and a >24h stale warning.
2. **`--doctor` self-test flag** walking env vars → TCP+TLS → IMAP greeting → AUTH → INBOX open with green-check plain-English output. High-leverage UX before any Claude config edit.
3. **Connect-gating for iCloud throttle** — single global `_connectGate` promise serializes connection initiations 10ms apart while letting in-flight sessions run concurrently.
4. **Pragmatic JXA Reminders fallback** when CalDAV VTODO is broken on iCloud, plus exemplary error-translation for the TCC Automation denial.
5. **Saved-rules engine inside the server** (create_rule / run_rule / run_all_rules with dryRun) and a `log_write`/`log_read`/`log_clear` session journal so Claude can resume multi-step bulk runs.

## Gotchas / things to avoid
1. **App-specific password is the only auth path.** No keychain integration; the same plaintext password sits in `claude_desktop_config.json` and is reused for IMAP, SMTP, CardDAV, and CalDAV Basic auth. Anyone with read on that file gets full mail+contacts+calendar.
2. **Credentials read directly from `process.env` inside `lib/carddav.js` and `lib/caldav.js`** rather than threaded through the `creds` object the IMAP/SMTP layers accept — multi-account works for mail but Contacts/Calendar always hit the primary `IMAP_USER` account.
3. **Persistent state in `$HOME` is unencrypted** — `.icloud-mcp-move-manifest.json` and `.icloud-mcp-rules.json` sit in plain JSON in the home directory with no schema versioning.
4. **No LICENSE file in the repo root** despite README and package.json declaring MIT; only the metadata claim exists.
5. **`hasAttachment` filter scans up to 500 candidates client-side**, so on broad searches it silently truncates — README warns but tool callers may not notice.

## License compatibility for our combined project
MIT is fully compatible with our intended MIT or Apache-2.0 combined project; only carry the upstream copyright notice.

## Verdict
A polished iCloud MCP: native protocol coverage (IMAP/SMTP/CardDAV/CalDAV) plus a JXA escape hatch for Reminders, with safe-move semantics and a doctor command worth copying. Best fit in synthesis as the donor for Mail/Contacts/Calendar/Reminders behavior; refactor the credential-handling layer before merging.
