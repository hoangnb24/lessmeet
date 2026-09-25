# Lessmeet legal hosting

Unpublished preparation, reconciled 2026-09-24 against
`b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` and accepted working-tree evidence.
This document holds Store drafts as
well as the hosting runbook; it is not a second delivery-status tracker.
Execution/acceptance remains in [STATUS](../docs/STATUS.md).

The current finish line is owner internal TestFlight testing with a requested
120-minute transcription capability, not public launch or App Review. That
capability is not established: accepted synthetic evidence covers local capture/
export, and the 120-minute export exceeds the current 18 MiB upload cap. Do not
add a long-transcription claim to listing copy until implemented and verified.
Public legal hosting and the Store-publication checklists below are separate from
internal-beta acceptance. Existing packaging gates are project policy and remain
unchanged here; Lead owns any scoped internal-beta packaging decision. This draft
does not claim that Apple requires published legal pages for every internal beta.

Cloudflare Workers static assets, separate from the existing `meetless-website`.
The historical zone API check confirmed `2m0r.com` belongs to account
`6031f1f85e189c44fb3bcd150ca65920`. No backend, payment links, cookies,
analytics scripts, uploaded recordings or credentials belong in this directory.
Only `public/` is uploaded. Draft legal documents remain outside the asset root.

## Current state

Prepared, NOT deployed. `/privacy` and `/terms` are intended to return 404 rather
than serve a support page as a valid legal document; live routing was not checked.
Do not put these URLs in
the app until real reviewed policies are published and verified over HTTPS.

## Verification

From the repository root:

```sh
node website/verify-drafts.mjs
git diff --check -- docs/legal website
```

The offline check verifies the exact asset root/inventory, no symlinks, absence of
draft routes, local Markdown/HTML link targets, and draft metadata lengths. It
does not establish HTTP responses, Wrangler runtime behavior, DNS or certificates.
No deployment/dry-run, dashboard call or dependency installation is needed.
If separately authorized later, use pinned Wrangler `4.136.3` for local routing
checks and a deployment dry-run. No such check is claimed by this preparation.

Historical documentation-lane verification on 2026-09-23, macOS 26.4 (25E246), Node v22.22.3:
`node website/verify-drafts.mjs` passed: four allowed public assets, three HTML
links and nine local Markdown links. Candidate name/subtitle/promotion/keywords
lengths were 8/27/150/63, within checked limits 30/30/170/100.
`git diff --check -- docs/legal website` passed. This is static/offline evidence,
not a site deployment or application/provider test. Historical deletion-readiness
failures remain in the legal runbook; this lane did not rerun or supersede them.

Sep 24 reconciliation evidence, macOS 26.4 (25E246), Node v22.22.3:
`node website/verify-drafts.mjs` passed with four allowed assets, three HTML links,
20 local Markdown links and unchanged metadata lengths 8/27/150/63.
`git diff --check -- docs/legal website/README.md` passed. For untracked scope,
`git ls-files --others --exclude-standard -- docs/legal website/README.md` returned
no paths; no new scoped files were introduced. Full-file whitespace checks also
cover the five scoped Markdown files, not just tracked diff lines. This is document
and asset-inventory evidence only, not a runtime, provider, HTTP or beta acceptance.
No public asset, route, effective date, audience, market or completion SLA changed.

## Before deployment

1. Resolve the publication checklists in `docs/legal/PRIVACY_DRAFT.md` and
   `docs/legal/TERMS_DRAFT.md`; get operator approval and effective date.
   Never turn draft text into a promise of deletion, retention, or provider
   behavior without an implemented process and verified account settings.
2. Add reviewed static `privacy.html` and `terms.html`; update the support page.
3. Verify the exact hostname's DNS records in Cloudflare. The prior Wrangler
   OAuth check could read zone metadata and Workers custom domains, but its
   DNS-record GET returned 403; this is historical, not a current permission audit.
   Do not overwrite any existing record/site to fix a conflict.
