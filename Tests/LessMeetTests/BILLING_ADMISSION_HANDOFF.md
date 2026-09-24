# Native billing admission handoff — 2026-09-24

Bounded candidate for Lead review; not writer-accepted. All native write ownership
relinquished at handoff. Production RevenueCat deletion remains a separate release
decision as confirmed by Lead after C assessment. No global removal claim.

## Identity and scope

Original HEAD: 1a2685b5d56c04e13a724e611f9fafb16e7effe1.
Actual base: accepted dirty native/A/B/C/automation input, not clean HEAD.
Automation input: Tests/backend/AUTOMATION_HANDOFF.md; accepted manifest
2a80a8baa459e8382d64479d929af16069f9294924e2a054ee77e6c94b924271.
All 10 native entries in Tests/backend/DELETION_SHA256.txt matched before edits.
BILLING_ADMISSION_SHA256.json records complete 37-file pre-edit scope and every
final file with before/after hashes. New evidence files have null before hashes.
The manifest excludes itself; its immutable SHA-256 is in the final handoff message.

Changed implementation/test paths relative to actual dirty base:
- Sources/LessMeet/Account/AccountSession.swift
- Sources/LessMeet/Billing/BillingStore.swift
- Sources/LessMeet/LessMeetApp.swift
- Tests/LessMeetTests/BillingStoreTests.swift
- Tests/LessMeetTests/SubscriptionViewTests.swift

Added evidence: this handoff and BILLING_ADMISSION_SHA256.json. All other scoped
input files are unchanged. No package, README, backend, schema or shared contract
edits. No install, commit, push, deployment, secrets, real provider operations,
recordings, paid requests or account changes.

## Implemented policy

Production store receives the live owner/session identity and uses the existing
authenticated deletion status API. Construction does not configure RevenueCat.
Every prepare (including startup/relaunch and Refresh), purchase and restore
requires a fresh valid matching-owner requested=false result before driver entry,
under the existing process-wide operation gate. Missing configuration, signed-out
identity, locked account, malformed/wrong-owner/deleting status and transport
failure cannot authorize SDK identification. Default injected admission is closed.

Owner AND session must still match after every await, even when the owner is
unchanged. Cancellation and generation fences remain. Deletion locking and
sign-out synchronously call suspend before their remote work; suspend invalidates
queued work and clears billing presentation without waiting on submitted SDK work.
The live identity closure also blocks an expired/replaced/busy Clerk session before
SwiftUI's task has reacted. Startup has no persisted positive admission cache:
a recreated store must obtain fresh status. Synthetic relaunch tests model that
new admission state, not a real SDK/process lifecycle.

Existing driver behavior, supported products and explicit purchase/restore flows
are preserved. Refresh can retry status checks. No anonymous logout or automatic
restore was added. A status outage intentionally makes billing unavailable.
Local recordings/results, capture/playback and subscription cancellation are untouched.

## Mechanism evidence and remaining release blocker

Pinned local checkout verified with git rev-parse:
purchases-ios-spm 5.90.2, 4faa17c4a290954fbdbf8f8a6bf0f58e48a8256c.
Read Sources/Purchasing/Purchases/Purchases.swift and Sources/Identity/IdentityManager.swift
within .build/checkouts/purchases-ios-spm before selecting the mechanism.
Purchases.swift lines 1008–1049 initialize foreground work, transaction delegates
and notifications, with deinit cleanup and internal-only clearSingleton.
Lines 3028–3094 handle foreground cache work. IdentityManager.logOut synchronizes
attributes then creates an anonymous ID; logIn also synchronizes the previous
identity's attributes. There is no usable public shutdown in the inspected API.

Official documentation inspected 2026-09-24:
https://www.revenuecat.com/docs/customers/identifying-customers
Sections Logging Out, Switching accounts, and Advanced Topics say logout generates
an anonymous ID; custom-ID-only integrations avoid logout and switch via login.
That is identity management, not cancellation or quiescence.

REMAINING BLOCKER: suspend only closes app-local admission. It does not detach the
singleton, stop foreground/StoreKit observers, cancel requests already submitted,
prove remote completion, or stop other devices/older builds. An allowed later login
can sync the previous SDK identity. A backend status check is not atomic with the
subsequent SDK request: deletion initiated elsewhere can race it. No honest
durable RC removal guarantee is possible from this patch. Lead must resolve
provider recreation/quiescence policy before enabling production RC deletion;
this bounded candidate does not discharge that prerequisite. No hidden SDK APIs,
dependency patches, account aliases or anonymous customers are used as a workaround.

## Verification and reproduction

Environment: /Users/tubakhuym/projects/lessmeet, Darwin arm64; Apple Swift 6.3.3
(swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0. Existing resolved dependencies.
Commands from repository root:

1. git rev-parse HEAD — matched original base.
2. rg 'Sources/LessMeet|Tests/LessMeetTests' Tests/backend/DELETION_SHA256.txt |
   shasum -a 256 -c — all 10 native accepted entries OK before edits.
3. rg --files Sources/LessMeet Tests/LessMeetTests | sort | xargs shasum -a 256 —
   captured all 37 initial files before editing; final inventory in manifest.
4. swift test --skip-update --disable-automatic-resolution — baseline PASS 66 tests,
   zero failures (08:11:58 local). Deprecation warning for --skip-update; later runs omit it.
5. swift test --disable-automatic-resolution — intermediate PASS 71 tests,
   zero failures (08:13:45 local).
6. swift test --disable-automatic-resolution — final PASS 73 tests, zero failures,
   08:14:16 local; build 1.65 seconds, test suite 0.388 seconds.
7. git diff --check -- Sources/LessMeet Tests/LessMeetTests — no diagnostics.
8. git -C .build/checkouts/purchases-ios-spm rev-parse HEAD — matched pinned revision.

Seven added tests cover default-deny admission; unknown/wrong-owner/malformed/
pending status on recreated stores; same-owner session replacement during delayed
status; deletion/sign-out invalidation during delayed admission; fresh checks for
purchase/restore; completed deletion refusing restore/reidentify; ambiguous deletion
revoking billing before its response. Existing delayed SDK/gate/purchase/restore
races remain passing; shared-identity test now correctly discards the first store's
stale offering when live identity switches. Existing synthetic local audio/results
preservation and save/reopen tests pass. No live SDK configured by new tests.

Failed/unknown proof: no compile/test failure observed. Initial exploratory shell
read used an incorrect flat BillingStore path and unmatched glob (exit 1), corrected
to Billing/BillingStore.swift; an exploratory grep with no matches also exited 1.
No functional failure is hidden. Render test checks unconfigured view raster
dimensions only: no visual inspection of changed signed-in/deletion UI, live Clerk,
SDK lifecycle, network cancellation, real purchases/restores, playback quality,
actual process relaunch or all-device behavior is established. These remain unknown.

Downstream: use the hash manifest to isolate this patch from accepted dirty work;
rerun the full offline command above. Lead decides exact-candidate acceptance.

