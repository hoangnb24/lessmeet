# LessMeet Privacy Policy — unpublished draft

This draft describes the pre-pivot cloud product and retained provider obligations.
It is not a disclosure of the current local-first/ChatGPT app. Reconcile that
product change before any publication; existing data obligations remain.

NOT FOR PUBLICATION until the operator has reviewed and completed this document.
This is a draft for review, not a legal-compliance certification.

Implementation notes reconciled 2026-10-13 against local source and recorded
acceptance. No live settings or external legal terms were revalidated. The
[runbook](DELETION_RUNBOOK.md) owns current deletion scope and evidence.

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
and the accepted working-tree evidence in [STATUS](../STATUS.md),
[backend contract](../BACKEND.md) and [configuration](../CONFIGURATION.md).
Development deployment is not production availability. No live settings were read
for this reconciliation. See the [provider disclosure matrix](PROVIDER_DISCLOSURES.md).
Sep 25 update: this is also the privacy-copy candidate for the public website
and Google OAuth Branding dependency in issue #2. It remains unpublished and
requires the decisions below; production credential setup is not release readiness.
Human confirmed operator Hoang Bang and support/privacy hoang@2m0r.com Sep 25.

Effective date: [REQUIRED]

Operator: Hoang Bang
Privacy contact: hoang@2m0r.com
Website: https://www.lessmeet.2m0r.com
Planned policy URL (not yet verified/published): https://www.lessmeet.2m0r.com/privacy

## Recordings on your Mac

LessMeet records microphone and system audio when you start recording and grant
macOS permissions. System audio can include other applications; no video track is
saved. Obtain the necessary consent before recording others. Local audio, recording
metadata and saved AI results remain on your Mac. The app does not separately
encrypt those local files. Signing out does not erase the local library.

## Optional account and cloud AI

### Signing in with Google

Google sign-in is handled by Clerk. The configured login requests basic identity,
email and profile information (`openid`, `userinfo.email`, `userinfo.profile`) to
identify your account and establish a session. Profile information may include
your name and profile picture. The configured login does not request Calendar or
Drive access. LessMeet's backend uses your Clerk account identifier to associate
your cloud recordings and access allowances with your account.

Signing in is not consent to upload a recording. Google account information used
for login is distinct from recording content you separately choose to send to
Google Gemini. No Google password is requested by the LessMeet app.

Operator review note: scopes are based on the Sep 25 Human handoff; Clerk enabled
and client ID were independently checked, but full consent/callback and exact
returned profile fields have not been exercised. Verify before publication.
Google OAuth project `lessmeet` does not establish the Gemini project, billing
tier or data-use settings.

### Uploading a recording and asking questions

Local recording does not require an AI upload. When you sign in, Clerk processes
account and authentication information. When you explicitly confirm Create
Transcript, audio from the selected recording is uploaded to our Convex backend and sent to
Google Gemini for transcription. Questions you send, the transcript and relevant
conversation context are processed to generate answers, summaries and action
items. These outputs may contain information about you or other participants.

Convex stores uploaded audio, transcripts and chat indefinitely unless deletion is
requested; there is no automatic content-expiry policy. Native account-deletion
initiation, confirmation and status refresh exist in the accepted implementation.
Production provisioning and a selected-case deletion are recorded. This does not
establish an available end-to-end provider deletion service.
The backend attempts exact temporary Google File cleanup when its identifier is
known and durably tracks known IDs and ambiguous operations. Cleanup may fail;
unknown/legacy copies and interrupted generation remain reconciliation exceptions.
Neither file cleanup nor expiry establishes deletion of all provider copies.
Canceling a subscription, signing out or stopping local waiting does not delete
cloud data or necessarily stop work already accepted by the server.

## Subscription information

Apple processes App Store purchases. RevenueCat processes subscription and
transaction status associated with your LessMeet account identifier. Our backend
uses this information to verify access and track usage/allowance reservations.
Restoring a purchase requires the original LessMeet account. Private service API
keys are held on the server, not included in the app.

## Providers and requests

Our implementation uses Clerk for authentication, Convex for backend/storage,
Google Gemini for AI processing, Apple for store transactions, and RevenueCat for
subscription management. Provider-specific retention, processing regions, SDK
diagnostics, AI data-use terms and international-transfer disclosures must be
verified for the actual production accounts before this policy is published.

