# Privacy/deletion handling — unpublished operator runbook

Owner: Hoang Bang. Support contact: hoang@2m0r.com. Manual procedure approved
by operator 2026-09-23; later implementation/retention acceptance is recorded below.
Procedure partially rehearsed offline and on the selected Oct4 live case.
Only the scoped results below are accepted; full fulfillment is not accepted.
No live deletion is authorized by this document. Each destructive operation needs a verified request and exact
targets. Do not promise erasure beyond the supported case scope.

## Current KISS acceptance — issues #3 and #4 (2026-10-04)

This authorized scope decision supersedes older broad #3 completion gates below.
#3 is the usable account-deletion path. #4 owns broad privacy completeness and
public-release claims. Closing #3 does not close #4 or establish legal compliance.

Minimum #3 checklist:

1. Verify in-app initiation and destructive confirmation for the exact account.
2. Delete its LessMeet account and owned cloud rows/blobs/transcript/chat. Lock new
   cloud/billing work and handle known in-flight work without changing other owners.
3. Handle sessions and applicable login grants. Verify Google-through-Clerk
   responsibilities; Clerk user absence alone does not prove Google revocation.
   For Apple-linked cases, verify token revocation with the original client.
   Manual handling and approved evidence exceptions remain valid routes.
4. Handle specific known account-linked provider data or record a supported
   disposition/retention reason. Do not relabel unknown operations as erased.
5. Preserve local files and explain that Apple subscription billing is separate.
6. Process normal cases within7 calendar days from receipt. Use verified email
   for updates and the scoped result, including after account deletion. Exceptions
   need status, reason and a next-update time. This is an operating commitment,
   not a universal erasure/legal promise. Do not require email to initiate deletion.
   Resend-specific infrastructure and full automation are not acceptance conditions.

Accepted live evidence already covers native intake/confirmation/Refresh, empty
cloud cleanup/access lock, Clerk account/session deletion and local-file preservation.
Populated cleanup, isolation, late writes and retry have accepted offline fixtures.
An additional production seed is not a default closure gate. Use a selected synthetic
account only when a changed or still-unverified runtime path needs live evidence.
Apple-applicable handling remains required for applicable cases, not for the
verified Google-only selected case. Do not claim the untested Apple live path works.

Move these broad tasks to existing #4: Gemini project/billing/logging/sharing and
general retention policy; generic provider-internal logs/backups; external exports;
full-rollback/post-purge restore policy; legal applicability and public disclosures.
Owner: Hoang Bang for policy/provider authority, Lead for technical inventory.
Checkpoint: #4 acceptance before public claims/App Review submission. Return earlier
if evidence identifies a specific account-linked resource or a restore is proposed.
Known files, operation ambiguity or known retained records remain case work in #3.
No Gemini "delete user" API or proof that all internal Google logs vanished is
required by default. This transfer neither erases data nor authorizes a restore.

### Truthful runtime status and manual receipt

`deletion.status.providersComplete` still requires local cleanup, all five flags
and reconciled execution evidence. New requests also require separate Google
revocation acknowledgement or evidence-backed non-applicability. Outbox/email and the90-day purge use that broad
meaning. Do not set Gemini/residuals/RC flags to make the narrowed issue look complete.
Do not reinterpret those existing flags. The additive `googleStatus` describes
only Google handling; it does not replace the broad completion guard. A scoped
manual receipt for the historical case is not automated Google proof.

Record two distinct decisions: `#3 scoped outcome: accepted/pending` with exact
evidence, and `broad provider/privacy scope: pending` with #4 owner/checkpoint.
The native pending provider message remains truthful. It is not the scoped receipt
and may become unavailable after Clerk deletion. Do not make it the sole channel.
The native app displays the additive Google status when available. Never derive
Google success or broad completion from Clerk account absence alone.

Operational limit: a scoped #3 acceptance does not start the broad90-day purge.
The existing incomplete guard/evidence remains retained. #4 must resolve retention
of these pending records; this is a documented limit, not approval for a new policy.

### Google login permission handling

