# Bug-fix pass: 2026-08-26

## Scope

This pass reviewed the macOS app, serving paths, bundled CLI, Apple service implementations, SQLite readers, and integration harness.

It did not modify live configuration, LaunchAgents, Cloudflare resources, or personal Apple data. Three independent finders checked separate areas, then cross-checked each other's claims against current source, SDK declarations, dependencies, and isolated reproductions.

## Baseline

- Strict Swift format lint passed.
- The Debug test run passed 41 tests.
- The Debug static analyzer passed.

## Confirmed fixes

### Approval and client setup

1. Approval cleanup now finishes before callbacks can present the next request.
2. Approval copy points to Settings > Clients.
3. Codex setup registers the bundled stdio bridge.
4. The integration harness uses current Calendar names.
5. Enumeration accepts the service-dependent tool set, with an optional exact-count check, while rejecting empty sets, duplicate names, and missing schemas.

### Serving and remote access

6. Config saves protect unreadable and undecodable files.
7. Locked field-level config updates preserve concurrent Settings, filesystem root, public URL, and origin changes.
8. Alternate config profiles use isolated Cloudflare agent labels.
9. Public URLs and allowed origins stay synchronized.
10. Disabled tunnels no longer advertise stale endpoints.
11. Loaded but stopped agents are booted out.
12. Startup reconciliation compensates for stale side effects, retries current settings, and stops on cleanup failure.
13. Cloudflare diagnostics fully redact secrets.
14. Adopted OAuth clients respect the 256-client cap.

### Transport and process reliability

15. JSON-RPC numeric and string identifiers no longer collide.
16. The CLI returns JSON-RPC errors for request transport and response failures.
17. Camera timeouts include the configured delay, and concurrent calls retain separate delegates.
18. Map dimensions are validated from 1 through 4096 pixels.
19. Shortcut execution drains stderr while the child runs and awaits termination without blocking the cooperative executor.

### Apple service correctness

20. Messages rejects malformed dates and participant aliases, and direct handle lookup prevents wildcard broadening or result starvation.
21. Messages uses the current user's real home directory.
22. Calendar rejects malformed bounds and occurrence selectors, validates alarm variants, and bounds recurrence intervals safely.
23. Reminders rejects malformed dates and due values, and combines completed and incomplete bounded queries.
24. Calendar and Reminder alarm arithmetic no longer overflows.
25. Contacts intersects supported predicates instead of using an unsupported compound predicate.
26. Cached locations require valid accuracy and expire after 60 seconds.
27. Messages and Reminders readers include committed WAL rows.
28. Directions default to automobile.
29. Binary reads report the file's actual size.

## Regression coverage

New tests cover approval callback reentrancy, WAL-only Messages and Reminders rows, safe participant lookup, typed JSON-RPC keys, complete secret redaction, and adopted OAuth client pruning.

## Final verification

- Strict Swift format lint passed.
- The Debug suite passed 44 test cases and 55 parameterized invocations with no failures.
- Debug static analysis passed.
- The unsigned Release build passed.
- The integration harness passed syntax, help, and isolated 11-tool enumeration probes.
- The project file, shell scripts, XML, signed appcast, and final diff passed their checks.
- Three independent final cross-checks reported no remaining regression in the changed paths.
