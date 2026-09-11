# Mac App Store feasibility

Reviewed September 8, 2026 against the current source and Apple's published documentation.

## Recommendation

Keep direct distribution while proving a separate sandboxed App Store build.
Hosted access is compatible with that direction: an outbound network connection
avoids installing a separate tunnel helper. Full feature parity is unproven,
especially Messages, database-backed Notes features, and arbitrary Shortcuts.
Do not promise an App Store migration until a sandbox prototype and App Review
establish which surfaces can ship.

## Concrete changes

| Current source | App Store work |
| --- | --- |
| `App/App.entitlements` has Apple Events permission but no App Sandbox | Create a separate sandboxed target/configuration and audit every service entitlement. |
| `CloudflaredInstaller.swift` downloads executable code | Use the in-process hosted relay in the Store build; investigate a bundled, sandbox-compatible helper only if retaining own-Cloudflare setup there. |
| `App.swift` installs a keep-alive LaunchAgent | Replace direct plist installation with an appropriate ServiceManagement flow and explicit user consent; quitting must stop background work unless separately consented to. |
| `App.swift` uses Sparkle | Exclude Sparkle and its updater UI from the Store build. |
| `LicenseGate.swift` and `LicensePane.swift` require Gumroad keys or signed licenses | Replace Store-build activation with App Store purchase/StoreKit entitlements; retain direct-build licensing separately. |
| `ServingConfig.swift` stores state under `~/.config/apple-core` | Move Store-build state to its container; design explicit import from the direct build. |

Apple requires Mac App Store apps to be sandboxed, self-contained, and updated
through the Store. It prohibits license keys, custom copy protection, downloaded
executable functionality, and unconsented background startup. These requirements
make the current shipping binary unsuitable for submission unchanged.
[App Review Guidelines, 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

## Feature viability

**Update, September 11, 2026.** Oliver authorized private API use in Apple Core.
Issue #40 adopts the private ReminderKit framework for native reminder
hierarchy, sections, tags, and attachments. If that lands, Reminders leaves the
public-framework set below and cannot ship in a Store build at all, since App
Review rejects private framework use. The rest of this document is unaffected:
notarized direct distribution does not inspect for private frameworks.

- **Calendar, Contacts, Maps, Location:** Start the prototype here.
  These implementations use public frameworks. Verify sandbox entitlements,
  privacy prompts, remote invocation, and account access on a clean Mac.
- **Filesystem:** The existing allowlist is useful policy, but plain paths do
  not grant sandbox access. Persist security-scoped bookmarks obtained through
  the user's folder picker, resolve them on launch, handle stale bookmarks,
  and balance scoped-access calls around operations. Test nested folders,
  moved folders, Spotlight, attachment writes, and relaunch.
  [Apple's sandbox file-access guide](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- **Mail and AppleScript-backed Notes:** Automation consent alone does not
  grant sandbox scripting access. Inspect target scripting access groups and
  use `scripting-targets` where supported; otherwise document specific
  temporary Apple Events exceptions. Prototype before committing to parity.
  [Sandboxing and Automation](https://developer.apple.com/library/archive/qa/qa1888/_index.html)
  [Temporary exception review information](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information)
- **Messages and database-backed Notes:** Current code reads `chat.db` and
  `NoteStore.sqlite` directly. Treat these as unresolved review and sandbox
  risks. A Full Disk Access prompt does not establish Store eligibility.
  Consider omitting these tools from the Store variant if no approved route
  is available; do not use an external helper to bypass the sandbox.
- **Shortcuts, Utilities, Capture:** Test each operation separately. A
  user-created shortcut can perform much more than its name suggests, and
  subprocess inheritance and screen/camera/microphone permissions need real
  sandbox testing. Do not mark an entire surface supported based on compilation.

## Subscription and download design

Use a StoreKit auto-renewable subscription for hosted access, with the download
delivered by the Mac App Store. Associate verified purchases with the hosted
account using an `appAccountToken`; do not use a client-supplied boolean as
proof of subscription. Keep the hosted account identifier independent of
Gumroad so both distribution channels can be supported during migration.
[Apple account-token documentation](https://developer.apple.com/documentation/appstoreservernotifications/appaccounttoken)

The hosting backend would verify signed transaction data and track renewals,
refunds, expiration, revocation, billing retry, and grace periods. Add App Store
Server Notifications V2, reconciliation through the App Store Server API,
restore purchases, subscription management, and sandbox purchase tests.
Notifications should be idempotent and tolerate delayed or reordered delivery.
[App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)
[Subscription billing](https://developer.apple.com/documentation/storekit/handling-subscriptions-billing)

Existing Gumroad buyers need an explicit migration policy. Their purchase is
not automatically an App Store transaction. Decide whether to retain a direct
download, grant a transition period, or offer separate hosted entitlement.
Do not cancel or replace existing customer purchases as part of this beta.

## Submission preparation

Create the App Store Connect record and signing configuration, supply review
instructions and a working hosted demo account, test with TestFlight, and
prepare screenshots, support/privacy URLs, data-handling disclosures, and
account deletion if hosted accounts are created. Explain that the Mac must
remain awake and connected and that authorized requests transit hosting.

Also audit redistribution rights for every donor and dependency before the
Store build. The repository describes GPL source plus separately licensed
signed binaries; that description alone does not establish permission to
relicense third-party contributions. This investigation has not completed a
dependency-by-dependency licensing review or obtained Apple's approval.

The first go/no-go milestone is a sandboxed prototype demonstrating all
intended read-only surfaces on a clean Mac. StoreKit work should follow that
result, not precede it.
