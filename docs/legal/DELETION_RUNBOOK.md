# Privacy/deletion handling — unpublished operator runbook

Owner: Hoang Bang. Support contact: hoang@2m0r.com. Manual procedure approved
by operator 2026-09-23; later implementation/retention acceptance is recorded below.
Procedure partially rehearsed offline; NOT accepted for live use. No live deletion is authorized
by this document. Each destructive operation needs a verified request and exact
targets. Do not promise completion while provider copies remain unresolved.

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
and the accepted working-tree/development checkpoints in [STATUS](../STATUS.md).
The current milestone is owner internal TestFlight testing, not public launch or
App Review. Publication gates below apply to that later public milestone; they are
not a claim that every internal beta requires public legal pages. This runbook
does not change packaging gates or authorize uploads, activation or live handling.
Use the [provider matrix](PROVIDER_DISCLOSURES.md) for dated public sources and
account-setting unknowns. This is a proposed operational procedure, not executable
deletion authority or a promise of a response/completion deadline.

## Intake and verification

Native Account settings now include Delete Account, destructive confirmation and
Refresh deletion status. Accepted intake, exact-owner guards, local cleanup,
partial automation and retention workers are deployed to dev `zany-octopus-315`;
new-request intake, automation and preflight activation gates are off. Contact
capture/sends are not active. An accepted local Clerk transport module remains
disconnected: the worker still reports `adapter_unimplemented`. No integrated
Clerk/Apple/RevenueCat destructive fulfillment or verified notification delivery is
established. Use [the accepted internal operator contract](../BACKEND.md#internal-exact-owner-operator-procedure)
for guarded request/inventory/retry/reconciliation/provider-confirmation work,
not ad-hoc row deletion. [Configuration](../CONFIGURATION.md) records deployment
and activation evidence; this reconciliation performed no account or environment reads.

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
- Identify queued/running transcription jobs, chat leases, reservations and admitted
  operations through exact-owner inventory. The transactional guard rejects new
  cloud/billing work and late results; it cannot retract an already-submitted
  provider call. Unresolved operations keep local completion pending. Revoking
  sessions alone is not proof that JWTs or running actions have stopped. Preserve
  the guard, reconcile side effects and use bounded cleanup/retry, never row-only
  deletion. Older untracked work and real backup restoration remain separate risks.
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
- Gemini cleanup records safe known file IDs and operation ambiguity durably.
  Only eligible exact-known files have bounded automated cleanup; unknown uploads,
  legacy copies and interrupted generation need reconciliation. Never delete all
  files in a shared Google project. File absence/expiry is not proof of log or
  backup erasure; escalate unresolved exact-scope evidence to the operator/provider.
- Inventory backups, provider logs and support records; track residual copies and
  retention separately. Maintain a minimal private deletion ledger so a restored
  backup does not silently reintroduce deleted data. No backup deletion promise
  is made until the actual provider/account capabilities have been checked.
- Apply the approved retention policies below. They do not permit deleting an
  incomplete guard, resetting retries, granting new quota or activating providers.

## Approved operational retention — not a completion SLA

Main content remains indefinite unless deletion is requested; no content TTL is
introduced. Incomplete requests retain their exact-owner guard and operational
evidence. After local cleanup and all five provider/residual confirmations, the
identifier-bearing ledger remains for 90 continuous days. Reopening a flag cancels
the clock; unresolved owner work blocks purge. Daily bounded purge removes the
request and linked preflight, stage, outbox, contact and send rows. The remainder
has completion/purge times and policy revision only: no owner, subject, email,
provider payload, token, evidence reference or request ID.

The separate preflight inventory expires 30 days after its latest accepted
transition; reads do not extend it. Daily bounded compaction removes identifiers,
configuration and cursors, retaining a minimal request-linked receipt to prevent
snapshot recreation. It remains request-linkable until the completed-ledger purge
removes it. Both workers are deployed to development and run even with activation gates
off. These are retention clocks, not 30/90-day deletion promises. Support records,
provider residuals/backups and contact/send activation still need scoped review.

The development rehearsal verified intake, empty cleanup and exact 90-day deadline
with synthetic provider attestations only; no actual provider deletion occurred.
Do not repurpose those attestations as live completion evidence. Retention approval
does not authorize contact capture or sends. A Resend acceptance would remain
delivery-unknown; no delivery webhook/readback exists, and missing/Apple-relay-only
contacts need an approved alternative that does not delay Apple revocation.

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

### Historical base characterization — not current implementation results

The following results describe base `1a2685b5d56c04e13a724e611f9fafb16e7effe1`,
not the accepted guarded implementation. They remain evidence of why row-only
deletion is unsafe, not an assertion that today's implementation lacks a guard.
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
5 rehearsal cases). `npm run typecheck:backend` passed. At that historical checkpoint,
a per-owner guard, targeted/idempotent cleanup and durable provider progress were
missing. Accepted work subsequently added guards, cleanup and progress tracking;
coordinated provider fulfillment still remains incomplete. No production/backend
implementation was changed by that historical rehearsal.

For eventual App Store submission, verify the existing native initiation and
confirmation against the actual submitted build and completed operational flow.
Manual fulfillment can remain behind it, but email-only initiation is insufficient.
Apple's [account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
was rechecked 2026-09-24; it requires timing and completion communication for
non-immediate fulfillment. No new estimate is supplied by this runbook.

## Remaining fulfillment and public-release evidence

In-app initiation and confirmation must submit the request without requiring an
email/support conversation. Manual back-office fulfillment may follow, with an
approved time estimate and completion notification; none is invented here.
Apple's guidance also requires a genuine account/data deletion option, not merely
deactivation. Pending provider steps must stay pending, including unavailable
credentials, partial failures, residual copies and unknown OAuth revocation.

Accepted guarded/native source and offline race/isolation/idempotence evidence are
recorded in STATUS; they are not live provider acceptance. Before operational use,
Lead must bind that evidence to the final integrated candidate and resolve any
changed behavior. A separately authorized operator then verifies provider handling and
backup-restore suppression, records minimal private evidence, and approves the
user-facing timing and residual-copy explanation. Do not store private case
identities in this repository. Do not delete shared-provider files by broad list,
reset quotas, transfer purchases or cancel Apple subscriptions as a workaround.

Closure is per step: exact Convex rows/blobs, reservations, guard and late writes;
Clerk account/sessions; Apple sign-in tokens; RevenueCat customer/aliases;
Gemini known files and unidentified-copy escalation; backups/exports/support.
Missing rows alone cannot establish complete erasure. No live procedure was run
or provider completion verified in the 2026-09-23 disclosure research.
