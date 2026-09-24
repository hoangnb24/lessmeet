# Manual privacy/deletion handling — sandbox procedure

Owner: Hoang Bang. Intake: hoang@2m0r.com. Approved by operator 2026-09-23.
Procedure partially rehearsed offline; NOT accepted for live use. No live deletion is authorized
by this document. Each destructive operation needs a verified request and exact
targets. Do not promise completion while provider copies remain unresolved.

Evidence boundary (2026-09-23): base `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
The base limitations and historical fixture outcomes below remain evidence even
while an implementation lane is working. Its work is not accepted by this runbook.
Use the [provider matrix](PROVIDER_DISCLOSURES.md) for dated public sources and
account-setting unknowns. This is a proposed operational procedure, not executable
deletion authority or a promise of a response/completion deadline.

## Intake and verification

Lead reconciliation (2026-09-23): A's exact offline source was accepted (manifest
df822f671f3607e28d6fd42ceb344ff3503a89fd9e7dfa4f1055b84bc957d31c).
The historical base instructions/results below are not the executable procedure
for the new code. Use [the accepted internal operator contract](../BACKEND.md#internal-exact-owner-operator-procedure)
for new guarded request/inventory/retry/reconciliation/provider-confirmation work.
No deployment, live provider handling or UI rehearsal has occurred. Retention,
timing/notification and live-operation authority remain prerequisites. Do not use
the historical row-only approach or treat source acceptance as deletion readiness.

1. Record a private case ID, request date, requested scope and deployment.
   Keep identifying case details out of Git, public logs and chat.
2. Verify control of the existing account through an authenticated session or
   verification sent to its existing verified contact. Sender address, claimed
   user ID and possession of a recording ID alone are not proof. Never request
   passwords, session tokens, card data or a copy of the recording.
3. Confirm whether the request covers specific cloud recordings or the entire
   account. Explain local files are separate and subscriptions must be managed
   through Apple: deleting an account does not cancel Apple billing. Do not make
   cancellation a condition of deletion. Explain access/restore consequences.
4. Resolve the Clerk subject and exact Convex `owner` from verified records.
   Recordings/quota/billing use the issuer-bound `tokenIdentifier`; RevenueCat
   uses the Clerk subject. Never derive ownership from email string matching or
   guess the owner string. Legacy recordings may not have a `subject` field.

## Inventory and stop new work

- Inventory exact recording IDs, their `_storage` audio IDs, embedded transcripts
  and `messages`, and account/quota records on the explicitly selected deployment.
  Do not export media/transcripts to make the inventory. Count before deleting.
- Identify queued/running transcription jobs, chat leases and reservations.
  Current code has no per-user deletion lock. Revoking sessions alone does not
  establish that already-issued JWTs or running actions have stopped. Do not
  begin ad-hoc row deletion while work can still race or recreate account data.
  A verified quiescence mechanism and synthetic rehearsal are required first;
  use a separately approved maintenance window if no per-user guard exists.
- Whole-account deletion must include Clerk and RevenueCat handling, not just
  recordings. Determine any narrowly necessary retention and communicate its
  basis and duration; do not invent indefinite billing-retention exceptions.
  Do not silently reset quota or make a subscription transferable as a shortcut.

## Execute only with verified targets and authority

- Remove each targeted stored audio object and corresponding recording data;
  deleting a database row does not itself remove its storage blob. Reconcile
  reservations before removing their quota buckets. Preserve other users' data.
- For account deletion, remove the relevant authentication account/sessions and
  customer data through the providers' supported procedures. Check aliases and
  identity linkage in RevenueCat without transferring purchases. Apple transaction
  records are outside the app database; explain any independent retention.
- Verify Sign in with Apple token revocation through the responsible integration;
  do not equate deleting a Clerk user with proof of Apple token revocation.
  Record supported provider results and unresolved steps separately.
- Gemini cleanup is best effort in current code; remote file identifiers are not
  durably recorded. Do not delete all files in a shared Google project to handle
  one user. Reconcile provider retention/settings or escalate to provider support
  if the specific residual copy cannot be identified.
- Inventory backups, provider logs and support records; track residual copies and
  retention separately. Maintain a minimal private deletion ledger so a restored
  backup does not silently reintroduce deleted data. No backup deletion promise
  is made until the actual provider/account capabilities have been checked.
- The proposed ledger/tombstone must have Human-approved purpose, minimal fields,
  retention and access controls before operational use. A durable guard is not
  permission to retain identity indefinitely or silently grant new free quota.

## Verify and close

Repeat exact-owner inventory and verify targeted blobs are gone, other accounts
are unaffected, no queued/running job recreates data, and deleted account access
is rejected. Report completed scope, remaining provider copies/exceptions and
local-file instructions to the verified requester. Do not label the case fully
erased based only on missing Convex rows. Do not email secrets or recordings.

## Required rehearsal / public-release gates

Use synthetic accounts/media only: mixed-owner isolation, queued transcription,
in-flight chat, storage cleanup, quota reservations, repeated request/idempotence,
partial provider failure, session invalidation, and backup-restore handling.
Partial offline rehearsal ran on 2026-09-23 in `convex-test`, with synthetic
records/blobs only and a network-denying fetch stub. See
`Tests/backend/deletionRehearsal.test.ts`. Five characterization tests passed;
passing means observed behavior was reproduced, NOT that deletion is safe.

| Check | Observed result |
| --- | --- |
| Row-only deletion and later timeout cleanup | FAIL readiness: audio remains and reserved seconds remain; missing row prevents timeout settlement. |
| Exact-target deletion under quiescent fixture conditions, repeated twice | PASS fixture: targeted row/blob/bucket absent; other owner's data intact. This uses test-only admin operations, not an implemented deletion endpoint. |
| Deleted queued row and late transcription result | PASS limited check: claim returns null; finish does not recreate row. Does not prove an already-running provider request stops. |
| Deleted processing row and late chat write | PASS limited check: authorization and chat write reject, row remains absent. No real in-flight provider call was tested. |
| Billing verification after billing-row deletion | FAIL readiness: account recreated. No per-owner deletion guard exists. |
| Clerk identity verification/session invalidation, RevenueCat/Gemini deletion, provider partial failure, backups | NOT RUN; no live provider operations or credentials used. |

Full backend regression: `npm run test:backend` passed 56 tests (51 existing plus
5 rehearsal cases). `npm run typecheck:backend` passed. Next implementation needs
a per-owner deletion guard, targeted/idempotent blob and reservation cleanup,
and coordinated provider deletion with durable progress before a full rehearsal
can pass. No production/backend implementation was changed by this rehearsal.

For App Store submission, add authenticated in-app initiation and confirmation
of account deletion. Manual fulfillment can remain behind that flow, but directing
users only to email support is insufficient for Lessmeet. Verify current Apple
requirements: https://developer.apple.com/support/offering-account-deletion-in-your-app/

## Proposed release flow and completion evidence

In-app initiation and confirmation must submit the request without requiring an
email/support conversation. Manual back-office fulfillment may follow, with an
approved time estimate and completion notification; none is invented here.
Apple's guidance also requires a genuine account/data deletion option, not merely
deactivation. Pending provider steps must stay pending, including unavailable
credentials, partial failures, residual copies and unknown OAuth revocation.

Before this runbook is marked usable, Lead must identify an accepted immutable
candidate and repeat synthetic race/isolation/idempotence checks against it.
Then a separately authorized operator verifies provider-specific handling and
backup-restore suppression, records minimal private evidence, and approves the
user-facing timing and residual-copy explanation. Do not store private case
identities in this repository. Do not delete shared-provider files by broad list,
reset quotas, transfer purchases or cancel Apple subscriptions as a workaround.

Closure is per step: exact Convex rows/blobs, reservations, guard and late writes;
Clerk account/sessions; Apple sign-in tokens; RevenueCat customer/aliases;
Gemini known files and unidentified-copy escalation; backups/exports/support.
Missing rows alone cannot establish complete erasure. No live procedure was run
or provider completion verified in the 2026-09-23 disclosure research.
