# Provider disclosure research — unpublished

Reviewed 2026-09-23. Source baseline: `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
Public documentation research only; no provider account/settings inspection.
This is evidence for policy review, not a certification or authorization to publish.
Implementation in progress is not evidence of accepted deletion behavior.

## Data, retention and deletion matrix

| Recipient | Base implementation sends/stores | Public provider documentation | Production verification still needed |
| --- | --- | --- | --- |
| Convex | Clerk issuer-bound owner ID, subject, uploaded combined audio, transcript, questions/answers, processing state, billing status and quota reservations. Cloud content retained indefinitely; no accepted deletion workflow. | [File deletion](https://docs.convex.dev/file-storage/delete-files) is a separate storage operation. [Backups](https://docs.convex.dev/database/backup-restore) may include files; restoring can reintroduce files. Manual/daily backups are described as 7 days, weekly as 14; the same page's FAQ says up to 7 days. These are not a universal erasure deadline. | Exact production region/plan, backup schedule and file inclusion, downloaded exports, logs/support retention, DPA and subprocessors. Resolve documentation discrepancy with provider if material. No confirmed production backup expiry or deletion SLA. |
| Clerk | Account identity, selected social-login profile/contact information and sessions; the app uses Clerk tokens for backend authentication. Not intentionally sent meeting audio. | [deleteUser](https://clerk.com/docs/reference/backend/user/delete-user) deletes the specified user. [DPA](https://clerk.com/legal/dpa) distinguishes customer personal data from account information, permits processing where Clerk/subprocessors operate, and describes deletion following contract termination. That is not a per-user deletion deadline. | Production social-login scopes/profile fields, session/device/security logs, backup retention, applicable contract/transfer mechanism, and Sign in with Apple token-revocation responsibility. User API deletion alone does not prove every residual copy or OAuth grant is erased. |
| RevenueCat | Clerk subject as App User ID, subscription transactions/entitlements and SDK purchase context; backend receives status for authorization. Not intentionally sent meeting content. | [Customer deletion](https://www.revenuecat.com/docs/dashboard-and-metrics/customer-profile#delete-customer) removes customer/purchase history but does not cancel Apple subscriptions. [Privacy policy](https://www.revenuecat.com/privacy) distinguishes developer end-user processing under customer agreements from its own site/account policy. Do not copy its six-year site/account retention language into Lessmeet's end-user promise. | Exact SDK fields, aliases, integrations/exports, production and sandbox restore policy, DPA, residual logs/backups and deletion confirmation. [Apple privacy guidance](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy) informs SDK disclosure but does not complete the whole app questionnaire. |
| Google Gemini | Audio via Files API; transcript, question and prior conversation for replies. Both generation paths request `store: false`; temporary file deletion is attempted only when a safe file ID is known, not durably recorded. | [Files API](https://ai.google.dev/gemini-api/docs/files) describes 48-hour expiry and explicit deletion. [Interactions](https://ai.google.dev/gemini-api/docs/interactions-overview#data-storage-and-retention) supports opting out of stored interactions; this is distinct from Files and other provider logs. [Terms](https://ai.google.dev/gemini-api/terms) distinguish unpaid content use/human review from paid-project handling, which does not use prompts/responses for product improvement but retains limited safety/legal logs. | Active billing association for the exact project, applicable tier/terms/region, logging/data-sharing settings and residual retention. Owner-funded intent is not proof of paid-service status. `store: false` is not a zero-retention or no-training guarantee for every processing layer. Do not submit sensitive/personal data under unverified unpaid terms. |
| Apple | App Store account/payment processing; subscription transaction information flows through StoreKit/RevenueCat. Sign in with Apple is mediated by Clerk. | [App Store privacy](https://www.apple.com/legal/privacy/data/en/app-store/) describes region-dependent financial-record retention, commonly at least 10 years and longer in some regions. Lessmeet cannot erase Apple's independent records. [Account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/) requires in-app initiation, associated-data handling and Sign in with Apple token revocation. | Actual sign-in configuration and revocation integration, storefronts, transaction disclosures and reviewer flow. Deleting Lessmeet/RevenueCat data neither deletes an Apple Account nor cancels Apple renewal. |

Cloudflare remains the selected website host, not a replacement backend. No Sites
migration is proposed. The base static site has no scripts, analytics or forms;
hosting request metadata/logging still needs account-level review before claiming
the website collects nothing. Support email creates a separate support-record
inventory; mailbox provider, access and retention are operator-unverified.

## Decisions required before publication (not new defaults)

1. Human confirms audience and storefront eligibility: Google's current terms
   restrict API clients directed at or likely accessed by under-18s and require
   paid services for EEA/Swiss/UK availability. Apple content age ratings do not
   establish compliance with Google's audience restriction. Do not silently add
   an age gate, change markets or change providers.
2. Human retains the existing indefinite cloud-retention decision unless explicitly
   changed. Separately decide necessary deletion-ledger/tombstone/support retention,
   purpose, minimum fields, duration and access; no new indefinite exception is
   approved here. Any new paid plan, retention change or external operation returns
   to Lead/Human before action.
3. Operator verifies settings in the matrix and approves applicable rights,
   processing purposes/legal bases, transfer disclosures, contact details and
   audience text with jurisdiction-appropriate review. No GDPR/CCPA compliance,
   data-locality, no-tracking or universal no-training claim is established.
4. Lead accepts a stable deletion candidate and its operational rehearsal before
   replacing base limitations in [Privacy](PRIVACY_DRAFT.md),
   [Terms](TERMS_DRAFT.md) and [runbook](DELETION_RUNBOOK.md). Human approves a
   supportable completion-time disclosure; this research supplies no SLA.

## Reproducible source boundary

Read the following with `git show 1a2685b5d56c04e13a724e611f9fafb16e7effe1:<path>`,
not from another lane's moving tree: `convex/schema.ts`, `convex/gemini.ts`,
`docs/BACKEND.md`, `docs/STORE_SANDBOX.md`, the three existing legal drafts/runbook,
`website/README.md`, `website/wrangler.jsonc`, `website/public/index.html`,
`website/public/404.html` and `website/public/_headers`.
Schema/Gemini source independently corroborate the content inventory, lack of a
deletion ledger in the base schema, `store: false` and best-effort file cleanup.
Other product statements inherit base documentation, not fresh runtime testing.
Historical rehearsal results in the runbook were not rerun in this documentation
lane. All public links above were read on the review date; they establish public
capabilities/terms, not the settings or behavior of Lessmeet's accounts.
