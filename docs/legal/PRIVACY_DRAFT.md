# Lessmeet Privacy Policy — unpublished draft

NOT FOR PUBLICATION until the operator has reviewed and completed this document.
This describes the current implementation, not a legal-compliance certification.

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
and the accepted working-tree evidence in [STATUS](../STATUS.md),
[backend contract](../BACKEND.md) and [configuration](../CONFIGURATION.md).
Development deployment is not production availability. No live settings were read
for this reconciliation. See the [provider disclosure matrix](PROVIDER_DISCLOSURES.md).
The current milestone is owner internal TestFlight testing, not public launch;
this unpublished policy is not a universal beta-publication prerequisite.

Effective date: [REQUIRED]

Operator: Hoang Bang
Privacy contact: hoang@2m0r.com
Website: https://www.lessmeet.2m0r.com
Planned policy URL (not yet verified/published): https://www.lessmeet.2m0r.com/privacy

## Recordings on your Mac

Lessmeet records microphone and system audio when you start recording and grant
macOS permissions. System audio can include other applications; no video track is
saved. Obtain the necessary consent before recording others. Local audio, recording
metadata and saved AI results remain on your Mac. The app does not separately
encrypt those local files. Signing out does not erase the local library.

## Optional account and cloud AI

Local recording does not require an AI upload. When you sign in, Clerk processes
account and authentication information. When you explicitly confirm Create
Transcript, the combined recording is uploaded to our Convex backend and sent to
Google Gemini for transcription. Questions you send, the transcript and relevant
conversation context are processed to generate answers, summaries and action
items. These outputs may contain information about you or other participants.

Convex stores uploaded audio, transcripts and chat indefinitely unless deletion is
requested; there is no automatic content-expiry policy. Native account-deletion
initiation, confirmation and status refresh exist in the accepted implementation.
The guarded backend is deployed to development, with new-request intake and
automation gates off. This is not an available end-to-end provider deletion service.
The backend attempts exact temporary Google File cleanup when its identifier is
known and durably tracks known IDs and ambiguous operations. Cleanup may fail;
unknown/legacy copies and interrupted generation remain reconciliation exceptions.
Neither file cleanup nor expiry establishes deletion of all provider copies.
Canceling a subscription, signing out or stopping local waiting does not delete
cloud data or necessarily stop work already accepted by the server.

## Subscription information

Apple processes App Store purchases. RevenueCat processes subscription and
transaction status associated with your Lessmeet account identifier. Our backend
uses this information to verify access and track usage/allowance reservations.
Restoring a purchase requires the original Lessmeet account. Private service API
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
  evidence. After local cleanup and all five provider/residual confirmations, the
  identifier-bearing ledger is retained for 90 days of continuous completion.
  Reopened completion cancels the clock; unresolved work blocks purge. Daily bounded
  cleanup then removes the request and linked inventory, stage, outbox, contact and
  send records, leaving only an unlinkable completion/purge-time and policy receipt.
- Read-only provider inventory has a 30-day inactivity deadline after its latest
  accepted transition, not after a mere read. Daily bounded cleanup removes provider
  identifiers/configuration/cursors and leaves a minimal request-linked receipt.
  That receipt is not the final unlinkable ledger receipt and is removed with the
  completed request. Neither duration is a deletion-completion deadline.

Both policies are deployed to development and run independently of activation gates;
they do not approve new contact collection, email sends or provider destruction.
The separately gated notification implementation can retain a verified primary
non-relay email address and frozen completion message; it is not active. Resend is
the selected notification processor. Its account-level retention, contact/send
activation privacy and an alternative for absent/relay-only contacts remain to be
resolved. Submission would not establish delivery; no verified delivery path exists.

Clerk transport is accepted only as a disconnected, mocked module. The worker's
Clerk/Apple/RevenueCat destructive stages are not integrated; residual-copy handling
and original Apple revocation provenance remain unresolved. A synthetic development
ledger rehearsal used synthetic provider confirmations, not actual provider deletion.
End-to-end handling, completion timing and notification still need verification and
approval. No immediate deletion, response deadline or provider-erasure promise is made.

## Publication checklist — remove only after resolution

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