The backend requests that Gemini not store Interaction objects, independently of
its temporary audio-file cleanup. Neither setting promises zero provider retention.
Google's published Files expiry does not describe all safety logs or other copies;
paid/unpaid data-use terms depend on the actual project. No universal no-training
assurance is made. See the dated provider matrix for sources and unresolved settings.

When you contact support, your message and contact information are used to handle
the request. Do not include meeting content. Support-record retention still
requires operator approval. Website
hosting can process connection/request metadata even without analytics scripts;
Cloudflare account logging and retention must be confirmed before publication.

## Deletion records and testing limitations

For privacy or deletion questions during internal testing, contact hoang@2m0r.com.
Manual handling requires verified account ownership, exact scope and separate
operation authority; email does not replace the native initiation flow. Do not send
passwords, authentication tokens, payment credentials or recordings in a request.
Local audio, metadata and saved results are not erased by account deletion. Apple
renewal must be managed separately; cancellation is not a prerequisite to deletion.

The approved operational retention policies are distinct from content retention:

- Incomplete deletion requests retain the exact-owner guard and reconciliation
  evidence. Local cleanup, all five provider/residual confirmations and reconciled
  execution evidence are required before the 90-day completed-ledger clock starts.
  New requests also require durable Google acknowledgement or evidence-backed
  non-applicability. The ledger is retained for 90 days of continuous completion.
  Reopened completion cancels the clock; unresolved work blocks purge. Daily bounded
  cleanup then removes the request and linked inventory, stage, outbox, contact and
  send records, leaving only an unlinkable completion/purge-time and policy receipt.
- Read-only provider inventory has a 30-day inactivity deadline after its latest
  accepted transition, not after a mere read. Daily bounded cleanup removes provider
  identifiers/configuration/cursors and leaves a minimal request-linked receipt.
  That receipt is not the final unlinkable ledger receipt and is removed with the
  completed request. Neither duration is a deletion-completion deadline.

Retention workers run independently of activation gates. They do not authorize
contact collection, email sends or provider destruction. Resend is the selected
notification processor. Its provider retention and contact/send privacy review
remain open. One manual status email has recipient-reported receipt; automatic
contact capture and automatic delivery remain unverified.

Clerk, Apple and RevenueCat workers are integrated in source. Recorded live evidence
covers one selected Clerk deletion, not full provider fulfillment. The local Google
extension still needs a separately authorized live trial. The approved operating
policy is normal scoped deletion within seven calendar days of receipt, with email
updates/results. Exceptions need a status, reason and next-update time. This is
not a promise of immediate deletion or universal provider erasure. See the
[approved procedure and limits](DELETION_RUNBOOK.md#approved-7-calendar-day-email-operation--implementationreadback-required).

## Publication checklist — remove only after resolution

- Operator/contact are confirmed as Hoang Bang / hoang@2m0r.com. Reconcile Google's
  current hoang@kieng.io.vn support field before public Branding; do not silently
  change account ownership or organization contact information.
- Resolve target-audience/provider eligibility under issue #4. The approved 10+
  target is not a contractual age limit; no 18+ clause is silently substituted.
- Verify Google consent/profile fields and separately approve Gemini processing
  disclosures. Login credentials alone do not establish AI data policy.
- Set the effective date when approved; publish and verify the planned HTTPS URL.
  Confirm any additional operator contact details required before publication.
- Confirm actual production provider contracts/settings and data inventory;
  add applicable rights, retention exceptions and transfer disclosures with review.
- Implement and rehearse the approved manual account/data deletion handling, including provider copies
  and backups; do not imply removing a local file removes a cloud copy.
- Verify the existing native initiation/confirmation/status flow on the eventual
  submitted build, with actual provider fulfillment and completion communication;
  a support-email-only flow is not a substitute for App Store account deletion.
- Reconcile App Store privacy disclosures and third-party SDK privacy manifests
  with observed behavior. Do not invent a no-tracking/no-training assurance.
- Resolve audience/storefront eligibility, rights-request routes and applicable
  processing bases/transfers; do not assume a low Apple age rating permits minors
  to use Gemini. Approve completion-time disclosures, contact/send activation and
  unresolved support/provider residual retention without reopening the approved
  30/90-day operational policies or changing indefinite content retention implicitly.
