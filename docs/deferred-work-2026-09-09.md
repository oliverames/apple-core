# Deferred work follow-up, September 9, 2026

Author: Oliver Ames

## Notes concurrent updates, issue #1

Implemented optional `expected_hash` on `notes_update`. A caller reads `notes_get`, retains `bodyHash`, and supplies it with the update. The handler re-reads the HTML body and compares its SHA-256 hash. A mismatch returns `notes_update_conflict` before invoking the write script. Empty hashes also fail rather than disabling protection. Omitting the parameter preserves legacy behavior.

The update script checks the captured body again immediately before replacement, using exact JavaScript string comparison. This catches changes that arrive between the first read and script execution. It is optimistic concurrency, not an atomic transaction. Notes can still change between its final read and write Apple events.

The existing hash format and response fields are preserved. The update script now returns JSON, matching other Notes scripts. No credentials, Notes content, or live note identifiers were used as fixtures.

Validation:

- Seven Swift Testing tests passed, including parameterized stale/empty hashes, second-read conflicts, guarded and legacy writes, failed reads, Unicode content, and a known SHA-256 value.
- JavaScriptCore executed the production update script against an isolated Notes object fixture. Conflicting cases made zero writes.
- Full Debug app and CLI compilation passed with signing disabled.
- Changed Swift files passed strict formatting checks. The Xcode project passed property-list validation and the diff passed whitespace checks.

These are source and isolated-test results. Apple Core was neither installed nor launched on the MacBook. Home Server still needs the updated build and designated disposable-note acceptance under issue #6. Attachment guards and append protection remain separately tracked in issue #4. This change does not claim attachment safety.

## SDK compatibility adapter, issue #8

Current GitHub inspection found upstream swift-sdk issue #262 still open without maintainer comments. Release 0.12.1 remains the latest published release. Its tag resolves to `a0ae212ebf6eab5f754c3129608bc5557637e605`, the exact revision pinned by Apple Core. The checked-out client capability model still uses `[String: String]?` for `experimental`.

The adapter and dependency remain unchanged. Removal still depends on a released upstream fix plus regression and live client acceptance. The current blocker was recorded on issue #8.

## Tracking

- Notes implementation: https://github.com/oliverames/apple-core/issues/1
- Home Server acceptance and installation follow-up: https://github.com/oliverames/apple-core/issues/6
- Attachment and append safety: https://github.com/oliverames/apple-core/issues/4
- SDK release prerequisite: https://github.com/oliverames/apple-core/issues/8
- Upstream issue: https://github.com/modelcontextprotocol/swift-sdk/issues/262
