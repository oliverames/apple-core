# Project brief — Oliver's original prompts and decisions (2026-07-20 revival)

This file preserves the verbatim prompts and decision answers that drove the
2026-07-20 revival of Apple Core, so future sessions can consult the original
intent rather than reconstructing it. The resulting architecture decision is
recorded in [`BUILD_PLAN.md` §0a](BUILD_PLAN.md).

## Initial prompt (verbatim, voice-dictated)

> I'd like you to fork my Bridgeport repository into a new repository called
> Apple – MCP. Then I'd like you to rework Bridgeport so that it essentially
> only surfaces Apple local apps as advertised, but the key distinction here
> is that these are Apple apps, not just apps that run on the Mac. I'm
> basically trying to create a smaller, more focused utility that uses the
> same concepts and designs that we've created with Bridgeport, except
> instead of entering your own MCPs, we basically bundle a set of MCPs from
> others, like the Apple Notes MCP into one kind of simpler package. I'd like
> you to when having this work done, review the IMPC repository on GitHub. It
> essentially services all the different possible MCP Mac app types, though
> there are more, and creates them basically a local MCP server that services
> them. What I wanna do is similar to that, except designed for both local
> and remote access. The other thing to keep in mind is that Apple – notes –
> MCP is one that I handpicked because it is easily the most feature
> comprehensive, but I have not looked into similar comprehensively, you
> know, the best so far created for reminders, calendar, contacts, all of
> those types of things. I do know that the author of Apple Dash Notes – MCP
> does have an Apple mail connector that is quite robust, so we could include
> that. Actually, instead of forking Bridgeport, let's clone it, as I think
> that'll be a cleaner approach. Definitely wanna make sure that we have a
> remote set up for this on GitHub that it is set to private and you should
> do all of the work needed to get to a full release, though don't cut that
> release yet Make sure that you clone the repository into the correct
> developer/projects subdirectory

Notes on references in the prompt:

- "IMPC" = [`mattt/iMCP`](https://github.com/mattt/iMCP)
- "Apple – notes – MCP" = [`sweetrb/apple-notes-mcp`](https://github.com/sweetrb/apple-notes-mcp)
- "the author['s] Apple mail connector" = [`sweetrb/apple-mail-mcp`](https://github.com/sweetrb/apple-mail-mcp)
  — note this is a *different project* from `imdinu/apple-mail-mcp`, the
  Python/GPL server whose disk-first `.emlx`+FTS5 design BUILD_PLAN §3.1 is
  based on. Both are references for the Mail surface: imdinu's for the
  deep-index architecture, sweetrb's (the one Oliver vetted and runs as a
  plugin) for tool inventory and behavior.

## Mid-session direction change (verbatim)

> FYI I do like the idea of this "apple-core reimplements surfaces natively
> in Swift, borrowing patterns (not runtime dependencies) from those same
> donor repos, single unified signed app" Then we can take the power of all
> of those amazing MCPs like apple-notes-mcp and apple-mail-mcp and rebuild
> them as swift native

This changed the project from "clone Bridgeport and spawn other people's
published MCP servers as child processes" to "revive apple-core and rebuild
those MCPs' capabilities natively in Swift, in one signed app" — which is
what was built.

## Decision answers (from the clarifying questions)

| Question | Oliver's answer |
|---|---|
| New repo name ("Apple – MCP" isn't a valid slug; `apple-mcp` is taken) | Check the existing `apple-core` project first — it turned out to be the same concept, already researched |
| v1 scope: just Notes + Mail, or all iMCP-equivalent categories? | **Research and bundle all iMCP-equivalent categories now** |
| Remote-access model | **Carry over Bridgeport's per-connector `exposePublicly` toggle as-is** (became per-*surface* in the single-app architecture) |
| Revive `apple-core` or proceed with Bridgeport clone? | **Both**: revive apple-core for its concepts/research, but note "the Bridgeport mac app itself is much more robust. Apple-core didn't get far at all… It was more of an iMCP clone." → Bridgeport is the technical chassis |
| Pure Swift monolith vs. SYNTHESIS.md's hybrid (TS + Swift sidecars)? | **Pure Swift monolith** |
| v1 depth | **Everything including Mail** |
| Reuse apple-core identity (name, bundle ID, repo)? | **Yes — reuse apple-core** |

## Later refinements (same session)

- Settings screen, popups, confirmations, and alerts: rebuilt around
  **Bridgeport's** design language (not iMCP's).
- Menu bar execution: follow **ping-warden**'s pattern
  (`~/Developer/Projects/ping-warden`).
- Menu bar icon: an SF Symbol "showing one thing connecting to another"
  (settled on `app.connected.to.app.below.fill`).
- Goal bar: feature parity with iMCP, Swift native, with Bridgeport's power
  and control, plus the depth of the bundled-MCP references
  (apple-notes-mcp, apple-mail-mcp). Full release readiness, but no release
  cut without explicit confirmation.
