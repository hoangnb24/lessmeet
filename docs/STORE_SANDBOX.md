# Store connection and sandbox acceptance

Historical pre-pivot runbook. The current local-first app has no RevenueCat
purchase/restore screen. These procedures apply only to the recorded legacy
artifact and do not authorize rebuilding or activating the old product.

Execution status and ownership live in [STATUS.md](STATUS.md). This is the runbook,
not evidence that the dashboard, legal publication or sandbox tests are complete.
Scope: configure and test only. No submission, public release, real purchase,
production enforcement or paid AI test. Human selected existing Convex development
deployment `zany-octopus-315` for sandbox testing; no separate deployment is needed.
Enabling quota enforcement there affects all accounts using that dev backend.
Convex development and `REVENUECAT_ALLOW_SANDBOX=true` do not prevent real Apple
charges. Before any purchase, verify the actual StoreKit sandbox testing context;
a backend rejection after a production purchase cannot undo or prevent the charge.

Signed internal artifact: `dist/sandbox-dev/LessMeet.app`. Open this exact path,
not the existing `dist/LessMeet.app`. The internal Plan & usage screen displays
test disclosures and requires acknowledgement; public legal URLs may be absent
only in sandbox-dev. Store builds still require both HTTPS links. Sign into
Lessmeet normally; `sandbox@kieng.io.vn` is the Apple sandbox tester, not a
required Clerk login. Confirm Apple's sheet is a sandbox test before approving.
The recorded signed sandbox artifact has packaging/signature acceptance and
Human-reported core billing checks. See STATUS for the exact scope and remaining
lifecycle checks; this runbook does not verify a newly built artifact.

## 1. Apple prerequisites (Account Holder)

Priority: owner-only internal sandbox first. Account deletion and full public
legal publication remain pre-release gates, not blockers for synthetic internal
billing tests. Keep failed deletion evidence separate from sandbox acceptance.
`sandbox-dev` permits acknowledged unpublished legal links. Do not substitute dead
URLs or call drafts production policies. Store mode still requires published links.

Target: team `63M98WD275`, macOS app `6815021182`, bundle `com.lessmeet.app`.
Do not change Meetless (`com.meetless.app`).

- Account Holder reviews/signs Paid Apps Agreement and completes tax/bank details
  directly in App Store Connect. Record readiness, never financial details here.
- Create one subscription group, proposed display name **Lessmeet Pro**.
  Both products offer the same service level; monthly/yearly are billing periods,
  not separate benefit tiers. Do not enable trials or Family Sharing by default.
- Configure the following exact identifiers; read back saved duration, group,
  localization and US price. Other storefront prices need separate review.

| Product ID | Duration | Approved US price | RevenueCat package |
| --- | --- | --- | --- |
| `com.lessmeet.app.pro.monthly` | 1 month | USD 9.99 | `$rc_monthly` |
| `com.lessmeet.app.pro.yearly` | 1 year | USD 99.99 | `$rc_annual` |

Do not submit products/app for review or enable public sale as part of this task.
Sandbox uses configured App Store products, not real charges. Agreement and other
prerequisites still apply; local StoreKit fixtures are not store connection proof.

Sources: [Apple IAP setup](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases),
[subscription setup](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/),
[sandbox](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox).

## 2. RevenueCat connection

Target only Lessmeet project `a83a7730`:

1. Connect its Apple app for `com.lessmeet.app`; use the dashboard's current Apple
   credential requirements. Enter private Apple credentials directly there, never
   in chat, tracked files, screenshots or command arguments. Do not reuse unrelated
   app credentials. Record validation result, not credential values.
2. Import both exact Apple products (not similarly named Test Store products).
3. Attach both to entitlement `lessmeet_pro`. Proposed offering identifier:
   `default`, set as current, containing the monthly and annual packages above.
   Read back the actual saved offering; the app uses the current offering.
4. Set and read back **Keep with original App User ID** in project settings.
   Check the sandbox override too: disabled/inherited, or explicitly the same
   policy. A different sandbox policy invalidates the identity test.