4. Only after separate publication authority, deploy explicitly with
   `npx --yes wrangler@4.136.3 deploy --config website/wrangler.jsonc`.
   This creates/updates only `lessmeet-legal` and its exact custom hostname.
   Do not enable a paid plan or change other domains. `workers.dev` and preview
   URLs are disabled. Cloudflare handles custom-domain DNS/certificate setup:
   https://developers.cloudflare.com/workers/configuration/routing/custom-domains/
5. Verify certificate validity, HTTPS 200 on `/privacy` and `/terms`, correct
   approved content, security headers, and 404 on unknown paths before installing
   legal URLs into app public configuration. `www.lessmeet.2m0r.com` is the only
   requested hostname; no apex or additional alias is configured implicitly.

The configured `404-page` handling and absence of privacy/terms assets support the
intended unpublished state, not a live-response claim. Cloudflare remains the
chosen host; do not migrate to Sites or another site. See [Cloudflare HTML
handling](https://developers.cloudflare.com/workers/static-assets/routing/advanced/html-handling/)
and [provider disclosures](../docs/legal/PROVIDER_DISCLOSURES.md).

## Store listing draft — not submitted

These are candidate English strings, not approved marketing or runtime evidence.
Do not copy editorial notes, unresolved placeholders or internal-only sandbox
claims into App Store Connect. No screenshots have been generated or captured.

| Field | Candidate / decision |
| --- | --- |
| Name | Lessmeet |
| Subtitle | Record, transcribe, revisit |
| Promotional text | Record microphone and system audio on your Mac. Choose when to upload for AI transcripts, summaries and questions. Keep your local recordings at hand. |
| Keywords | meeting,recorder,transcription,notes,audio,summary,productivity |
| Primary category | Productivity — proposed, Human approval needed |
| Platform | macOS 15+; bundle `com.lessmeet.app`; team `63M98WD275` |
| Support URL | `https://www.lessmeet.2m0r.com/` — proposed, HTTPS/public support verification pending |
| Privacy URL | `https://www.lessmeet.2m0r.com/privacy` — intentionally unpublished |
| Terms link | `https://www.lessmeet.2m0r.com/terms` — intentionally unpublished |
| License | Apple Standard EULA, approved choice; verify saved App Store Connect selection |
| Copyright / seller | Hoang Bang; confirm exact copyright year and required seller/trader details |
| Marketing URL | Omit until an approved public page is useful; do not invent a second hostname |

Description candidate:

> Keep a local record of your conversations on your Mac. Lessmeet records microphone
> and system audio, keeps a recording library, and lets you replay saved audio.
>
> Choose when to use cloud AI. Sign in and confirm an upload to create a transcript,
> then ask questions, request a summary or extract action items from that transcript.
> AI results can be inaccurate; review them before relying on them. Obtain permission
> from participants before recording or uploading their information.
>
> Local recording and playback are not metered by an AI subscription. Free includes
> a one-time allowance of 120 transcription minutes and 20 AI questions. Pro includes
> 1,200 transcription minutes and 200 AI questions per monthly allowance period,
> including for annual subscribers. Unused allowances do not roll over. Summaries
> and action-item requests each use one AI question when successful. Upload size
> and conversation limits apply; this is not an unlimited transcription service.
>
> Pro is available as an auto-renewing monthly or annual subscription. The App Store
> purchase sheet shows the localized price and billing period. Manage renewal with
> Apple. Use your original Lessmeet account to restore purchases; purchases do not
> transfer to another Lessmeet login. Canceling a subscription does not delete data.
>
> Cloud audio, transcripts and chats are retained indefinitely unless deletion is
> requested. Review our Privacy Policy before uploading. Local files remain separate.
> Support: hoang@2m0r.com.

Before submission, append the verified public Privacy/Terms links and
[Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).
Reconcile retention/deletion language with the accepted release; do not silently
rewrite indefinite retention as automatic expiry. Approved US targets remain
$9.99/month and $99.99/year; localized StoreKit pricing is authoritative in the app.
Product IDs remain `com.lessmeet.app.pro.monthly` and
`com.lessmeet.app.pro.yearly`; no trial, rollover or family-sharing promise is added.

Internal evidence, not listing copy: core sandbox purchase/restore/reopen and
account-isolation behavior was accepted as recorded in STATUS; this is not public
sale approval. Native account-deletion initiation/confirmation/status refresh exists,
and guarded cleanup plus 30-day inventory/90-day completed-ledger retention are
dev-deployed with activation gates off. These operational policies do not expire
cloud content or promise provider erasure. The accepted Clerk transport remains
disconnected, identity/billing destructive stages are not integrated, and notification
delivery is unknown. See the [Privacy draft](../docs/legal/PRIVACY_DRAFT.md) for the
retention conditions and still-unresolved contact/send and residual-copy disclosures.

## Metadata and privacy questionnaire checklist

- Confirm app/version/build identity, primary language, category, support contact,
  seller/trader obligations, storefront availability, copyright, export-compliance
  answers, content rights and accessibility claims with actual evidence. Do not
  infer encryption-exemption or accessibility answers from this document.
- Verify both subscription localizations, durations, price sheets and review
  screenshots against approved products, original-account restore policy and
  monthly allowances. Do not substitute sandbox acceptance for public sale approval.
- Review the full production app and every SDK/service. Apple's questionnaire
  includes third-party collection, not just data in Lessmeet's database. A privacy
  manifest is an input, not a substitute for these answers.

Provisional mapping for review, NOT completed App Store Connect answers:

| Apple data type to assess | Evidence/purpose | Linkage and unresolved details |
| --- | --- | --- |
| User Content → Audio Data | Explicit cloud transcription upload; app functionality | Linked to authenticated owner; local-only audio is distinct from collected cloud audio |
| User Content → Other User Content | Transcripts, questions, replies; app functionality | Linked to owner; review participant-sensitive content and any additional applicable categories |
| Identifiers → User ID | Clerk subject, issuer-bound owner, RevenueCat App User ID; authentication/purchase access and guarded deletion evidence; gated provider inventory | Linked; apply approved operational retention separately from content; review SDK/device identifiers rather than assuming none |
| Contact Info → Email Address / Name | Clerk social-account fields/support; gated verified-primary contact and frozen completion email | Contact/send activation off; review Resend processing, retention and missing/relay-only handling before activation; do not infer delivery |
| Purchases → Purchase History | StoreKit/RevenueCat and backend entitlement verification | Linked to account; Apple payment processing does not automatically mean Lessmeet collects card data |
| Usage Data / Diagnostics / other identifiers | Quota counters plus possible SDK/service operational metadata | Inspect actual production SDK options and provider inventory; categories/purposes/linkage not finalized |

Do not select “Data Not Collected”: authenticated cloud content is retained in the
accepted implementation. No advertising/tracking integration is established by the recorded evidence,
but “not used for tracking” still needs SDK/settings review under Apple's definition.
Do not assume all optional cloud collection qualifies for an optional-disclosure
exception. Sources read 2026-09-23: [Apple privacy definitions](https://developer.apple.com/app-store/app-privacy-details/),
[RevenueCat SDK guidance](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy),
[metadata fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).

## Age rating and audience — unresolved decision

Complete Apple's current questionnaire using the actual released feature set,
including messaging/chat, user-generated content, unrestricted web access and AI
output/content risks where applicable. Transcript-bound AI chat is not evidence
of person-to-person messaging or public sharing; do not answer by feature name
alone. No final rating is assigned here and no parental controls are claimed.
Review regional ratings and any age override in the current form.

Human must first resolve audience/market eligibility under the [Gemini terms](https://ai.google.dev/gemini-api/terms)
identified in the provider matrix. A content rating alone does not establish an
effective age restriction. Do not market to students/minors or promise worldwide
availability before that decision. [Apple rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)
were read 2026-09-23; recheck before submission.

## Screenshot checklist — no assets supplied

Capture the accepted, signed release candidate on macOS with consented synthetic
content. Preserve a private evidence record of build hash, OS, dimensions and
capture date; never show real meetings, account emails, purchase receipts or keys.
Suggested truthful sequence: recording/library; playback and transcript; a grounded
question/summary; Plan & usage with actual localized offering. Show only working
UI, not unverified provider-completion screens or invented AI results. A prerecorded synthetic
fixture must not be passed off as live AI quality evidence.

Apple currently specifies Mac 16:10 images at 1280×800, 1440×900, 2560×1600 or
2880×1800. Check current upload count/format/localization requirements before
capture. Do not stretch an existing window image or use generated mockups as
screenshots. Final branding/icon and screenshot selection require Human approval.
Source: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
(read 2026-09-23).

## App Review notes and reviewer access — draft checklist

Candidate note, to complete only after the release is accepted:

> Lessmeet is a native Mac microphone/system-audio recorder with optional cloud AI.
> Local recording does not require a cloud upload. Grant the requested macOS capture
> permissions, make a synthetic recording, stop it, and replay it from the library.
> To test transcription, sign in and explicitly confirm Create Transcript; questions,
> summaries and action items use the resulting transcript. AI requires network access.
> Pro uses Apple auto-renewing subscriptions; annual billing still has monthly usage
> allowances. Restore Purchases uses the original Lessmeet account.

- Supply a working review account or an Apple-accepted fully featured demonstration
  route; verify the actual Clerk Google/Apple sign-in and callback on the submitted
  build. No reviewer credentials exist in this document. Share credentials only
  through App Store Connect's private review fields, not Git or screenshots.
- Human must approve account provisioning and any reviewer AI budget. Do not use
  the owner's personal login, demand a real purchase, assume a sandbox tester is a
  Clerk login, bypass authentication or fabricate an entitlement for convenience.
- Fill exact sign-in steps, expected Free/Pro access, account recovery/2FA handling,
  reachable backend, review contact Hoang Bang / hoang@2m0r.com, and any required
  phone number privately. Verify reviewer can access all reviewable features.
- For eventual App Review, document Account settings → Delete Account, confirmation
  and Refresh deletion status on the actual submitted build. Intake is currently
  disabled in dev; accepted UI/source does not establish provider completion.
  Supply approved timing/notification and verify associated data/provider handling
  and Sign in with Apple token revocation. Do not tell
  reviewers that email-only deletion satisfies the requirement.
- Confirm that Privacy/Terms open successfully from the submitted app, cancellation
  guidance works, and review notes match that build rather than internal sandbox
  warnings. Include technical size limits and known restrictions honestly.
- Attach only genuine subscription review screenshots/necessary demonstration
  evidence; do not claim recording quality, AI accuracy or save/reopen behavior
  from fixture tests. Human authorizes any upload, submission and publication.

Sources read 2026-09-23: [App Review guidelines](https://developer.apple.com/app-store/review/guidelines/)
and [account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/).
The [sandbox runbook](../docs/STORE_SANDBOX.md) remains the operational reference;
this draft neither alters it nor accepts another lane's moving implementation.

## Publication handoff boundary

Usable now: listing strings, disclosure inventory, operational/reviewer checklists
and policy drafts for review. Still required: Human audience/markets/legal approval;
provider settings and residual-retention/contact-send decisions; integrated provider
fulfillment and an authorized rehearsal beyond accepted intake/cleanup; approved
timing/notification text; signed-build screenshots/runtime
evidence; reviewer account/budget; effective dates and verified HTTPS publication.
No dashboard, deployment, provider deletion, recording upload, purchase, signing,
artifact promotion or submission was performed by this documentation preparation.
These publication requirements do not redefine the owner-internal-TestFlight
milestone or claim its separate runtime/packaging acceptance is complete.
