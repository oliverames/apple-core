# Apple Core system surfaces: MCP coverage review

Author: Oliver Ames  
Research date: September 10, 2026  
Apple Core source reviewed: `98c48c3`  
Scope: Filesystem, Capture, Utilities, Location, Maps, Weather. Shortcuts has a separate reviewer.

This is a source and primary-documentation comparison, not an executed certification of competing servers. Priorities reflect useful workflows and bounded implementation effort. Recent commits demonstrate activity, not reliability. No application code or user data changed during this review.

## Source and runtime boundary

[ServiceRegistry](../../App/Controllers/ServerController.swift) registers twelve services and conditionally adds Weather under `WEATHERKIT_AVAILABLE`. The six surfaces below contain 39 tool declarations, of which six are Weather tools. A declaration does not establish visibility in a particular installed build. Service settings, activation state, permissions, and remote-client policy must also permit access.

[NOTICE](../../NOTICE) identifies iMCP as the MIT-licensed ancestor. It requires donor attribution when implementation incorporates another project's code or substantially derived design. This report recommends behavior, not importing code. In particular, the GPL Google Maps comparator needs separate distribution/license review before any code reuse.

## Comparator selection and maintenance evidence

GitHub API repository and latest default-branch commit responses were checked on September 10, 2026. All listed repositories reported `archived: false`. These are observed timestamps, not release dates. The reference servers repository timestamp does not prove the Filesystem subdirectory changed that day.

