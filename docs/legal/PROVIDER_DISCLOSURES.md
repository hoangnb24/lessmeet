# Provider disclosure research — unpublished

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
plus accepted working-tree evidence in [STATUS](../STATUS.md),
[BACKEND](../BACKEND.md) and [CONFIGURATION](../CONFIGURATION.md).
This is evidence for policy review, not legal approval or authorization to publish.
No account/settings inspection occurred in the Sep 24 reconciliation. Sep 25
Google/Clerk evidence is now recorded in CONFIGURATION: Google credentials enabled,
domain/SSL complete, Google Testing/Branding incomplete and Apple credentials pending.
Scopes/Google dashboard behavior are Human-reported; full login remains unverified.
Human subsequently authorized landing-only publication Sep 25; this does not
authorize publishing policy drafts or establish Google production readiness.

Sep 25 source refresh: [Google OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)
require an accurate app homepage and links to privacy/terms on an owned verified
domain for production. Basic login scopes do not establish a Gemini data-processing
policy. [Gemini terms](https://ai.google.dev/gemini-api/terms) still prohibit API
clients directed toward or likely accessed by under-18s, restrict purposes/regions,
and distinguish paid-project data handling from unpaid use. The approved 10+ target
therefore remains an unresolved eligibility decision for Human under #4, not a
reason to invent an age clause or silently change provider. Exact paid-project and
optional-sharing evidence is still needed; no universal no-training claim follows.

## Data, retention and deletion matrix

| Recipient | Accepted implementation sends/stores | Public provider documentation | Production verification still needed |
| --- | --- | --- | --- |
| Convex | Issuer-bound owner, subject, uploaded audio, transcript, questions/answers, processing and billing/quota state. Content indefinite unless deletion requested. Accepted guarded cleanup and operational ledgers are dev-deployed, intake/automation off. Separate approved 30/90-day policies below. | [File deletion](https://docs.convex.dev/file-storage/delete-files) is separate from row deletion. The historical Sep 23 [backup research](https://docs.convex.dev/database/backup-restore) found differing duration descriptions; no universal erasure deadline was established. | Exact production region/plan, backup/file schedule, exports, logs/support retention, DPA and subprocessors. Recheck backup documentation/settings and suppression on restore; no production backup expiry or deletion SLA is verified. |
| Clerk | Account identity, selected social-login profile/contact information and sessions; the app uses Clerk tokens for backend authentication. Not intentionally sent meeting audio. | [deleteUser](https://clerk.com/docs/reference/backend/user/delete-user) deletes the specified user. [DPA](https://clerk.com/legal/dpa) distinguishes customer personal data from account information, permits processing where Clerk/subprocessors operate, and describes deletion following contract termination. That is not a per-user deletion deadline. | Production social-login scopes/profile fields, session/device/security logs, backup retention, applicable contract/transfer mechanism, and Sign in with Apple token-revocation responsibility. User API deletion alone does not prove every residual copy or OAuth grant is erased. |
| RevenueCat | Clerk subject as App User ID, subscription transactions/entitlements and SDK purchase context; backend receives status for authorization. Not intentionally sent meeting content. | [Customer deletion](https://www.revenuecat.com/docs/dashboard-and-metrics/customer-profile#delete-customer) removes customer/purchase history but does not cancel Apple subscriptions. [Privacy policy](https://www.revenuecat.com/privacy) distinguishes developer end-user processing under customer agreements from its own site/account policy. Do not copy its six-year site/account retention language into LessMeet's end-user promise. | Exact SDK fields, aliases, integrations/exports, production and sandbox restore policy, DPA, residual logs/backups and deletion confirmation. [Apple privacy guidance](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy) informs SDK disclosure but does not complete the whole app questionnaire. |
| Google Gemini | Audio via Files; transcript/question/history for replies; generation requests `store: false`. Safe known file IDs and ambiguous operations are durably recorded. Eligible exact-known files have bounded cleanup; unknown uploads, legacy copies and interrupted generation remain exceptions. | [Files API](https://ai.google.dev/gemini-api/docs/files) documents expiry/deletion, distinct from [Interaction storage](https://ai.google.dev/gemini-api/docs/interactions-overview#data-storage-and-retention) and provider logs. [Terms](https://ai.google.dev/gemini-api/terms) distinguish paid/unpaid handling; project billing and optional sharing matter. | Exact project billing/tier/region and logging/sharing settings, residual retention and reconciliation. Recorded owner-funded dev approval is not a fresh settings audit. File absence and `store: false` do not prove universal erasure or no training at every layer; no sensitive/personal test data under unverified unpaid terms. |
| Apple | App Store account/payment processing; subscription transaction information flows through StoreKit/RevenueCat. Sign in with Apple is mediated by Clerk. | [App Store privacy](https://www.apple.com/legal/privacy/data/en/app-store/) describes region-dependent financial-record retention, commonly at least 10 years and longer in some regions. LessMeet cannot erase Apple's independent records. [Account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/) requires in-app initiation, associated-data handling and Sign in with Apple token revocation. | Actual sign-in configuration and revocation integration, storefronts, transaction disclosures and reviewer flow. Deleting LessMeet/RevenueCat data neither deletes an Apple Account nor cancels Apple renewal. |

### Accepted execution limits and notification processor

Clerk's accepted transport-only module pins the recorded `2026-05-12` wire version
and distinguishes DELETE acknowledgement, point-in-time absence and session
revocation. It has no worker caller or completion writes; the worker still returns
`adapter_unimplemented`. Apple original-client/revocation provenance and RevenueCat
destructive permission, aliases and all-device recreation risk remain unresolved.
The recorded RC v2 preflight credential is read-only; it does not authorize deletion.
The development Clerk instance uses shared social credentials; enabling the native
Apple capability did not resolve hosted OAuth provenance or migrate identities.

Resend is the selected, separately gated completion-notification processor. The
implementation would send a verified primary non-relay email address and frozen,
scope-qualified completion text from `notifications@lessmeet.2m0r.com`, retaining
submission identifiers/state. It sends no recording content. The recorded domain
is verified; the sending credential is not provisioned to Convex and no send is
established. Contact/send activation privacy and provider retention/processing
terms still need review; the 90-day linked-row purge is not Resend-side deletion.
There is no delivery webhook/readback; API acceptance remains delivery-unknown.
Missing/relay-only contact needs a separately approved route, never a guessed
recipient or a reason to delay Apple revocation. [Resend events](https://resend.com/docs/webhooks/event-types)
distinguish send success from recipient-server delivery (rechecked 2026-09-24).

### Approved application retention, not provider deadlines

Content remains indefinite unless deletion is requested. Preflight identifiers,
configuration and cursors compact after 30 days since the latest accepted state
transition; mere reads do not extend the deadline. A minimal request-linked receipt
prevents snapshot recreation. It contains no provider identifiers but is not the
final unlinkable receipt. Incomplete main requests retain exact-owner guards and
operational evidence. After local cleanup and all five provider/residual confirmations,
90 continuous days start; reopening cancels the clock and unresolved work blocks
purge. Daily bounded purge removes request-linked preflight/receipts, stage, outbox,
contact and send rows, leaving only unlinkable completion/purge times and policy
revision. Both policies are dev-deployed and gate-independent. Neither activates
intake, inventory, contact capture, sends or provider destruction; neither is a
fulfillment SLA. Synthetic provider flags in the dev rehearsal prove no live erasure.

Cloudflare remains the selected website host, not a replacement backend. No Sites
migration is proposed. The prepared static site has no scripts, analytics or forms;
hosting request metadata/logging still needs account-level review before claiming
the website collects nothing. Support email creates a separate support-record
inventory; mailbox provider, access and retention are operator-unverified.

## Decisions required before publication (not new defaults)

1. Human confirms audience and storefront eligibility: Google's current terms
   restrict API clients directed at or likely accessed by under-18s and require
   paid services for EEA/Swiss/UK availability. Apple content age ratings do not
   establish compliance with Google's audience restriction. Do not silently add
   an age gate, change markets or change providers. The terms also limit service
   use to developers building for professional/business purposes, not consumer
   use; review intended use before broad marketing. Internal testing is not a
   blanket exemption from provider terms. No audience or market is selected here.
2. Preserve indefinite content retention and the approved 30-day inventory/90-day
   completed-ledger policies. Resolve support/provider residual retention and
   contact/send activation privacy separately; do not reopen resolved policy or
   invent a new indefinite exception. New paid plans, retention changes and external
   operations return to Lead/Human before action.
3. Operator verifies settings in the matrix and approves applicable rights,
   processing purposes/legal bases, transfer disclosures, contact details and
   audience text with jurisdiction-appropriate review. No GDPR/CCPA compliance,
   data-locality, no-tracking or universal no-training claim is established.
4. Native intake/guarded cleanup and the disconnected Clerk transport are accepted
   within their recorded limits, not end-to-end provider fulfillment. Before public
   claims, verify the integrated candidate and separately authorized provider
   rehearsal. Human approves supportable timing and completion communication;
   [Privacy](PRIVACY_DRAFT.md), [Terms](TERMS_DRAFT.md) and the
   [runbook](DELETION_RUNBOOK.md) supply no SLA or legal-compliance certification.

## Reproducible source boundary

Historical Sep 23 research read the following using
`git show 1a2685b5d56c04e13a724e611f9fafb16e7effe1:<path>`,
not from another lane's moving tree: `convex/schema.ts`, `convex/gemini.ts`,
`docs/BACKEND.md`, `docs/STORE_SANDBOX.md`, the three existing legal drafts/runbook,
`website/README.md`, `website/wrangler.jsonc`, `website/public/index.html`,
`website/public/404.html` and `website/public/_headers`.
That historical schema lacked a deletion ledger; it is not the current schema.
This Sep 24 reconciliation uses the accepted BACKEND/CONFIGURATION/STATUS contracts,
including media source `83c1c9ddd8df` and disconnected Clerk transport `39d3c407880a`
identified by STATUS. It adds no runtime or live-provider verification. Historical
failed rehearsal evidence is preserved in the runbook, not rerun here. Apple account
deletion, Gemini terms and Resend event documentation were rechecked Sep 24; other
provider links remain dated Sep 23 research inputs, to be revalidated before public
reliance. Public documentation does not establish LessMeet's production settings.