5. Require Clerk sign-in before SDK configuration/purchase. Confirm the customer's
   `original_app_user_id` matches the signed-in Clerk subject, with no anonymous
   origin. Do not enable server-notification tracking of new purchases without
   checking its identity interaction with this restore policy.
6. Copy only the Apple public SDK key (`appl_...`) to app configuration. Provision
   the private server API key directly into the selected dev backend's secret store.

The restore policy is project-wide. A second Lessmeet login using the same Apple
purchase must not inherit Pro; provide guidance to recover the original account.
It can also block a new purchase under that second login. Treat this as a required
support/UX scenario, not an excuse to switch to transfer-on-restore.

Sources: [restore policy and sandbox override](https://www.revenuecat.com/docs/projects/restore-behavior),
[entitlements](https://www.revenuecat.com/docs/getting-started/entitlements),
[offerings](https://www.revenuecat.com/docs/offerings/overview).

## 3. Development configuration and legal publication

Use `dev:zany-octopus-315`, HTTP URL `https://zany-octopus-315.convex.site`, as
explicitly selected by Human. Verify that exact target before deployment or env
changes; never target production. Configure credentials and verify restore policy
before enabling enforcement, since missing prerequisites block cloud work for all
dev accounts. Preserve existing data; do not reset usage or delete records for tests.

| Location | Configuration | Gate |
| --- | --- | --- |
| App | `REVENUECAT_PUBLIC_APPLE_KEY` | Apple public `appl_` key only |
| App | `CONVEX_SITE_URL`, `CLERK_PUBLISHABLE_KEY` | Selected dev backend and matching test identity |
| App | `LESSMEET_PRIVACY_URL`, `LESSMEET_TERMS_URL` | Published, working HTTPS pages; drafts do not qualify |
| Dev server | `REVENUECAT_SECRET_API_KEY` | Private; never bundled or logged |
| Dev server | `REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED=true` | Only after dashboard policy readback |
| Dev server | `REVENUECAT_ALLOW_SANDBOX=true` | Never production |
| Dev server | `BILLING_ENFORCEMENT_ENABLED=true` | Enable after prerequisites; applies to all dev users |
| Dev server | `GEMINI_BILLABLE_ENABLED` | Existing owner-funded setting is not authority for agent-paid tests; no AI requests during store-only tests |

Billing lifecycle can be checked without Gemini work. Do not upload audio or call
AI merely because dev's existing kill switch permits it. Use existing mocked-provider
quota tests first and mark live quota settlement NOT RUN until separately authorized.

Privacy and Terms drafts are in `docs/legal/`. Human supplied operator Hoang Bang,
contact `hoang@2m0r.com`, and domain `www.lessmeet.2m0r.com`. Proposed paths are
`https://www.lessmeet.2m0r.com/privacy` and `https://www.lessmeet.2m0r.com/terms`;
neither is verified as published. Human must approve the text before publication.
Deletion workers and limited live evidence now exist. They do not establish full
fulfillment or public readiness. The [deletion runbook](legal/DELETION_RUNBOOK.md)
owns the approved timing, retention conditions and remaining evidence.

## 4. Mac signing gates

Store packaging source is locally accepted after the certificate-extraction syntax
correction; this is not real installer/upload acceptance. Store now additionally
requires explicit version/build, approved ICNS and a public production/legal/icon
approval record. See [Store input and installer contract](../Tests/packaging/STORE_INPUTS.md).
`build-app.sh store` still produces only an app; the separate `store-package.py
package` command signs an isolated installer and requires separately authorized
real signing inputs. Do not run it merely because offline tests pass. Actual
distribution compatibility, install/runtime and Apple upload remain unverified.

`scripts/build-app.sh` supports `dev`, `offline-check`, `auth-check`, `sandbox-dev`,
`store` and `testflight`. Default `dev` uses ad-hoc signing. The three profile-based
modes are `sandbox-dev`, `store` and `testflight`; their outputs are isolated.
The [packaging contract](../Tests/packaging/STORE_INPUTS.md) defines signing inputs.
A successful strict signature check is not Mac App Store acceptance.

For store packaging, select the correct Apple distribution identity/profile for
the exact team and bundle. Add App Sandbox and required client-network/audio
permissions in a separately verified store build, embed the matching profile and
verify signed entitlements, bundle identity and SDK resource bundles. Do not simply
turn sandboxing on in the existing user build: container paths, existing recording
access, Clerk Keychain/OAuth callback and capture permissions all need regression
testing. Preserve existing recordings and do not reset Keychain/TCC to make tests
pass. Certificate/private-key creation and upload are not assumed completed.

For Apple sandbox purchase testing, use an appropriately development-signed build
and Sandbox Apple Account. Store distribution packaging remains a separate gate.
Verify launch, sign-in, mic/system capture, playback, quit/reopen, existing-library
access, legal links and RevenueCat resource loading on the signed sandboxed app.

Sources: [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
[App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

## 5. Required evidence matrix

This matrix defines checks, not current results. Core sandbox checks have
Human-reported acceptance; remaining checks stay unverified in STATUS. For each run record build
hash, macOS version, selected dev deployment, timestamp, pseudonymous test-account
labels, expected/actual result and redacted evidence location in STATUS.md.
Never store tokens, receipts, raw subscriber payloads or real recordings in docs.

| Scenario | Acceptance |
| --- | --- |
| Offerings/legal | Correct two products, localized StoreKit prices and periods; both legal pages open |
| Monthly + annual purchase | Each sandbox purchase yields server-verified Pro for the same Clerk subject |
| Cancel purchase / pending purchase | No guessed Pro, no quota reset, actionable non-success state |
| Restore original account | Relaunch/reinstall then restore returns Pro without duplicate allowance |
| Account A → B | Same Apple account cannot transfer A's purchase; no A plan/cache shown in B |
| B → A | Original purchase remains usable by A; B's failed restore did not revoke A |
| Cancel auto-renewal | Access until verified expiry, then no Pro; saved local work remains |
| Renewal / monthly↔annual | Read real v1 fields and expiry; no duplicate grant or annual upfront allowance |
| Expiry / refund / verification outage | No stale Pro cloud authorization; local capture still available |
| Concurrent quota boundary | Last unit reserved once; excess rejected, success settles once |
| Failure / timeout | Reservation released, no double charge or late settlement |
| Annual allowance boundary | Monthly allowance, no rollover; use deterministic clock fixtures too |
| Signed app lifecycle | Capture/playback/save/reopen, sign-in and SDK/legal resources actually work |

Apple's accelerated renewal clock is not proof of a real calendar-month quota
rollover. Preserve separate fixture and live results. Inspect RevenueCat v1 field
compatibility (original identity, ownership, product, expiry, refund and sandbox
evidence); do not loosen fail-closed parsing merely to make a test pass.

## 6. Public-sale blockers, beyond sandbox

- Hostile audio: structural MP4 checks are not a full decoder. Use synthetic
  malformed containers, forged timing/payloads, nesting/sample amplification and
  truncated frames; measure CPU/memory and decoder-equivalent duration. Reject or
  normalize before paid inference. Keep public activation blocked until resolved.
- Long recordings: retain the [completed synthetic export measurements](../Tests/LessMeetTests/LONG_CAPTURE_HANDOFF.md).
  The internal [batch path](BATCH_CONTRACT.md) handles bounded chunks but does not
  establish public long-session readiness. Real capture quality, drift and live
  provider behavior still need evidence. Do not infer these from synthetic files.
- AI economics: Human first approves a spending cap and synthetic/non-sensitive
  inputs. Record actual model/version, billed usage, request count, storage/transfer
  and failure costs; report per transcribed hour and per question. Compare full
  monthly quota cost against both monthly and annual-equivalent net revenue. Use
  the actual Apple proceeds/fees, not an assumed commission. The earlier 25–30%
  budget is a target, not measured margin. Reopen pricing/limits if it fails.
- Legal publication, privacy disclosures, account/deletion support and signed-app
  runtime behavior remain launch gates. Only Human can authorize public release.
