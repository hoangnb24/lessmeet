# Lessmeet Privacy Policy — unpublished draft

NOT FOR PUBLICATION until the operator has reviewed and completed this document.
This describes the current implementation, not a legal-compliance certification.

Evidence boundary: base `1a2685b5d56c04e13a724e611f9fafb16e7effe1`, reviewed
2026-09-23. "Current" below means that base, not parallel deletion work.
Publication requires reconciliation with Lead-accepted behavior and the
[provider disclosure matrix](PROVIDER_DISCLOSURES.md); no live settings were checked.

Effective date: [REQUIRED]
Lead reconciliation (2026-09-23): deletion source has now been accepted offline,
including native initiation and guarded cleanup. It is not deployed; the base
description below still reflects the prior deployment, not the proposed release.
Before publishing, replace the no-deletion-control limitation with verified release
behavior and approved timing/retention disclosures. Source tests alone are insufficient.

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

Convex stores uploaded audio, transcripts and chat indefinitely in this version;
there is currently no in-app deletion control or automatic retention cleanup.
The app attempts to delete temporary Google Files after processing when their
identifier is known. Cleanup may fail, and immediate deletion is not guaranteed.
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
the request. Do not include meeting content. Support-record retention and any
minimal deletion-verification record still require operator approval. Website
hosting can process connection/request metadata even without analytics scripts;
Cloudflare account logging and retention must be confirmed before publication.

For privacy or deletion requests during sandbox testing, contact hoang@2m0r.com.
The operator has approved manual handling after verifying account ownership and
confirming the requested scope. Do not send passwords, authentication tokens,
payment credentials or recordings in a request. This contact route is not an
implemented in-app account deletion feature. The handling procedure still needs
an end-to-end rehearsal before publication; no immediate deletion or response
deadline is promised by this draft.

Proposed release flow, NOT implemented/accepted evidence: initiate account deletion
inside the app, confirm identity and scope, receive honest pending/completed status,
and obtain confirmation after provider handling. Local recordings are separate;
account deletion must not silently erase them. Apple renewal must be managed
separately. Do not publish this paragraph as an available feature until verified.

## Publication checklist — remove only after resolution

- Set the effective date when approved; publish and verify the planned HTTPS URL.
  Confirm any additional operator contact details required before publication.
- Confirm actual production provider contracts/settings and data inventory;
  add applicable rights, retention exceptions and transfer disclosures with review.
- Implement and rehearse the approved manual account/data deletion handling, including provider copies
  and backups; do not imply removing a local file removes a cloud copy.
- Add in-app initiation of account deletion before App Store submission; a
  support-email-only flow is not sufficient for this non-regulated app.
- Reconcile App Store privacy disclosures and third-party SDK privacy manifests
  with observed behavior. Do not invent a no-tracking/no-training assurance.
- Resolve audience/storefront eligibility, rights-request routes and applicable
  processing bases/transfers; do not assume a low Apple age rating permits minors
  to use Gemini. Approve completion-time disclosures and necessary residual-record
  retention without changing indefinite content retention by implication.