Product decision2026-10-05 supersedes the customer manual route below. Customers
initiate deletion only in LessMeet. The service handles applicable Google grants
before deleting Clerk prerequisites. Lead must verify pinned SDK/current primary
API support. The selected local implementation uses the existing Clerk worker,
Clerk Backend API provider-token lookup, then Google's revoke endpoint. Failure/unknown is
pending with an operator-owned recovery path, never inferred from Clerk absence.
Manual operator exceptions remain for genuine evidence/provider limits. Customer
Google Connections clicks are not normal-flow feature acceptance. The old selected
case must not be recreated or disconnected without separate exact authority.
Prepare fixtures/native integration first; a new live destructive test needs an
exact selected account and confirmation. Email7-calendar-day policy is unchanged.

Lead accepted primary-source inspection against the current Clerk worker/transport.
`deleteUser` and session revocation have no established Google grant-revocation
guarantee. The Clerk Frontend API exposes
`DELETE /v1/me/external_accounts/{external_account_id}/tokens`, distinct from
external-account deletion and Clerk-as-OAuth-provider token endpoints. Its contract
is provider-conditional; an acknowledgement is not a Google-side readback.
[Clerk Frontend specification](https://github.com/clerk/openapi-specs/blob/main/fapi/2026-05-12.yml).

For the already-deleted Google-only case, preserve accepted Clerk evidence and
the observed connection. Its manual-removal option requires separate action-time
permission and is case remediation only, not proof of the normal product path.
Do not recreate the deleted user or fetch new provider tokens for this old case.

Selected-case read-only observation2026-10-04 at16:22UTC: existing connections tab
and private account-control match verified. LessMeet remains listed; detail shows
Sign in with Google using name/email/profile picture, with access given to2m0r.com.
Separate Clerk entry not inspected or attributed. Branding/domain/scopes match
recorded production configuration, but this UI does not expose the numeric OAuth
client ID. Lead accepts connection presence, not revocation or exhaustive absence.
"Stop using Sign in with Google" remains untouched pending action-time authority.
The UI describes stopping automatic Google sign-in to LessMeet. No claim of deleting
provider-held data follows. Original connections page restored; browser released.
[Google connection controls](https://support.google.com/accounts/answer/13533235)
distinguish stopping Google sign-in from removing data access.

For a future selected case, the service performs supported Google revocation while
the required Clerk context still exists, then revokes Clerk sessions/deletes the
user. The backend route does not need a new native OAuth flow or Clerk FAPI session. Do not
put Google tokens in logs or invent a backend API. Google revocation can affect
that user's grants across the same project's clients; verify exact client/project
scope before execution and keep that consequence in confirmation copy.

#### Google recovery and smallest live trial

Owner: Lead handles execution diagnosis and evidence. Hoang Bang owns target,
external-effect and policy decisions. Keep a private case reference, status,
reason and next-update date for an unresolved request. The7-calendar-day email
policy still applies. No recovery command below grants authority for a live effect.

1. Inspect the exact request and `clerkExecution.inventory({id,owner})`.
   Preserve the execution fence, phase, frozen Google config and per-account result.
   Do not export tokens, upstream bodies or tokeninfo URLs.
2. If a metadata read failed, resolve the recorded cause and use
   `observeGoogleAgain({execution,owner,fence})` only for a blocked inventory phase.
   It preserves budgets and requires the original config. It cannot restart revoke.
3. If token lookup or revoke is unknown/rejected, keep the request pending.
   Do not retrieve a new token or replay revoke to guess whether the first call worked.
   If independent exact-target revocation evidence exists, use `resolveGoogle`
   with the current fence, stage fence, frozen Google config, target and private
   evidence reference. `revocation_verified` resolves only that target. The service
   then verifies inventory without another token lookup. Without evidence,
   record an operator exception and an update date; do not claim completion.
4. If the observed Google inventory is empty, verify historical non-applicability
   separately. Only then use `historical_non_applicability_verified` without a
   target. Empty current inventory alone is insufficient. The worker checks it again.
5. If account IDs, binding or stage evidence changed, stop downstream destruction.
   Do not rebind the row or reset budgets. Restore a wrongly removed original
   prerequisite only with matching evidence, or reopen the technical decision.
   Read-only inventory may resume only where its guarded handler permits it.
6. After Google proof, inspect Clerk session/user outcomes and reconcile their
   separate scope. Google acknowledgement does not set Clerk or broad completion.
   Keep operator attestations distinct from provider acknowledgements in the case.

The worker has no cross-provider transaction. A final metadata/fence check reduces
the race window but cannot undo a request already sent or guarantee that no remote
client changes a grant immediately afterward. Do not sign in, link accounts or
refresh provider tokens during the selected trial. Unknown races stay exceptions.

Automatic revocation supports exactly one current Google link. Multiple links
stop before token lookup and preserve Clerk state. Neither recovery entry point
can bypass that stop, including an older partially acknowledged execution.
Lead owns a technical route review when an actual multiple-link case appears.
Keep that case pending with a reason and next-update date; do not ask the customer
to disconnect Google as the normal deletion path.

Smallest live trial, after local candidate acceptance:

1. Human selects one new active test account and confirms its Google/Apple history.
   The automatic trial requires exactly one current Google link.
   Do not recreate the deleted old case. No populated recording or paid call is needed.
2. Lead verifies the exact Clerk instance/user, Google client `aud`/`azp` settings
   and project provenance. Record the consequence for this user's grants across
   clients in that project. A project label is not independent provider proof.
3. Capture the verified usable contact with sends disabled. Verify the selected
   account's initial connection and current provider metadata without token lookup.
4. Obtain exact authority for in-app deletion, provider-token lookup (which can
   refresh), Google project-scoped revocation and the subsequent Clerk destruction.
   Follow action-time confirmation for any destructive Computer Use click.
5. Submit from the approved LessMeet build and adopt only that exact request after
   local cleanup and Apple disposition. Record sanitized ordered execution evidence:
   Google acknowledgement precedes every Clerk session/user mutation. Stop on unknown.
6. Check Google connection propagation read-only for the same selected account.
   Keep connection visibility, API acknowledgement and Clerk absence separate.
   Do not sign in again or fetch a token to test revocation. Record a still-present
   connection as observed, not erased. Lead accepts the integrated scoped outcome
   only from the actual evidence; completion email still needs exact send authority.

Live compatibility, actual token availability and propagation are not established
by the mocked suites or offline native screenshots. The new Google gate remains
default-off until the selected deployment/configuration and exact trial are ready.

### Proportionate RC and Gemini evidence

For the selected case, exact RC customer and aliases endpoints returned404.
The native trial did not initialize RC, and cloud/billing/work inventory was empty.
Accept exact-ID absence and absence of identified case-linked records, not an
exhaustive historical-alias audit. Keep the broad RC flag false. A scoped manual
disposition may state that there is no identified RC resource to delete, with the
history limitation. Do not create a customer, transfer a purchase or issue DELETE
to manufacture proof. Reopen on an actual receipt, alias, SDK-identification history,
integration record or conflicting customer evidence. Ask a bounded case-history
question only if it would change that disposition; no automatic support escalation.

For Gemini, inventory exact case work and known file IDs. Resolve such resources
and ambiguous operations through existing guarded/manual procedures. Zero current
work does not prove historical erasure. With no identified case-linked resource,
record that limit and move the general project/logging review to #4. Never list/delete
shared project files or run paid AI to create deletion evidence.

Primary requirements rechecked Oct4: [Apple account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
allows manual fulfillment with timing and completion communication, and requires
Apple token revocation when applicable. [Google token handling](https://developers.google.com/identity/protocols/oauth2/resources/best-practices)
calls for revocation and deletion of no-longer-needed tokens. Do not confuse Clerk
session tokens with external Google tokens or substitute privacy deferral for a
known live login permission.

Human explicitly approved manual exceptions on 2026-09-26 for missing Apple
evidence and unverified RevenueCat aliases. Operator handling must retain an
incomplete/blocked state until evidence for the exact case supports completion.
Missing evidence is not non-applicability, alias ownership, or successful erasure.
This exception route does not waive normal-path fulfillment or authorize live
provider mutations/sends. Resume the case when evidence arrives; never clear it
solely because a deadline elapsed or an API acknowledged the request.

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
and the accepted working-tree/development checkpoints in [STATUS](../STATUS.md).
The current milestone is owner internal TestFlight testing, not public launch or
App Review. Publication gates below apply to that later public milestone; they are
not a claim that every internal beta requires public legal pages. This runbook
does not change packaging gates or authorize uploads, activation or live handling.
Use the [provider matrix](PROVIDER_DISCLOSURES.md) for dated public sources and
account-setting unknowns. This runbook grants no executable deletion authority.
Its approved7-calendar-day email commitment is defined above; older observations
and privacy research do not change that operational deadline.

## Intake and verification

Native Account settings now include Delete Account, destructive confirmation and
Refresh deletion status. Accepted intake, exact-owner guards, local cleanup,
partial automation and retention workers are deployed to dev `zany-octopus-315`;
new-request intake, automation and preflight activation gates are off. Contact
capture/sends are not active. Local source now includes separately gated durable
Clerk execution with fresh inventory, Apple-evidence fencing, observe-before-retry
and explicit operator reconciliation. Sep 26 production update: these workers are
now deployed to uncommon-narwhal-733; intake and automation are enabled there.
Oct3: Clerk/RevenueCat execution is configured and enabled; exact case adoption
is still required. Apple/contact/email remain off. Backend cleanup is real;
full live fulfillment is not established.
See [the local Clerk execution contract](../BACKEND.md#durable-clerk-execution--local-only).
Local source also includes bounded Apple/RevenueCat execution and explicit manual
case reconciliation; live fulfillment and verified notification delivery remain
unestablished. See [the provider execution contract](../BACKEND.md#apple-and-revenuecat-execution--local-only).
Use [the accepted internal operator contract](../BACKEND.md#internal-exact-owner-operator-procedure)
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
  backup erasure. Escalate specific case evidence; route generic policy review to #4.
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

For additional destructive rehearsals, use selected synthetic accounts/media:
mixed-owner isolation, queued transcription,
in-flight chat, storage cleanup, quota reservations, repeated request/idempotence,
partial provider failure and session invalidation. Existing real-case evidence is
retained; an extra production seed is not mandatory under the KISS decision.
Broad backup-restore policy/testing belongs to #4 unless a specific restore
or known account-linked copy makes it immediate case work.

### Oct3 production rehearsal — prepared, not run

Oct4 execution update: the selected personal account's native request was accepted.
Empty Convex cleanup and the access guard were verified. Human then confirmed
Google-only account history. Lead accepted case-specific Apple non-applicability,
completed guarded Clerk deletion and verified the app's signed-out state.
RevenueCat exact-subject v2 GET returned404/resource_missing; historical aliases
remain unverified. Gemini/residual handling also remains incomplete. See STATUS's
selected-account case for evidence, limits and remaining provider inputs. Earlier
preparation text below is not a pending permission or Apple/Clerk dependency.

Ready artifact: `dist/issue3-production-rehearsal-20261003/LessMeet.app`.
This is an ad-hoc signed local build, not a distribution upload. Its public config
binds Clerk production to uncommon-narwhal-733. RevenueCat SDK configuration is
deliberately absent: BillingStore.prepare returns before SDK identify when no key
exists. This bounds the first trial to authentication/intake and operator-handled
deletion. It does not prove removal of an existing RevenueCat customer. The previous
app was restored to `dist/LessMeet.app`; use the explicit rehearsal path.

Oct4 update: Human selected the current personal account for real deletion.
That explicit choice replaces the disposable-account requirement below. Lead may
operate the native intake, subject to Computer Use action-time confirmation.
Lead owns private evidence and exact-case execution. Production activation
permission is settled. No email, AI call, purchase or restore is authorized.

1. Verify the exact Human-selected account in the authenticated native session.
   Record known account history privately. Do not infer historical absence of
   Apple linking from a current Google login. Missing Apple evidence follows the
   approved manual exception and stays incomplete.
2. Before launching, quit other LessMeet builds. Clear any launch-environment
   CLERK_PUBLISHABLE_KEY, CONVEX_SITE_URL or REVENUECAT_PUBLIC_APPLE_KEY override.
   Open the explicit rehearsal artifact. A restored session is usable only when
   it matches the Human-selected account. Stop on any mismatch.
3. Use the selected account's existing authenticated session when available.
   Lead records the successful native callback and authenticated backend response
   for that exact subject. Do not copy JWTs, email addresses or private IDs into Git
   or chat. Stop on wrong project/account, auth error or uncertain identity.
4. Before destructive confirmation, Lead prepares a private case record with UTC
   time, exact deployment, selected native account, intended scope and before-counts.
   If all content/work/storage tables are empty, global zero counts prove the
   selected account has zero such rows without guessing its owner. Resolve the
   exact subject/owner from authenticated intake at step5. Before provider
   adoption, record provider history and target-bound inventory separately.
   Use exact-subject v2 RC GET, not v1 GET or a customer list. Capture any aliases
   without assuming ownership. Record current sessions, owned cloud rows/blobs,
   queued work, and the scope of residuals/backups. Do not upload audio or call
   Gemini to manufacture test data under the current permission boundary.
5. Once the case and scope are agreed, Lead opens Delete Account… and asks Human
   for action-time confirmation before clicking Delete Account and Cloud Data.
   That final click starts real cleanup; do not treat preparation as submission.
   Lead obtains request id/issuer-bound owner from the authenticated request row.
   All subsequent inventory/adoption/reconciliation uses those exact stored values.
6. Lead verifies local cleanup, then follows the durable worker contracts in
   BACKEND.md. Apple revocation or historical non-applicability evidence precedes
   Clerk adoption. Clerk absence/session evidence precedes RC adoption. If RC has
   no customer, independently evidenced non-applicability/absence is a manual
   confirmation, not a claim that DELETE ran. Keep aliases or unknown copies pending.
7. Before RC deletion, quit the trial app and stop other known clients for this
   selected account. Record the SDK/other-device recreation boundary. Observe
   provider readback without blindly replaying DELETE. Do not log back in through
   Google after Clerk deletion: that can create a new account and confuse evidence.
8. Lead records after-counts, request guard, session/access rejection, provider
   results and remaining copies separately. Report a sanitized completion/partial
   result to Human in the handoff. Automatic email remains off. The later approved
   email policy requires its own exact-recipient delivery rehearsal. This handoff
   does not substitute for email delivery evidence.

Observed Oct4 on the selected empty account; also expected for a fresh empty account:
`requested=true`, then `localComplete=true`, while `providersComplete=false`.
The last field requires all five provider/residual confirmations and resolved
execution evidence (`convex/deletion.ts`). Empty Convex storage is not proof of
Apple, Clerk or RevenueCat erasure. After Clerk deletion, a401 on Refresh is
possible and is not itself a provider-completion report.

Minimum return inputs and owners (Oct4 reconciliation):
- Human: selected-case account choice and action-time confirmation are resolved.
  A separate synthetic account is still needed for populated production rehearsal.
- Lead: native authenticated intake/Refresh, private before/after case and Clerk
  execution are accepted. Continue residual handling on evidence, without new login.
- Human/provider operator, only for an Apple-linked case: original-client proof
  and a securely provisioned presigned Apple secret/Clerk execution credential.
  Lead integrates those inputs; no need to block the Google-only path on all Apple
  exceptions becoming automated.
- Email owner/Lead, for the approved email route: exact recipient/send
  scope, contact credential/capture and delivery evidence. Resend config is ready;
  neither a configured sender nor this rehearsal authorizes a real notification.

Still untested live: populated cloud storage cleanup; mixed-owner/in-flight
production behavior; applicable Apple revocation; RC deletion/history/recreation;
Gemini legacy scope; relay/inbox delivery; backup-restore suppression.
Native authenticated intake/Refresh and real Clerk account/session deletion are
accepted for the selected case. They do not cover the remaining paths above.
Offline regressions and the signed build do not close issue #3.

### Oct4 completion evidence and next bounded rehearsal

Lead accepted five added offline cases. `Tests/backend/deletionCompletion.test.ts`
uses populated recordings/blobs, transcript/chat, batch content and quota/billing
rows. It preserves two unrelated issuer-bound owners, holds unknown work, rejects
late writes and retries a failed cleanup batch. Its restore test keeps the guard.
`Tests/backend/providerExecution.test.ts` adds initial404 and alias-conflict cases.
They reject stale/wrong-target reconciliation and make no DELETE call. Only a
synthetic operator attestation completes those fixtures. Full suite PASS969/26;
typecheck PASS. This does not establish live provider compatibility or erasure.

The following optional production rehearsal is prepared, not executed or required
by narrowed #3 acceptance. Use it only if a runtime change needs this proof.
Use a separate selected synthetic account, never the deleted personal account.
No paid AI or real audio.

1. Human selects the synthetic account and confirms its Google/Apple history.
2. Lead binds its subject and owner from authenticated records on the explicit
   production deployment. Record the exact candidate and private case manifest.
3. Lead prepares at most nine synthetic recording rows/blobs, one quota bucket,
   one billing row, one completed batch/chunk and one chat/context for that owner.
   Use fixed synthetic text and the existing test-media fixture. Record all IDs,
   hashes, counts and byte totals before execution. No provider file is seeded.
4. Before any production seed, Lead verifies a bounded admin route and reviews its
   exact manifest. Current upload routes require billable gates; do not enable them
   to manufacture data. No production seed handler exists or is deployed by this
   increment. Implement a one-use exact-owner seed only after the target is bound;
   reject pre-existing data and cap rows/bytes. Do not add a public seed endpoint.
5. Lead uses native authenticated intake with action-time destructive confirmation.
   Run normal cleanup and exact-owner readback. Keep provider stages pending until
   their own evidence exists. Never use fixture attestations in production.
6. Lead verifies every seeded blob is absent and every seeded content row is gone.
   Check unrelated existing owner counts without exporting content. Observe guard,
   Refresh and local-file preservation through the app-check skill.
7. If cleanup fails, retain the guard and exact manifest. Use bounded retry and
   supported work reconciliation. Do not reset the database or blindly delete rows.
   Remove any temporary seed capability before accepting the rehearsal. Retain the
   case under the approved retention policy; cleanup does not purge an open guard.

Production race/failure injection and actual backup restore are separate risky
operations, not implicitly authorized by that seed. Offline fixtures cover them
until a specific isolated target and recovery plan are approved.

### Issue #4 residual inventory and restore stop conditions

Observed08:01UTC Oct4 on production: Backup Never; no backups in this deployment;
no snapshot export requested yet. Private screenshots07/08 are in the existing
case directory. This does not prove absence of internal backups, external exports
or provider logs. No backup was created, downloaded, changed or restored.

For each residual, record these private fields: data class; exact provider/project;
location; purpose and approved legal basis, if any; retention start/end or explicit
unknown; access owner; deletion/expiry proof; restore suppression; next checkpoint.
Do not insert invented retention durations to complete the table.

| Residual class | Current result | Evidence owner / return event |
| --- | --- | --- |
| Convex visible backup/export inventory | Empty, schedule Never | Operator: prior external exports and internal/provider retention evidence |
| Clerk security/log/backup records | Unknown beyond accepted account/session scope | Operator/Clerk: case-specific retention/deletion response |
| RC historical aliases/integrations | Exact customer and aliases endpoint404; history unknown | Operator/RC: exact project/customer history disposition |
| Gemini files, operations, logs/datasets | No current case work; historical project scope unknown | Human supplies managing project/account; Lead reads billing/logging settings |
| Support/contact/case evidence | Private case exists; automatic contact missing | Human approves retention/access and communication policy |

The guard is a row in the same database as content. A full restore can roll it
back. The approved 90-day completed-ledger purge also removes target identifiers.
The anonymous receipt cannot reconstruct a deleted owner. Do not claim either
case is automatically suppressed by the retained-guard fixture.

1. Before a restore, keep the restored deployment isolated from clients, jobs,
   notifications and provider effects. Do not restore into serving production.
2. Resolve all deletion cases newer than the snapshot from a separately protected,
   authorized ledger. If that ledger is missing or identifiers were purged, stop.
3. Apply an exact-target reviewed suppression/cleanup plan before serving traffic.
   Current code has no general guard-reseed endpoint. Do not impersonate a deleted
   account or patch arbitrary production rows as a substitute.
4. Verify deleted-owner reads/writes reject, all restored target blobs/content are
   removed and other owners remain intact. Run late-write and retry fixtures.
5. Permit service only after Lead accepts the exact isolated result and Human
   authorizes cutover. Otherwise keep the restore unavailable.

Recommendation for approval: disallow restores that predate deletion cases when
the necessary protected ledger no longer exists. Alternative: approve a separate
longer-lived suppression ledger with purpose/access/expiry first. That alternative
changes retention policy; do not implement it under the existing90-day approval.
[Convex restore documentation](https://docs.convex.dev/database/backup-restore)
describes database replacement; a same-database guard is not an independent ledger.

### Conditional provider evidence requests — drafts only, do not send

These drafts are not default #3 dependencies. Use the RC draft only for an actual
case-linked inconsistency/record. Gemini general policy and provider residual
requests belong to #4. Applicable login-token semantics remain #3.

RC draft: For our exact project and customer in the private case, the v2 customer
and aliases endpoints return404. Please confirm how to establish historical aliases,
linked purchases/integrations and residual retention without recreating the customer.
Specify the evidence and supported deletion route for each remaining copy.

Clerk/Apple draft: For Backend API version2026-05-12, confirm the unit and freshness
semantics of OAuth access-token `expires_at`, and whether token GET can refresh it.
Provide the applicable Apple token/client provenance and revocation procedure.
No token, secret or full user payload should be included in the support request.
The pinned schema says Unix timestamp but does not settle seconds versus milliseconds.
Keep current fail-closed checks until authoritative endpoint evidence resolves this.

Google draft: For the exact Gemini project and billing tier, identify Files,
Interactions, abuse-monitoring, optional logs/datasets, sharing and backup retention.
Explain targeted deletion for legacy/unknown operations and copies without a file ID.
An OAuth login project is not proof of the Gemini key's managing project. Do not
list or delete all files in a shared project to answer an account-specific request.
[Gemini terms](https://ai.google.dev/gemini-api/terms) and
[logs/datasets documentation](https://ai.google.dev/gemini-api/docs/logs-datasets)
require project-setting evidence; file expiry alone cannot resolve these scopes.

### Approved 7-calendar-day email operation — implementation/readback required

The selected case has no captured contact. Email is disabled; no send is eligible.
After Clerk deletion, authenticated Refresh is not a reliable completion channel.
`notificationAdapter.payloadFor` is scope-qualified but carries no per-case pending
details or time estimate. Do not enable it as a substitute for approved policy.

Human selected email and7 calendar days from request receipt for normal scoped
deletion. Do not reinterpret this as business days. Operational deadline equals
requestedAt +7 *24 hours, with UTC recorded to avoid timezone/DST ambiguity.
Example: receipt2026-10-04T04:56:03.634Z gives2026-10-11T04:56:03.634Z.
This is an operating commitment, not a promise that all internal provider copies
are erased or a conclusion that every applicable law is satisfied. No stricter
case-specific requirement has been established by this implementation; #4 owns
applicability review. If a stricter requirement is identified, state the exact
requirement, affected case and policy gap before accepting that case.

Operator Hoang Bang owns fulfillment and email updates. Before the normal deadline,
an exception needs current status, reason and a concrete next-update date. Do not
silently time out, call the case successful, or extend the deadline without notice.
An exception update does not convert a missed commitment into a pass.

Capture the existing verified email bound to request/owner/subject and the correct
Clerk issuer/instance before Clerk deletion. Keep only the needed contact and
verification reference; never put the real address in Git/public logs. Its purpose
is request fulfillment and communication, not marketing. Use existing protected
case/contact storage and approved operational retention. The current broad pending
ledger may outlive scoped completion; #4 must resolve that explicit retention limit.
Do not silently extend the approved policy or start the purge clock with false flags.

Contact preparation must work with sends disabled. Missing, unverified, mismatched
or unusable relay contact is an operator exception, not permission to guess another
recipient. Do not delay applicable Apple token revocation merely to retain a relay.
For the already-deleted selected case, use its pre-deletion verified-contact evidence
for a bounded operator procedure; do not recreate the account to recapture it.

Manual email is sufficient; the broad automated completion-send path is not the
narrowed receipt. Prepare receipt, exception and scoped-completion drafts offline.
Do not enable an automatic send gate. Real rehearsal requires an exact selected
recipient, one approved message/scope, minimal content and explicit send permission.
API acceptance alone is not delivery evidence. Record receipt/readback separately;
keep #3 OPEN while email delivery remains UNVERIFIED.

Selected-case rehearsal2026-10-04: the one authorized received/status email was
accepted by Resend at10:33:14.525UTC. The recipient now confirms the exact subject
"LessMeet account deletion update" in the intended mailbox. Lead ACCEPTS scoped
recipient-reported receipt against the single recorded case send, subject and
recipient match. No competing case send is recorded. Exact receipt time and inbox
message-ID correlation remain unknown; no global outbox audit is claimed.
This proves the manual operator message, not the automatic outbox path.
Exact provider GET returned401;
no provider delivery metadata is available from that read. No automatic gate changed; no
additional send is authorized. Google permission disposition and the later scoped
completion notice remain outstanding. Receipt is not proof of full deletion or
automatic contact capture/deployment. Private attempt metadata is in
issue3-kiss-email-20261004/send-rehearsal-attempt.json.
[Apple guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
allows manual fulfillment but requires timing information and completion notice.

Unsent receipt template: "We received your LessMeet deletion request on [UTC date].
Normal requests are handled within7 calendar days, by [deadline]. We use this
verified email for updates and the result. Cloud access is locked. Completed:
[scope/evidence date]. Pending:
[provider/copy and reason]. Next update: [approved date/channel]. Retained records:
[purpose, basis and expiry, or explicit unknown]. Local recordings and Apple
subscriptions are unchanged. This is not a confirmation that all copies are erased."

Unsent completion template, only after accepted evidence: "Your LessMeet deletion
request completed for [explicit scope] on [date]. [List any narrowly approved retained
records, basis and expiry.] Local recordings and Apple subscriptions are unchanged."
Never send the completion template while unknown copies prevent accepting its scope.
Generic provider-internal privacy questions tracked in #4 do not expand the scoped
receipt into an all-copies-erased claim. Specific known account-linked unresolved
records must remain stated and cannot be silently omitted from that scope.

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
email/support conversation. Manual back-office fulfillment may follow. The approved
normal-case commitment is7 calendar days from receipt, with email updates/results.
Apple's guidance also requires a genuine account/data deletion option, not merely
deactivation. Pending provider steps must stay pending, including unavailable
credentials, partial failures, residual copies and unknown OAuth revocation.

Accepted guarded/native source and offline race/isolation/idempotence evidence are
recorded in STATUS; they are not live provider acceptance. Before operational use,
Lead must bind that evidence to the final integrated candidate and resolve any
changed behavior. An authorized operator verifies applicable case handling and
email delivery, then records minimal private evidence. Generic backup/retention
and public residual-copy disclosures belong to #4. Do not store private case
identities in this repository. Do not delete shared-provider files by broad list,
reset quotas, transfer purchases or cancel Apple subscriptions as a workaround.

Scoped #3 closure is per step: exact Convex rows/blobs, reservations, guard and late
writes; Clerk account/sessions and applicable login tokens; bounded RC disposition;
Gemini known files/operations; local/subscription preservation and email result.
Broad backups/exports/support and generic provider privacy remain #4 work.
Missing rows alone cannot establish complete erasure. No live procedure was run
or provider completion verified in the 2026-09-23 disclosure research.
