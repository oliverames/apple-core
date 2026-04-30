# mcp-server-apple-events — Review
**URL:** https://github.com/FradSer/mcp-server-apple-events
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Frad LEE (`fradser`) — solo maintainer, tagged at v1.4.0.
- **License:** MIT (Copyright 2025 Frad LEE).
- **Last commit:** 2026-04-23 (commits in last 90 days: 51).
- **Activity signal:** Very active. Recent commits show ongoing TCC/hardened-runtime work for macOS 26, recurrence-frequency expansion (hourly/minutely), tag handling, and an AppleScript fallback for cross-list reminder moves. Real maintenance, not a drive-by.

## Stack
- **Language / runtime:** TypeScript (Node ESM, `type: "module"`) for the server, plus a single Swift source file (`EventKitCLI.swift`, ~1,760 lines) compiled with `swiftc` into a sidecar binary.
- **MCP transport(s):** stdio only (`StdioServerTransport` from `@modelcontextprotocol/sdk` v1.25).
- **Build / install path:** `pnpm install` runs a `postinstall.mjs` that triggers `build-swift.mjs`. That script invokes `swiftc -framework EventKit -framework Foundation` with `-Xlinker -sectcreate __TEXT __info_plist` to embed `Info.plist`, then `codesign --force --sign - --options runtime --entitlements EventKitCLI.entitlements` to ad-hoc sign with hardened runtime. Output is `bin/EventKitCLI`.
- **Distribution:** Published to npm as `mcp-server-apple-events`; entry shim is `bin/run.cjs`. Repo notes that `npx` users must build the Swift binary manually after install.

## Apple surfaces covered
- Reminders (EventKit `EKReminder` + lists)
- Calendar events (EventKit `EKEvent` + calendars/accounts)
- Reminder subtasks/checklists (synthesized inside the notes field)
- Reminder tags (`#tag` extracted/preserved in notes)
- Geofenced alarms (`EKAlarm.structuredLocation` + proximity)
- Recurrence rules (minutely → yearly, with byday/bymonth/etc.)

## Tool inventory
- `reminders_tasks` — read/create/update/delete reminders, with priority, alarms (relative/absolute/location), recurrence, dueDate, completionDate, initial subtasks.
- `reminders_lists` — read/create/update/delete reminder lists, hex color, rename.
- `reminders_subtasks` — read/create/update/delete/toggle/reorder subtasks (stored in notes between `---SUBTASKS---` markers).
- `calendar_events` — read/create/update/delete calendar events, all-day, availability, structured location, recurrence, alarms, span (`this-event`/`future-events`), filter by calendar/account/search.
- `calendar_calendars` — read calendar collections (so the model can pick a `targetCalendar`).

Five tools, but each is a fat verb-dispatcher driven by an `action` enum, which keeps the surface compact while still covering full CRUD.

## How it talks to Apple
Almost everything goes through the **Swift `EventKitCLI` binary** linked against EventKit/Foundation. The TS layer (`utils/cliExecutor.ts`) spawns the binary via Node's `execFile` (never the shell-using variant — the file documents the shell-injection reasoning and references Swift ArgumentParser for type-safe args), passes `--action ...` flags, and parses a strict `{status:"success",result}|{status:"error",message}` JSON envelope. Permission errors are detected by regex against the message and re-thrown as `CliPermissionError` with a `reminders|calendars` domain tag. There is **one AppleScript fallback**: cross-list reminder moves, where EventKit returns error -3002 across iCloud/local sources, are retried via `osascript -e 'tell application "Reminders" ... move ...'`. That path also handles the Automation-TCC denial case with a specific error message pointing the user at System Settings → Privacy & Security → Automation.

