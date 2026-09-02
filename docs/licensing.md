# Apple Core — licensing (dual)

*Decision dated 2026-09-02. `EULA.md` governs the next signed binary whose `MARKETING_VERSION`
is tagged after this file appears; prior GitHub Releases through v1.6.1 remain
under `LICENSE.md` (GPL-3.0-or-later).*

## The split

This repository has two distributable artifacts with two licenses.

| Artifact | Where | License | What it contains |
|---|---|---|---|
| The **source** at `github.com/oliverames/apple-core` | This repo | **GPL-3.0-or-later** (`LICENSE.md`, `NOTICE`) | Every file in the tree except the packaged binary itself. DIY builders live here. |
| The **official, signed, notarized .app** Oliver sells | Gumroad | **`EULA.md`** (plus the MIT donor notices in `THIRD_PARTY_LICENSES/` that it bundles) | The `.app` + its Sparkle updates, as conveyed under the EULA. Nothing in `EULA.md` limits any right the buyer holds under the GPL for the source. |

When someone says "Apple Core is GPL'd," the source is. When someone says "I bought Apple Core," the binary's EULA is.

## Why this exists

Gumroad's monetization with teeth — "an unlicensed copy does not allow for setting up any MCP" — requires an unsigned, unactivated copy's MCP session-creating requests (`POST /mcp`, `GET /sse`, `POST /message`, and the OAuth endpoints) to be rejected with `402 Payment Required` until a signed license file is dropped into `~/.config/apple-core/license.txt` via **Settings → License**. A GPL-conveyed binary cannot carry such a term: recipients receive GPL rights, the check would be a further restriction, and anyone could legally strip it and redistribute under the GPL. So the EULA-conveyed binary must contain **no** GPL-licensed third-party code. The source already carries `THIRD_PARTY_LICENSES/` and `NOTICE`; those attribution files ride in the binary too, because the MIT donors' notice-preservation obligations survive any conveyance.

`apple-mail-mcp` (imdinu, GPL-3.0) is the pivot that forced the split:

- The 2026-04-30 plan (`docs/planning/BUILD_PLAN.md` §0 decision 4) deliberately chose GPL-3.0-or-later to *dissolve* the clean-room discipline and lift `apple-mail-mcp`'s disk-first `.emlx` + FTS5 + state-reconciliation code line for line. Direct lifts of GPL-3.0 code are fair game into a GPL-3.0 work, as Synthesis §"License-clean Mail implementation" noted.
- The 2026-09-02 EULA reverses that *only for the binary*. The source is still GPL, so anyone can do the direct lift and carry the GPL. Oliver cannot do it *inside the EULA binary*, because a binary that contains GPL code can only be conveyed under GPL — at which point the activation term is void. To keep the binary sellable, Mail v2.0 must be a clean-room reimplementation, studied from `apple-mail-mcp`'s documented behavior rather than translated function by function (`SYNTHESIS.md` already scoped that work at two to three weeks; see `docs/planning/BUILD_PLAN.md` §4.4).

`CONTRIBUTING.md` extends the inbound grant so Oliver retains the right to convey outside contributions under the EULA.

## The activation mechanism

**Verification is offline Ed25519.** `Shared/LicenseDocument.swift` parses the three-line envelope (canonical JSON payload + Ed25519 signature over it, base64) with `CryptoKit`. `App/Services/Serving/LicenseGate.swift` loads `license.txt` from the config dir, verifies against the public key embedded in the binary, and `AppleCoreHTTPServer.swift` consults the gate before opening any MCP session. `GET /license-status` (unauthenticated) so a support conversation can distinguish "not activated" from "server broken" without tokens. Sparkle updates, the landing page, and the unauthenticated icon routes stay reachable either way.

An unlicensed installation answers every MCP session-creating request with `402 Payment Required` + a plain-text body pointing at **Settings → License**. Once a valid license file is written, the HTTP server picks the change up on the next request (no restart needed).

## Selling through Gumroad

*Gumroad's fees are their own page (`https://gumroad.com/pricing`, checked 2026-09-02): they quote flat 10% plus $0.50 on direct sales and 30% on sales that found the product through Discover. Their help center (checked 2026-09-02) documents merchant-of-record handling. Their license-key tooling was not reachable behind sign-in at the time of this edit, so verify that flow before issuing: the docs below deliberately describe a flow that does not depend on it.*

Gumroad's **license-key feature** is the collection mechanism for every sale, even though Gumroad does not enforce the license at runtime — the app does, offline. The license file Oliver signs is the credential.

### Signer keys (one-time setup)

`Scripts/sign_license.swift` is the companion half of `Shared/LicenseDocument.swift`. It generates and stores the Ed25519 private key in the login Keychain (mirroring that file's docstring and the Sparkle key's placement) and never prints it. The public half is baked into `App/Services/Serving/LicenseGate.swift` (`AppleCoreLicensePublicKey.base64`) before any signed license will verify. Back it up in 1Password — the `op` CLI, not a bare shell pipe — before issuing the first license (same advice as the Sparkle key's).

Only the embedded public key ships. The private key is never in the repository.

### Creating a product

The repo ships the Gumroad CLI as an optional helper (authenticated in this workspace as `oliverames@gmail.com`; re-authenticate locally with `gumroad auth login` or `op run --env-file=~/.claude/.env -- gumroad …`). At publication time, create the product once, with a real fulfillment asset (the DMG/ZIP is the per-purchase deliverable; the license file is the buyer's own activation material).

Checklist (verified by running the CLI against the live account):

- `gumroad products create ...` fails without `--cover` even when `--unpublished` is passed; `--price` is indexed to USD — the flag is `--custom-summary`, not `--custom_summary`.
- The clean sequence that reaches a product page is: `products create` with `--name`, `--custom-summary`, `--price`, and `--cover` pointing at a local image, followed by the returned product's page being used as the live storefront. Use the smallest real screenshot that exists in the repo as the cover while drafting.

### Issuing a license for a sale

Run the signer on the sale receipt:

```bash
./Scripts/sign_license.swift sign \
  --to "buyer@example.com" \
  --name "Buyer Name" \
  --order <gumroad_sale_id> \
  [--expires 2027-09-02]
```

Deliver the resulting `APPLE-CORE-LICENSE-1` file to the buyer via Gumroad's fulfillment text (or as a custom license-key string) so it lives with their purchase and can be re-downloaded. Gumroad handles per-sale fees and tax collection on its side; Oliver does not collect extra.

### What buyers receive

- The signed, notarized `.app` via Gumroad (the deliverable), governed by `EULA.md` (the purchaser also has the right to convey the Source Code under GPL-3.0-or-later, to IR receivers under it).
- A plain-text license file whose name/email/order are human-readable and signed under the buyer's key — it is not a secret beyond its signature.

## Compliance and release posture

The app builds under `Apple Core.xcodeproj` with `Apple Core` on Debug and Release (already the CI gate). The Release Gate in `RELEASING.md` now checks that no GPL third-party code has entered the tree and that the license public key matches. The Sparkle public appcast stays at `App/Info.plist`'s `SUPublicEDKey` and `SUFeedURL`, as before.

`docs/planning/BUILD_PLAN.md` §4 now records the dual-license decision explicitly; that file is the canonical reference for the Mail v2.0 clean-room constraint.