| Comparator | Observed latest commit | Why considered |
| --- | --- | --- |
| [MCP reference Filesystem](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) | [d73f99efbfd4](https://github.com/modelcontextprotocol/servers/commit/d73f99efbfd4), September 3, 2026 | Clear tool contracts and repository test directory. Useful baseline for file operations, not a production security endorsement. |
| [Peekaboo](https://github.com/openclaw/Peekaboo) | [6cd38c0d319a](https://github.com/openclaw/Peekaboo/commit/6cd38c0d319a), September 8, 2026 | Native macOS implementation, extensive capture/interaction source, recent maintenance. MIT. |
| [Open-Meteo MCP](https://github.com/cyanheads/open-meteo-mcp-server) | [9af90bfe57cc](https://github.com/cyanheads/open-meteo-mcp-server/commit/9af90bfe57cc), September 10, 2026 | Broad environmental datasets and explicit bounded-result handling. Apache-2.0. |
| [Google Maps MCP community server](https://github.com/apurvaumredkar/google-maps-mcp) | [93bb2a693175](https://github.com/apurvaumredkar/google-maps-mcp/commit/93bb2a693175), August 16, 2026 | Places and routes breadth. GPL-3.0. |
| [iMCP](https://github.com/mattt/iMCP) | [ecef7a73af75](https://github.com/mattt/iMCP/commit/ecef7a73af75), September 8, 2026 | Direct ancestry comparison. Current Utilities source still exposes only beep, so Apple Core already exceeds that baseline. |
| [Google Maps Grounding Lite](https://developers.google.com/maps/ai/grounding-lite/reference/mcp?hl=en) | Official live reference checked September 10, 2026 | Provider-maintained hosted comparator. No public server implementation or release cadence established here. |

## Filesystem

Current [Filesystem.swift](../../App/Services/Filesystem.swift) implements 16 tools: roots, list, read, write, search, stat, create_folder, move, copy, trash, append, read_binary, search_content, recent, hash, and tags. It already offers paginated directory/name search, byte-offset text reads, Spotlight document-content search, SHA-256, Finder tags, and Trash. These should not appear on a missing-features backlog.

Activation requires at least one user-shared root. Paths are checked through `FilesystemAccess`, including Spotlight hits. Text reads cap at 512 KiB and inline binary reads at 256 KiB. Content search returns matching file metadata, not snippets, and reports truncation without continuation.

| Gap | Evidence and value | Priority and acceptance criteria |
| --- | --- | --- |
| Selective text edits with preview | Reference Filesystem has `edit_file` and dry-run diffs. Apple Core offers whole-file write and append. | P1. Add exact-match edits, preview, expected-hash conflict detection, atomic commit. Test concurrent changes, repeated text, Unicode, read-only roots and symlink escapes. |
| Batch reads | Reference `read_multiple_files` supports individual failures. Apple Core requires one request per file. | P1. Bounded file count and aggregate byte budget, ordered per-file successes/errors. One denied path must not expose other roots. |
| Bounded recursive tree and exclusions | Reference `directory_tree` and glob exclusions support project exploration. Apple Core has directory pages and substring-name search. | P2. Depth/entry budgets, exclusion patterns, explicit continuation. Preserve root authorization on every child. |
| Document snippets and resumable content search | Local source exposes Spotlight matches only. This is a workflow extension, not a confirmed competitor parity claim. | P2. Return bounded snippets where supported and stable continuation. Test unindexed volumes and unavailable iCloud content explicitly. |

Do not copy the reference server's client-supplied roots behavior into hosted access. A remote client's requested paths must never expand the Mac owner's sharing grants.

## Capture

Current [Capture.swift](../../App/Services/Capture.swift) has three tools: camera picture, microphone recording, and screenshot. Screenshots target display, window, or application. Window capture requires an ID, but this surface exposes no discovery tool. Activation succeeds when any capture permission is available, so activation alone cannot certify all three tools.

Peekaboo's current [MCP tool implementation directory](https://github.com/openclaw/Peekaboo/tree/main/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools) includes application/window tools and `inspect_ui`. The latter inspects accessibility data without requiring a screenshot.

| Gap | Useful outcome | Priority and acceptance criteria |
| --- | --- | --- |
| Capture target discovery | A client can obtain valid display/window/application IDs without guessing. | P1. List only necessary target metadata. Test two displays, stale window IDs, hidden windows and locked sessions. |
| Per-modality readiness | Clients distinguish missing hardware, denied permission, locked session, and ready camera/microphone/screen. | P1. Read-only status must not trigger prompts or collect media. Test independently granted permissions. |
| Accessibility text and optional on-device OCR | Reading an interface can avoid sending a full screenshot. | P2. Separate permission and surface selection. Bound traversal/text and exclude secure fields. Verify actual background behavior before enabling remotely. |
| Cropped screenshots | Reduce irrelevant private content and response size. | P2. Validate coordinates against target bounds, scaling and multiple displays. No implicit full-screen fallback. |

Full mouse/keyboard automation is a separate product decision. Greater comparator breadth does not justify silently converting Capture into general remote computer control.

## Utilities

Current [Utilities.swift](../../App/Services/Utilities.swift) implements beep, notification, text clipboard read/write, URL opening, and basic system information. The latter includes computer name, OS version, uptime and processor count. URL opening has a scheme restriction, and notifications check authorization.

Peekaboo's [ClipboardTool.swift](https://github.com/openclaw/Peekaboo/blob/main/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/ClipboardTool.swift) provides typed clipboard data and snapshots. That is a more useful comparator than an unrestricted shell tool.

| Gap | Useful outcome | Priority and acceptance criteria |
| --- | --- | --- |
| Connector capability/health summary | Diagnoses enabled surfaces, missing permissions and relevant version information in one call. | P1. Proposed integration improvement. Reuse existing permission inventory. Redact secrets and distinguish disabled, unsupported, denied and temporarily unavailable. |
| Typed clipboard read/write | Supports an image or rich text when a workflow explicitly needs it. | P2. Advertise formats before fetching bytes. Bound payloads and honor shared-root rules for file output. |
| Clipboard snapshot/conditional restore | Temporary clipboard operations need not discard user state. | P2. Scope snapshot lifetime and ownership. Do not restore over a newer user copy operation. |
| Storage and resource summary | Allows basic host diagnostics without command execution. | P2. Optional bounded totals only, no process arguments, environment variables or broad disk inventory. This is a proposed extension rather than verified parity. |

Avoid adding arbitrary shell or AppleScript execution merely to raise tool count. Neither is needed for the priority workflows above.

## Location

Current [Location.swift](../../App/Services/Location.swift) implements current location, geocode, and reverse geocode. Device location checks authorization, uses a freshness-qualified cache and requests approximately hundred-meter accuracy. Geocoding is distinct from device tracking.

Google's official reference includes `resolve_names` with up to 20 inputs and per-input failures. Its URL resolver similarly turns shared Google Maps URLs into canonical place identities. This provides concrete interoperability patterns, not a reason to replace Core Location.

| Gap | Useful outcome | Priority and acceptance criteria |
| --- | --- | --- |
| Bounded batch geocoding | Resolve several supplied addresses with fewer remote calls. | P2. Preserve input ordering and ambiguity, rate-limit provider requests, return per-input errors. Never choose device location implicitly. |
| Explicit location freshness/precision contract | Client can tell whether an answer is sufficient for the request. | P2. Audit serialized `GeoCoordinates` before adding fields. Add observed time, accuracy and cached status only if absent. This serializer audit remains open. |
| Shared-place URL resolution | Turns a supplied map link into a reusable location. | P2. Start with supported Apple Maps URLs. Strict host validation, redirect limits and no arbitrary URL fetch. |

Continuous location history, geofencing and background tracking are not recommended as default parity work. They introduce retention and surveillance concerns beyond the current request/response surface.

## Maps

Current [Maps.swift](../../App/Services/Maps.swift) implements search, directions, explore, ETA, and static map generation. Directions already accept departure/arrival times and alternative routes. Its schema lists automobile, walking, transit and any. Schema support must be tested against actual MapKit responses before describing every mode as working.

The community comparator implements separate places/maps/routes modules and documents distance matrices, place details and multi-stop optimization. Google's official hosted reference supplies place search and drive/walk routes, but should not be credited with the community server's broader route features.

| Gap | Useful outcome | Priority and acceptance criteria |
| --- | --- | --- |
| Stable place identity and detail lookup | Search once, then request the same place's supported details. | P1. Audit `Place` serialization first. [Apple's MKMapItemRequest](https://developer.apple.com/documentation/mapkit/mkmapitemrequest) supports identifier lookup. Confirm target-OS availability and handle missing fields explicitly. |
| Route matrix | Compare candidate destinations or origins efficiently. | P2. Bound pairs and concurrency, return per-route status. A matrix can orchestrate existing native route calls. |
| Multi-stop itinerary | Travel through several specified destinations. | P2. First implement fixed-order legs with totals. Optimization requires separate algorithm and traffic assumptions. |
| Structured open-hours/accessibility filters | More actionable venue selection. | Research. Google provides richer place queries, but MapKit field availability is not established here. Do not promise reviews, opening hours or accessibility data that Apple's public API cannot supply. |

Keep native Apple Maps as the default. A Google-backed provider would require explicit configuration, billing and attribution work, and sends locations to another service.

## Weather

Current [Weather.swift](../../App/Services/Weather.swift) declares current, daily, hourly, minute, alerts and history. All six are behind the registry's `WEATHERKIT_AVAILABLE` build condition. Source inspection found no other occurrence defining that flag in the searched working tree. Build-time injection remains possible. Weather availability must therefore be established from the installed tool list, not this count.

The Open-Meteo comparator's [tool definitions](https://github.com/cyanheads/open-meteo-mcp-server/tree/main/src/mcp-server/tools/definitions) cover air quality, marine conditions, historical data, ensembles, elevation, flood and climate. Its air-quality contract distinguishes modeled data from measurements and bounds oversized results.

| Gap | Useful outcome | Priority and acceptance criteria |
| --- | --- | --- |
| Build/provider availability and dataset coverage | Clients know whether Weather exists and which regional datasets are supported. | P1 before expansion. Verify signing/build entitlement, real tool discovery, supported/unsupported regions and attribution. |
| Units, timezone and provenance audit | Forecasts can be interpreted without guessing local date or units. | P1 audit. Inspect Ontology serialization before claiming missing fields. [Apple WeatherKit](https://developer.apple.com/weatherkit/) documents additional statistics and forecast detail worth checking. |
| Air quality and pollen | Supports outdoor planning alongside the forecast. | P2 optional provider. Clearly label modeled values, units, timestamp and geographic coverage. Do not treat these as measurements. |
| Marine forecast | Useful for boating and swimming planning. | P3 optional provider with explicit units and coverage limits. |
| Long-range historical/climate/ensemble access | Supports analysis beyond ordinary daily forecasts. | P3. Validate existing history limits first. Separate observations, reanalysis, forecasts and projections. Large output needs a bounded retrieval design. |

No competing Weather server was executed. No claim is made that WeatherKit lacks every dataset offered by Open-Meteo. Provider capability and existing serialization need a focused follow-up.

## Recommended sequence

1. Complete live readiness testing and inspect serialized Place, GeoCoordinates and Weather objects. Resolve visibility and contract uncertainty before adding tools.
2. Implement Filesystem selective edits and batch reads, Capture discovery, and a connector health summary with isolated regression fixtures.
3. Add stable place lookup and bounded route comparisons using native APIs.
4. Treat typed clipboard, accessibility inspection and optional environmental providers as separately scoped work with explicit permissions and output budgets.

This document records enhancement candidates and unresolved research, not newly reproduced defects. No issues were filed or source fixes attempted by this reviewer.