## Permissions / TCC model
The Swift binary itself owns the TCC dance. `Info.plist` (embedded into `__TEXT,__info_plist`) declares `NSRemindersUsageDescription`, `NSRemindersFullAccessUsageDescription`, `NSRemindersWriteOnlyAccessUsageDescription`, and the three matching `NSCalendars*UsageDescription` keys, plus `LSBackgroundOnly`. Entitlements grant `com.apple.security.personal-information.calendars` and `.reminders`. The binary is **ad-hoc signed with `--options runtime`** because macOS 26+ refuses to show calendar TCC prompts to subprocesses of GUI apps (e.g., Claude Desktop) without a hardened runtime — there's a recent commit explicitly enabling this. There is also a `check-permissions.sh` helper that exercises read/read-calendars and an osascript probe to surface Automation-TCC state. No notarization, no Developer ID; users grant Reminders, Calendars, and (for cross-list moves only) Automation → Reminders to whatever process spawns the binary.

## Testing posture
Heavy. 28 `*.test.ts` files under `src/`, Jest with ts-jest ESM preset, a `__mocks__/cliExecutor.ts` for unit tests, and explicit coverage thresholds in `jest.config.mjs` (96% statements, 90% branches, 98% functions, 96% lines). Tests cover the entitlements file, Info.plist keys, the `build-swift` script, date filtering, timezone integration, subtask/tag parsing, repository layers, and a top-level `e2e.test.ts`. No GitHub Actions workflows in the cloned tree (`.github/` is absent); CI presence is unclear from the repo alone. Biome is used for lint+format.

## Notable strengths (worth stealing)
- **EventKit-first, AppleScript only as a documented fallback** for the one operation EventKit genuinely cannot do (cross-source reminder move, error -3002). The fallback is isolated, named `runAppleScriptMove`, and has its own error message for Automation-TCC denial.
- **Hardened-runtime + embedded Info.plist via `-Xlinker -sectcreate`** for a single-file Swift sidecar. This is the cleanest pattern I've seen for a CLI that needs TCC dialogs to fire under a GUI parent process on macOS 26+.
- **Strict JSON envelope** (`status: success|error`) between Node and Swift, with permission errors classified by domain via regex on the Swift message — turns into a typed `CliPermissionError` with `'reminders' | 'calendars'`.
- **Binary path validation** (`binaryValidator.ts`) restricts spawn targets to a small allowlist of paths, defending against substitution attacks if the package is installed into a writable location.
- **Confidence-gated prompts** (HIGH/MEDIUM/LOW) baked into the server's prompt templates, with LOW always routing to `AskUserQuestion` rather than emitting freeform questions.

## Gotchas / things to avoid
- **`postinstall` requires Xcode CLT and macOS.** `npx mcp-server-apple-events` on a non-darwin host fails immediately; npm installs without the toolchain leave a broken binary. The README documents a manual rebuild dance, but it's friction.
- **Subtasks live inside the notes field**, sandwiched between `---SUBTASKS---` markers, with `[ ] {uuid}` lines. Any other writer of that note field will corrupt them. Tags share the same field.
- **Ad-hoc codesign only.** Acceptable for personal/local use, but not redistributable through the App Store; on a fresh machine the user will see the standard "downloaded from internet" Gatekeeper friction unless they build locally.
- **AppleScript fallback adds a hidden TCC dependency** (Automation → Reminders, granted to the *parent* process — Claude Desktop, Terminal, etc., not the EventKitCLI binary). Easy to miss until a cross-list move suddenly fails.
- **Single sprawling Swift file** (1,763 lines) holds the entire EventKit surface. Functional, but any future contributor inherits one giant translation unit.

## License compatibility for our combined project
MIT — fully compatible with both MIT and Apache-2.0 combined projects; only attribution is required.

## Verdict
The strongest pure-EventKit implementation in the set: a hardened, signed Swift sidecar driving Reminders + Calendar via native APIs, with AppleScript reserved as a single, documented escape hatch. For the synthesis, lift its Swift-CLI build/sign pattern, its JSON envelope + permission-error classification, and its Reminders/Calendar tool shape — but pair them with a different note-encoding scheme if subtasks need to coexist with another writer.
