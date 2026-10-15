# Gemini backend contract

This contract covers retained cloud services and pre-pivot clients. The current
local-first app uses local transcription and ChatGPT, not these upload routes.

Development endpoint: `https://zany-octopus-315.convex.site`.
Production endpoint: `https://uncommon-narwhal-733.convex.site`.
This document describes local source contracts, not current live switch values.
Deployment and acceptance are tracked in [STATUS.md](STATUS.md); dated environment
observations are in [CONFIGURATION.md](CONFIGURATION.md).

**Current recorded dev policy: owner-funded Gemini with sandbox billing enforcement.**
The earlier unlimited-development policy was superseded when Human selected this
same deployment for sandbox billing. The owner accepted indefinite retention of
audio, transcripts and chat unless deletion is requested. Development Gemini access
was approved with `GEMINI_BILLABLE_ENABLED=true`; this is not a new live readback.
The switch remains reversible: false/missing blocks
uploads/chat and provider entry points while preserving authenticated reads.
Technical request/storage limits below remain. Paid agent tests and production
rollout remain separate from this development configuration approval.

Every request sends `Authorization: Bearer <Clerk session token>`. The server
validates Clerk's issuer and `aud: convex`. Never send a Gemini key from Swift.
The application does not accept a client-supplied owner or storage ID.

## Upload and transcription

The pre-pivot native Create Transcript action uses [batch transcription](BATCH_CONTRACT.md).
The following single-upload contract remains for legacy recordings and clients.

`POST /recordings` sends the combined audio as the raw request body, with its audio
`Content-Type`. The initial version accepts at most 18 MiB; larger recordings must
be rejected visibly, not shortened or silently split. The local source files stay
on the Mac regardless of cloud success.

An accepted upload returns HTTP 202 and `{ "recordingId": "..." }`. Keep this ID
with the local recording and the current account. Transcription runs in the
background. Poll `GET /recordings?id=<recordingId>` with the current session token
to obtain its status, transcript and chat messages. Stop polling when signed out
or when the selected account changes. Do not display a prior account's cloud
result after an account switch.

Status is `queued`, `processing`, `ready` or `failed`. The response includes
`recordingId`, `status`, `messages`, and optional `transcript`/`error`. A ready
recording can include a cleanup warning in `error`; show it without hiding the
transcript. Messages use `{ "role": "user" | "assistant", "text": "..." }`.
With billing enforcement on, uploads must be non-fragmented AAC-LC M4A with MIME
`audio/m4a` or `audio/mp4`; see the media validation limits below. The legacy
unenforced path accepts `audio/m4a`, `audio/mp4`, `audio/mpeg`, `audio/mp3`,
`audio/wav`, `audio/aac`, `audio/flac`, `audio/ogg` and `audio/aiff`.

## Chat

`POST /chat` accepts `{ "recordingId": "...", "message": "..." }` and returns
`{ "text": "..." }`. The server uses its owned transcript and saved conversation;
the client cannot substitute someone else's transcript/history. The transcript
must be ready before chatting. Requests must not be automatically retried after
an ambiguous network failure, since a provider call may already have been billed.
HTTP errors return `{ "error": "..." }`: 401 signed out, 404 absent/not owned,
409 not ready/busy/conversation full, 413 too large, 415 unsupported content type,
and 502 provider failure. A failed background job is reported by GET instead.

## Configuration and limits

Only Convex reads `GEMINI_API_KEY`. `GEMINI_MODEL` optionally overrides the default
`gemini-flash-latest`; a rolling alias may change upstream. Provider/model access
and transcription quality require a separately authorized live test.

Billing enforcement was deployed and enabled on the selected dev backend for
Human-tested sandbox billing. Further local edits do not deploy themselves. Authentication and
per-record ownership remain required. Production rollout is separate.
No audio, transcripts, tokens or provider error bodies should appear in logs.

Bounds: 384 KiB serialized transcript, 8 KiB question, 32 KiB serialized reply,
128 KiB saved history and 20 exchanges. Oversize/incomplete model responses are
rejected rather than saved partially. Jobs expire after five minutes; abandoned
chat reservations expire after two minutes. There is no automatic retry.

Cloud content retains the existing indefinite-storage policy unless deletion is
requested; no automatic content retention TTL is added. Main-ledger retention is
approved at 90 days after full verified completion, including reconciled execution
evidence and required Google proof. Clerk, Apple and RevenueCat workers are
implemented; their presence does not establish live fulfillment. Temporary Google Files are deleted after
transcription when their ID is known. Known IDs and ambiguous operations now have a
durable ledger; failures remain pending, not inferred deleted after a deadline.

## Acceptance

Before deployment, verify unauthenticated requests fail, a second user cannot
read or chat with the first user's recording, and the owner can complete the
upload/transcript/chat path using a mocked provider. Live audio/API testing is
not part of these offline checks. Swift cloud buttons are integrated and verified
with URLProtocol fixtures. Separately, Human reported one successful real login,
recording, transcription and chat round; full provider/device/quality coverage and
the current release binary remain unverified.

```sh
npm run typecheck:backend
npm run test:backend
```

Tests use fake identities, synthetic bytes and mocked Gemini transport. They do
not read deployment secrets or incur Gemini charges.

## Subscription integration (development sandbox; production pending)

`GET /billing` and `POST /billing/sync` accept only the Clerk bearer identity,
no body or query parameters. Both return `userId`, `enforcement`, `plan`
(`free`, `pro`, `development`), nullable `periodEndsAt` in epoch milliseconds,
and `transcriptionSeconds` / `questions` objects with `limit`, `used`, `reserved`.
Native SDK entitlement state is presentation-only, never authorization.

The approved allowance is Free lifetime 7,200 seconds / 20 questions or Pro
72,000 seconds / 200 questions per monthly window (annual subscriptions also
reset monthly). Pro windows use the initial subscription anniversary in UTC,
clamped at month end. Repeated sync, cancellation and plan switches must not
create new grants. Summary/action-item requests each consume one question.
Reservations and saved results settle atomically; system failure/expiry releases
the reservation. Local recording and already-saved local results remain usable.

Rollout prerequisites (Human selected existing dev `zany-octopus-315` for sandbox;
production activation remains unauthorized):

- Connect only RevenueCat Lessmeet `a83a7730` to Apple `com.lessmeet.app`.
  Entitlement `lessmeet_pro`; products `com.lessmeet.app.pro.monthly` and
  `com.lessmeet.app.pro.yearly`, approved USD 9.99 / 99.99. Publish the current
  offering; native prices are loaded from StoreKit rather than these targets.
- Independently verify RevenueCat **Keep with original App User ID** restore
  behavior. Server requires exact original Clerk subject; no anonymous purchases.
  Set `REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED=true` only after verification.
- Supply server-only `REVENUECAT_SECRET_API_KEY`; never bundle or log it.
  `BILLING_ENFORCEMENT_ENABLED=true` opts in. Missing/false retains development
  access without RevenueCat lookups or quota enforcement. Verification outages
  fail closed when enabled. `REVENUECAT_ALLOW_SANDBOX=true` is allowed on the
  Human-selected dev target for sandbox testing, never production. Verify credentials
  and restore policy before enforcement; it affects every account on that backend.
- Native public configuration: `REVENUECAT_PUBLIC_APPLE_KEY` (`appl_`),
  `LESSMEET_PRIVACY_URL`, `LESSMEET_TERMS_URL` (published HTTPS legal pages).
  Missing/invalid billing configuration never disables local capture or sign-in;
  missing legal pages or unconfirmed server status disables purchasing.
- Human reported core sandbox purchase/restore, reopen, account isolation, expiry
  on Refresh and no duplicate allowances in the signed development-sandbox app.
  Renewal continuity and live AI debit/refund still need evidence. Store distribution
  is not accepted, and profiles must be regenerated after enabling Sign In with Apple.
- Confirm actual audio parsing and measure AI/storage/transfer cost before public
  activation. Enforced uploads are non-fragmented AAC-LC M4A only, still max
  18 MiB. Sample-table validation is not a full audio decode; malicious payload
  resistance, parser CPU/memory amplification and long-recording duration/size
  remain rollout concerns. Local pre-parser hardening bounds recognized box trees
  and checks fixed-width tables before MP4Box expansion; erased AAC payloads still
  pass structural checks, and descriptors/extensions remain an unverified parser
  surface. See [bounded media evidence](../Tests/backend/MEDIA_SAFETY_HANDOFF.md).
  Native synthetic 30/60/120-minute exports measured 29.56/59.11/118.22 MiB, all
  over18MiB; local export success is not long-upload readiness. See
  [long-capture evidence](../Tests/LessMeetTests/LONG_CAPTURE_HANDOFF.md).
  AAC padding plus per-upload rounding can add a second to the charge.
  The actual native synthetic 1.25s source/export compatibility fixture passes
  backend validation and reserves/charges 2 seconds only on saved success.

No live deployment, key sharing, store purchase or production switch change is
included in offline implementation acceptance.

## Account deletion

The implementation includes in-app intake, owner guards, local cleanup, provider
workers and a separately gated notification sender. Generic provider stages stop
as exceptions until explicitly adopted into the relevant worker. Residual-copy
handling remains operator-owned. A DELETE acknowledgement or absent account does
not establish complete provider erasure.

The Sep 26 backend was deployed to production. Oct3 configuration enabled intake,
automation and Clerk/RevenueCat execution. Oct4 evidence covers one selected Clerk
deletion and one recipient-confirmed manual status email, not full fulfillment.
The Oct5 Google prerequisite and revised contact/email implementation remain local
according to the recorded handoff. Automatic delivery remains unverified.
See [the operator runbook](legal/DELETION_RUNBOOK.md) for current scope and limits.

### Durable Clerk execution

The2026-10-05 local extension inserts Google grant handling before Clerk session
and user destruction. This extension is not deployed or live-verified yet. See
the Google section below; historical Clerk-only evidence does not verify it.

The earlier Clerk worker was configured and enabled Oct3, with a selected-case
deletion observed Oct4. That result does not verify the later Google prerequisite.
Exact case adoption is still required.

`CLERK_DELETION_ENABLED=true` and `DELETION_AUTOMATION_ENABLED=true` are both
required. The immutable binding uses `CLERK_JWT_ISSUER_DOMAIN`, matching
`CLERK_CONTACT_ISSUER`, `CLERK_CONTACT_INSTANCE_ID`, and a nonsecret
`CLERK_DELETION_CONFIG_REF`. A separate `CLERK_DELETION_SECRET_KEY` is used only
in action memory. Never substitute the read-only contact key or silently repoint
a revision to another instance. No credential is provisioned by this change.

#### Google grant prerequisite

Pinned Clerk iOS1.5.5 exposes external-account destroy/reauthorize, not a public
Google grant-revoke method. The Clerk Frontend API has a provider-conditional
token-revoke endpoint, but the native SDK does not expose its required authorized
client transport. A LessMeet JWT is not that FAPI client credential. The selected
route uses the existing backend credential while the Clerk user still exists.

The Backend API returns Google provider access tokens and may refresh them during
lookup. The pure `googleDeletionTransport` binds the Clerk instance/user and
current external-account IDs. It checks token `aud`, `azp`, `sub`, expiry and narrow
sign-in scopes through Google tokeninfo before posting to Google's revoke endpoint.
`aud` and `azp` have separate trusted settings. A project label records operator
provenance; it is not independently returned by tokeninfo. Never put access tokens,
tokeninfo URLs, provider payloads or credentials in logs, errors or ledger rows.

Google200 is a revocation acknowledgement, not proof of erased Google data or
immediate disappearance from the Connections UI. Google documents eventual effects
and revocation across that user's clients in the same project. Live acceptance must
bind the actual client/project and selected account before authorizing this effect.
Tokeninfo is a fail-closed diagnostic guard, not an availability guarantee.

New intake sets `googleRequired=true` and `googleStatus=pending`. The status API
returns an additive `googleStatus`, or null without a request. Legacy records with
no Google state return null, which preserves legacy native decoding without
asserting Google success. The broad completion helper also requires bound
Google proof for new requests. Clerk deletion and generic provider confirmation
cannot synthesize that proof. Keep its nonsecret reference on the deletion row
until final purge so deleting execution children does not strand retention.

No token is persisted. Unknown mutation results need operator recovery and must
not automatically re-fetch a provider token or replay revoke. Empty current Google
inventory is not evidence that a historical grant never existed. Pending cases
remain operator-owned; customers do not have to disconnect Google for normal flow.

The Google phases are `inventoryGoogle`, `revokeGoogle` and
`verifyGoogleInventory`. Exact external-account/Google-subject pairs are frozen;
automatic revocation permits exactly one current Google link. Multiple links stop
before token lookup with `google_multiple_accounts_operator_required`. Known
multiaccount executions cannot resume through claim, recovery or operator resolution,
even if later inventory shrinks. Lead must reopen that route when a real case needs it.
The single target keeps an acknowledgement marker and optional operator evidence ref.
Empty-inventory attestation keeps `googleOperatorEvidence` separately from the
final bounded `googleEvidence`. The worker rechecks metadata only before each
Clerk mutation. It must not refresh Google tokens after accepted revocation.
`resolveGoogle` requires exact owner/fence/stage/config/evidence and resolves one
ambiguous target or evidenced historical non-applicability. `observeGoogleAgain`
only resumes bounded metadata reads under the same configuration. Neither entry
point resets budgets or blindly replays an unknown revoke. See the
[recovery and live trial procedure](legal/DELETION_RUNBOOK.md#google-recovery-and-smallest-live-trial).

Primary contracts: [Clerk BAPI](https://github.com/clerk/openapi-specs/blob/3b078e5e0c17ad5261f06cb00e0a0943614dacb0/bapi/2026-05-12.yml),
[Clerk FAPI](https://github.com/clerk/openapi-specs/blob/3b078e5e0c17ad5261f06cb00e0a0943614dacb0/fapi/2026-05-12.yml),
[Google revocation](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke),
[Google token types/tokeninfo](https://docs.cloud.google.com/docs/authentication/token-types).

Internal entry points (never expose these as user/client inputs):

- `clerkExecution.adopt({id,owner,stageFence,appleFence,appleEvidence,disposition})`
  adopts exactly one blocked `adapter_unimplemented` Clerk stage after local
  cleanup. Refuses manual stages, exhausted legacy budgets, target/binding conflicts
  or unverified Apple evidence. Disposition must be `revocation_verified` or
  `historical_non_applicability_verified`: an operator attestation backed by the
  private Apple case, not a conclusion from a missing current Apple link. Freeze
  that evidence and the monotonic Apple-stage fence. Repeating the same adoption
  is idempotent and never resets budgets; changed bindings are not auto-migrated.
- `inventory({id,owner})` returns only the exact request's execution and sanitized
  session evidence to trusted operators. It is not public status.
- `observeAgain({execution,owner,fence})` only requeues a blocked GET phase after
  mutation uncertainty; same binding and Apple proof must still hold. It never
  rearms DELETE/POST or resets attempts. Unchanged active session/user remains an
  operator exception, not an infinite destructive retry.
- `reconcile({execution,owner,fence,evidence})` records explicit private-case
  acceptance of residual/session scope, only after completed bounded inventory,
  handling of every observed session and typed user absence. This alone sets
  `clerk=true`; the generic confirmation path cannot bypass unresolved execution.
- `releaseInvalidated({execution,owner,fence,stageFence,automationRevision,evidence,
  remoteEffects:"reconciled"})` closes an execution hold after its generic stage
  was explicitly reopened. Running leases must first expire. Requires the exact
  current manual-stage fence and request revision, preserves prior results/budgets,
  and does not set `clerk=true`. A separate evidence-backed confirmation follows.

Each action verifies the pinned Clerk instance and exact target. New execution
inventory is independent of frozen preflight snapshots: at most eight pages of32,
and a full eighth page is incomplete/blocked. Duplicate/moving pagination blocks.
Known sessions are observed and, if active/pending, revoked individually. Exact
revocation, terminal status and typed absence remain different evidence. Account
DELETE acknowledgement is followed by GET; absence alone never sets the Clerk
completion flag. No claim of historical/global session completeness is made.

Before every destructive request and before accepting its result, check gates,
config, exact request, worker lease/fence and frozen Apple-stage evidence. Mutation
intent is durable before submission. Lost leases, transport failures and malformed
mutation responses transition to observation, never blind mutation replay. Fences
cannot retract a request already sent to Clerk. Eight attempts per observation/
page,1024 total claims,90-second leases and20-second transport deadlines bound work.
The existing deletion recovery cron dispatches this gated recovery; no new cron.

Minimal execution evidence survives30-day preflight compaction. Unresolved
execution blocks the90-day completion clock/purge even if flags are inconsistent;
reconciled execution is deleted with the completed ledger. Contact capture and
delivery remain independent and must not delay revocation; relay/missing contact
and loss of authenticated status refresh after Clerk deletion need the existing
operator completion-notification process before live use.

Source semantics: [pinned Clerk REST schema](https://raw.githubusercontent.com/clerk/openapi-specs/main/bapi/2026-05-12.yml).
Mocked coverage is in `Tests/backend/clerkExecution.test.ts`. Dated live evidence
and its limits remain in STATUS; these tests do not establish provider behavior.

### Apple and RevenueCat execution

`providerExecution` shares one small durable case worker for these two providers,
not a generic integration framework. Deployed to production Sep 26; RevenueCat is
configured/enabled Oct3, Apple remains off at that checkpoint. All provider
results are observations/acknowledgements until operator reconciliation. It retains
no OAuth tokens, client secrets, private keys, raw responses or provider error text.

Common prerequisites: automation gate plus the provider-specific gate, matching
Clerk issuer/instance binding, exact deletion request/owner/subject/time, local
cleanup complete, and a blocked `adapter_unimplemented` stage with expected fence.
An immutable nonsecret configuration revision is frozen at adoption. Repeated
identical adoption returns the same execution without resetting attempt budgets;
no background scan adopts accounts. Generic confirmation cannot bypass an unresolved
execution. New rows participate in the same90-day completed-ledger purge and block
completion/notification/public status when unresolved, even with inconsistent flags.

Apple configuration: `APPLE_DELETION_ENABLED`, `APPLE_DELETION_CONFIG_REF`,
`APPLE_DELETION_CLIENT_ID`, `APPLE_DELETION_TEAM_ID`, `APPLE_DELETION_KEY_ID`,
dedicated `APPLE_DELETION_CLERK_SECRET_KEY` and pre-signed
`APPLE_DELETION_CLIENT_SECRET`. No new private-key signer/custody is introduced.
The client-secret header/claims must match the frozen config, use ES256, have a
valid time window and at least60seconds remaining. Structural checks are not
signature verification; trusted provisioning is still necessary.

`adopt({id,owner,provider:"apple",stageFence,safetyEvidence,apple})` accepts
`apple:{externalAccountId,providerUserId,originalClientId}` only with original-client
provenance attested by the private `safetyEvidence` reference. The current Services
ID is not historical proof. Omitting the identity creates an explicit blocked
manual case with no transport calls; a contradictory client is rejected. Run before
Clerk deletion. Transport freshly verifies the Clerk instance/user and exactly one
verified Apple link, obtains exactly one matching token via pinned Clerk REST,
and submits form-encoded `/auth/revoke`. Tokens stay inside that action. The token
GET can itself refresh credentials, so authorization is rechecked before it and
again immediately before revocation. Multiple/missing/unverified identities,
missing tokens and ambiguous results stay operator exceptions.

Clerk `expires_at` is described as a Unix timestamp without explicit units in the
inspected schema/SDK. The current conservative adapter requires freshness under
both seconds and milliseconds interpretations; seconds-scale/null values may
therefore route to manual handling. This is an explicit unverified live-compatibility
limit, not invented unit conversion. Apple200 with empty body is acknowledgement,
not proof of original-client identity or complete erasure. No automatic POST retry.

RevenueCat configuration: `REVENUECAT_DELETION_ENABLED`,
`REVENUECAT_DELETION_CONFIG_REF`, `REVENUECAT_DELETION_PROJECT_ID`, and separate
`REVENUECAT_DELETION_SECRET_KEY` with appropriate v2 customer read/write access.
Never reuse/upgrade the read-only preflight key implicitly. Adoption requires
completed Clerk handling and freezes its stage fence; `safetyEvidence` covers
SDK/other-device recreation handling for the exact case. V2 GET is used for
observation, never the v1 GET that can create a missing customer.

Before DELETE, transport freshly GETs the exact customer/project and aliases.
Only the exact subject (or an empty alias list) is accepted; additional aliases
or any non-null continuation become `alias_ownership_unverified` with no DELETE.
The supported normal path deliberately does not follow unexplained alias links.
HTTP200 DELETE means queued asynchronous handling, not disappearance. Subsequent
bounded GETs retain present/unknown/absent distinctions. Eight observation attempts,
provider retry hints and a nine-claim total bound readback; no automatic DELETE
replay. Reappearance or unresolved visibility is manual, not a cancellation of
Apple subscriptions or permission to transfer purchases.

`inventory({id,owner})` returns at most two private execution rows. Internal
`reconcile({execution,owner,fence,evidence,automationRevision})` is the explicit
operator path for observed/blocked/exhausted cases: the private evidence must
establish the actual scope, including unresolved Apple history/RC aliases and
recreation risks. It marks the existing provider stage manual and sets its flag;
it does not fabricate an automatic acknowledgement. Missing evidence keeps the
case incomplete. Lost leases record uncertainty; RC may only observe afterwards,
Apple requires operator handling. No additional periodic cron was added.

`providerExecution.releaseInvalidated` has the same exact-revision contract as the
Clerk entry point above. It handles an operator reopening during execution without
stranding the case or restoring execution authority. Reopening cannot recall a
remote request already sent: the private evidence must reconcile that possibility.
Release alone keeps the provider flag false and does not start completed retention.

Sources: [Clerk pinned BAPI](https://raw.githubusercontent.com/clerk/openapi-specs/main/bapi/2026-05-12.yml),
[Apple revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens),
[Apple manual handling](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple),
[RevenueCat v2 customer API](https://www.revenuecat.com/docs/api-v2/customer).
No live token/client binding, provider deletion or delivery is established by mocks.

`GET /account/deletion` requires the current Clerk bearer token and no query
parameters. `POST /account/deletion` requires that same authentication, no query
parameters, and exactly `{"confirm":"delete-account"}` (maximum 128 bytes).
No owner, subject, storage ID or provider ID is accepted from the client. GET
returns 200; an accepted or repeated POST returns 202, **not completion**:

```json
{"userId":"clerk-subject","requested":true,"localComplete":false,"providersComplete":false,"requestedAt":1234}
```

`requestedAt` is epoch milliseconds, or null before a request. `localComplete`
means the currently inventoried Convex rows/blobs, quotas, billing rows and
admitted operations have drained. It does not cover unidentified legacy orphans,
provider logs or backups. `providersComplete` additionally requires distinct
operator evidence for Clerk, RevenueCat, Apple sign-in revocation, Gemini and
residual copies. It is never set by waiting, a failed API request, or missing rows.
No API response claims universal erasure. The owner lock remains even after all
steps are verified. A surviving valid JWT may read/request its own deletion status,
but cannot read recordings, start cloud work or repopulate billing.

Native Account settings provide Delete Account, explicit destructive confirmation
and Refresh deletion status. Fresh tokens and user/session checks fence confirmation
and late responses. Ambiguous submission locks cached upload/purchase controls until
an explicit status refresh establishes otherwise; requests are not auto-retried.
Local audio, metadata and saved transcripts/chat are untouched. Subscription
cancellation is separate, linked to Apple's subscription settings, and is never a
prerequisite. Deletion does not transfer purchases or grant new allowance.

### Activation and approved ledger retention

New requests default to HTTP 503 unless `ACCOUNT_DELETION_ENABLED=true`. Existing
requests, guards, status and internal cleanup/retries do not depend on this switch.
Cloud calls create short-lived work admissions even with intake off; failed or
ambiguous admissions persist for reconciliation. The Human approved the main-ledger
purpose, fields and duration on Sep 24: incomplete requests retain their exact guard
and reconciliation state; fully verified requests retain identifier-bearing state
for 90 days from completion. Intake remains a separate switch and is not enabled by
that approval.

Proposed minimum: issuer-bound `owner`, verified Clerk `subject` for provider
targeting, request/update timestamps, local/provider progress and opaque private
evidence references. Pending operations additionally retain kind/start time, exact
storage/file ID when known, and ambiguity/finished flags. Successfully drained
operations are removed. No recording text, audio, tokens or provider errors
are copied into this ledger. The separate default-off contact/send records below
retain one verified address and its frozen notification; collection remains separately
gated. Reopening any completion flag cancels the purge deadline. After 90 days of
continuous verified completion, a bounded daily worker removes the deletion row and
all request-linked preflight, stage, outbox, contact and send rows. It refuses to purge
while any owner work remains. The only durable remainder is an unlinkable receipt
containing completion time, purge time and policy revision `completed_90d_v1`; it has
no request ID, owner, subject, email, token, payload or evidence reference. This window
exceeds the currently documented 14-day backup window, but production backup/restore
behavior still requires rehearsal before release.

This policy is deployed on dev `zany-octopus-315`. A fixed synthetic identity passed
intake, empty local cleanup, synthetic operator completion and exact 90-day deadline
scheduling with zero unresolved work. The temporary rehearsal action was removed and
all activation gates were removed afterward. Provider flags in that fixture are
synthetic attestations only: no Clerk, RevenueCat, Apple or Gemini deletion ran, so
this proves ledger orchestration and retention—not provider erasure.

The approved operating policy is normal scoped deletion within seven calendar days
of receipt, with email updates/results. Exceptions require a status, reason and
next-update time. See the [approved procedure](legal/DELETION_RUNBOOK.md#approved-7-calendar-day-email-operation--implementationreadback-required).
This is not a universal erasure guarantee or verified release readiness.

### Race and cleanup contract

- `deletions.by_owner` is the transactional guard keyed by `tokenIdentifier`, never
  email or subject alone. Quota admission, recording access/writes/job claim and
  authorization, and both halves of billing verification check it. Guarding billing
  remains mandatory when quota enforcement is off.
- `deletionWork` admission commits before storage upload, Gemini transcription/chat
  or RevenueCat lookup. These external calls cannot share a transaction with the
  guard. A request already admitted may still reach its provider; the ledger blocks
  cleanup completion until it returns or an operator proves it has stopped and
  reconciles its side effects. The guard rejects late DB results.
- Gemini records a safe returned file name before generation, rechecks the owner
  before generation, and attempts exact-file DELETE even on failure. The upload
  response/persistence crash window remains ambiguous; no shared-project sweeping.
  Even a verified File DELETE does not resolve an interrupted generation response;
  that operation remains pending for provider reconciliation.
  Google Files expiry and `store: false` do not prove all processing/log copies gone.
- Cleanup runs internal mutations, at most 8 recordings, 32 quota buckets or 8
  billing rows per invocation, scheduling the next batch. Reservations settle before
  rows/buckets disappear. Storage metadata existence is checked before deleting to
  make missing blobs harmless. Transaction failure preserves retry targets; errors
  never mark completion. No automatic retry of paid work is introduced.
- Persistent unknown operations, including failed storage cleanup, keep the request
  pending. They have no timeout-to-success transition. Legacy untracked provider
  copies and storage orphans remain a separate manual inventory limitation.

### Internal exact-owner operator procedure

This legacy manual route remains available for exceptions and missing adapters.
It is a usable interface/procedure for a separately authorized operator, not
authority to run it live. All helpers below are internal Convex functions, never
public HTTP endpoints. Use the approved deployment's Functions UI or controlled
admin tooling; do not copy credentials or private targets into shell history/Git.
Choose the deployment explicitly and derive targets from the authenticated deletion
row, not an email match or an ID supplied by an unverified requester.

1. In the `deletions` table locate the verified request; privately record its `_id`,
   exact issuer-bound `owner` and stored `subject`. Every operator call requires both
   request `id` and matching `owner`; mismatches fail without changes.
2. Call `deletion:inventory` with `{id, owner, cursor:null}`. This returns request
   progress and up to 32 work entries, not recordings. Continue with the returned
   `continueCursor` until `isDone`; all reads stay exact-owner. Entries identify
   operation kind, time, whether it returned, and exact known storage/Gemini IDs.
3. `deletion:retry({id,owner})` schedules bounded local cleanup again. Repeated
   calls are safe. Inspect failed scheduled mutations; fix only verified exact-owner
   accounting/storage prerequisites under separate authority, then retry. Never
   delete quota buckets first or remove the guard to make a retry pass.
4. For each remaining work entry, first establish the action has stopped. A deadline
   alone is insufficient. If `file` is known, use the provider's supported exact-file
   deletion and verify the result; failures stay pending. If upload acknowledgment
   or file name is missing, reconcile with provider/storage evidence or escalate.
   Never guess IDs or delete every file/customer in a shared project.
5. Only after independently proving that operation and its external side effects
   resolved, call `deletion:reconcileWork({id,owner,workId,evidence})`. `evidence` is
   a 1–100 character `[A-Za-z0-9_-]` private case-reference ID, not the evidence itself.
   This removes a known owned orphan blob if present, drops that work entry and
   schedules cleanup. It **does not call or fake success from a provider API**.
   Repeat reconciliation is harmless. Incorrect operator attestation can make
   progress incorrect; restrict admin access and retain reviewed proof privately.
   For requests with `automationRevision`, include that exact revision from a fresh
   `deletion:inventory` read. Omission/stale revision fails with 409. Reconciliation
   fences the corresponding file stage before removing work; a late worker cannot
   overwrite operator evidence. The same revision requirement applies to `confirm`.
6. Once local cleanup is verified, fulfill provider steps using the stored subject
   and actual linked identities, retaining the guard throughout. Use
   `deletion:confirm({id,owner,stage,complete,evidence})` for each stage. Stages are
   `clerk`, `revenuecat`, `apple`, `gemini`, `residuals`; each has its own durable
   pending/verified value and private evidence reference. `complete:false` records
   failure/reopened verification and allows later retry. `complete:true` is rejected
   while local operations remain unresolved. Do not set a stage true just because
   a request was submitted or accepted asynchronously.
7. Before new Clerk deletion, retain the verified durable account-bound email for
   the approved7-calendar-day email operation. Missing/relay/unverified contact
   stays an operator exception; do not invent a recipient. Handle applicable Google
   login permissions separately from Clerk sessions. Clerk: verify deletion of the
   exact account and its sessions. Apple: independently
   verify token revocation through the responsible Clerk/Apple integration (or
   verified non-applicability when no Apple identity was linked). **Clerk deletion
   is not Apple revocation proof.** Verify revocation prerequisites before deleting
   access to the needed linked-account information. RevenueCat: verify the exact
   subject/customer and aliases, without cancelling/transferring subscriptions or
   weakening original-owner restore policy. Aliases belonging to another owner
   require escalation before deletion, not a broad customer sweep.
8. Gemini: reconcile known case Files and ambiguous operations. Generic project
   settings/logs/retention and `residuals` backup/export/support review now belong
   to #4, unless a specific account-linked record makes them immediate case work.
   Unknown copies keep broad progress pending, not necessarily narrowed #3 closure.
   Independently retained
   Apple transaction records are not erased by LessMeet. Record and communicate
   scope/approved exceptions rather than claiming all copies gone.
9. Re-read inventory/progress, test guard denial and other-owner preservation, then
   send the approved completion record through a verified private channel. After
   Clerk deletion, in-app status may return 401; a failed sign-in is not completion
   evidence. Do not delete the guard. The current durable Clerk/Apple/RevenueCat
   workers are described above; do not infer completion from their activation.
   The separate sender below can submit email only after exact scope
   completion and contact/configuration checks; submission is not delivery evidence.

### Partial automation worker

`DELETION_AUTOMATION_ENABLED` is a separate, default-off gate: only the exact value
`true` allows discovery/claims/external dispatch. It does not enable intake, grant
retention approval, or turn on paid Gemini generation. File deletion is cleanup and
does not depend on `GEMINI_BILLABLE_ENABLED`. Disabling automation stops new claims,
not an external DELETE already submitted; its response may still be recorded.
Expired claims can become uncertainty/retry while disabled, but no new external
action is dispatched until enabled. Intake, owner guards and the legacy manual
route remain independent. No environment values were read or changed for testing.

When enabled, the final local-cleanup batch schedules `deletionAutomation:start`.
That freezes one stage per missing provider and paginates admitted work in batches
of 32. Only **finished** Gemini admissions with an exact file name are eligible;
active work and unknown upload responses are never swept or inferred from age.
Old requests can enter through `deletionAutomation:start({id,owner})` or the existing
exact-owner cleanup retry, under separate operator authority. The cron intentionally
does not scan/adopt every old deletion request or run legacy cleanup without that
entry point. Disabling automation during discovery requires an exact-owner `start`
after re-enabling; existing stage wakeups are recovered automatically.

`deletionStages` stores immutable request, issuer-bound owner, key, kind, target,
configuration reference and optional admitted-work ID. There is no retarget API.
Creation is transactionally unique on `(request,key)`; repeated discovery never
resets targets, configuration, manual decisions or attempt budgets. Remaining
provider stages invoke the same executor boundary but return `adapter_unimplemented`
without network or success stubs. They cannot advance legacy provider booleans.

State transitions are `queued → running → succeeded | retry | blocked | exhausted`;
an operator reconciliation changes the stage to `manual` and increments its fence.
Claim commits a 90-second lease, monotonically increasing fence, attempt count and
scheduled watchdog atomically. A completion must match the exact owner, target,
config and unexpired fence; otherwise it does nothing. Work ownership/binding is
checked before dispatch and again before applying a result. Every external request
has a 20-second fetch/body-read timeout. Abort/lease expiry is **unknown outcome**,
not successful deletion or proof Google stopped processing.

Retries have a shared maximum of eight claims (including abandoned claims), a
30-second exponential base with 0–50% jitter capped at six hours, and respect longer
valid `Retry-After` seconds or HTTP dates. Delays are rounded up to integer
milliseconds to prevent a timer firing before a fractional due timestamp. Scheduling
is persisted through mutations, not sleeps. A one-minute cron backs up committed
watchdogs/wakeups, taking at most 16 due stages in each of queued/retry/running.
It schedules actions or lease reconciliation; concurrent dispatch still requires
the single transactional claim. Neither repeated intake nor recovery resets an
exhausted budget. These are technical defaults, not a fulfillment SLA.

`deletionAutomation:resume({id,owner,stage,fence})` can explicitly retry a blocked
Gemini file stage after its prerequisite is fixed, preserving exact target/config
and attempts. It cannot resume manual/exhausted stages, change project binding, or
activate missing provider adapters. Exhausted/legacy-unknown work needs reviewed
operator evidence, not a database edit to restart a budget. Admin access remains
trusted: direct table edits/false evidence can defeat these guarantees.

### Exact-known Gemini contract and limits

New Gemini work snapshots `GEMINI_DELETION_PROJECT_REF` when admitted, independently
of the automation gate. This is a nonsecret, operator-verified configuration binding
(`[A-Za-z0-9_-]`, 1–100 characters) identifying the Google project/credential routing.
It is **not** proof of the project's identity derived from an API key. Before any
future activation, an operator must verify the key's project and bind it to this
reference. Never repoint the same reference to a different project. Same-project
key rotation can preserve it; project changes require a new reviewed route. The
worker will not silently adopt that new route for previously frozen targets.
Legacy work lacking this binding remains blocked even if an environment reference
is later set. No raw key or key fingerprint is stored in ledger/scheduler arguments.

The adapter only calls `DELETE https://generativelanguage.googleapis.com/v1beta/`
plus the frozen `files/[A-Za-z0-9_-]+` name, using `x-goog-api-key` from the server
environment, no body, and redirects rejected. Missing key, mismatched/missing
configuration, invalid target and permanent response errors block without fabricated
success. `200` with exactly an empty JSON object records `deleted`. Exact-resource
`404` with structured `error.code=404` and `error.status=NOT_FOUND` records `absent`
under the verified project-binding invariant; an HTML/proxy 404 is not proof.
The adapter deliberately rejects undocumented success shapes (including 204) for
review. Response parsing is capped at 16 KiB. `408`, `429`, transient `5xx` (except
501), and transport/timeout ambiguity consume bounded retries. Other errors and
malformed bodies become blocked exceptions. Only status and allowlisted categories
are retained, never raw provider errors, tokens, audio or generation text.

New Gemini/chat admissions have `knowledgeVersion:1` and independent durable
`generationStarted`/`generationFinished` fields. The started intent commits before
generation; finished acknowledgement commits after the response. Gemini lifecycle
hooks are awaited. A crash between intent and call remains conservatively unknown.
File cleanup can set `fileDeleted` independently, but removes a work entry only
when the action has finished and versioned knowledge proves generation either did
not start or returned. A deleted file with interrupted generation stays pending.
Old combined ambiguity is never upgraded to new knowledge. Unknown uploads and
active/legacy work remain manual exceptions, including missing response/persistence
windows. No automatic generation retry or shared-project file listing is added.
`store:false`, file expiry, and file absence do not prove log/backup erasure.

### Progress and notification intent, not delivery

Public `GET/POST /account/deletion` retains its routes. The local Google extension
adds optional `googleStatus` without replacing broad provider-completion fields.
`deletionAutomation:inventory({id,owner,cursor})` exposes paginated internal stages
and an outbox snapshot. Classification is `queued` while discovery or scheduled
work is pending, `exceptions` for blocked/exhausted/unresolved scope, and
`scope_complete` only when local cleanup, all five provider/residual attestations
and reconciled execution evidence are complete, including required Google proof.
A successful known-file stage alone never sets `gemini`
or `providersComplete`. Read the legacy inventory alongside automation inventory
for unknown work and a current `automationRevision` before manual changes.

There is exactly one provider-neutral `deletionOutbox` **intent** per request,
transactionally updated with monotonically increasing request revision, current
classification, local/provider completion and `delivery:not_configured`. A queued
or exception intent is not a completion notification. It has no recipient/payload,
sender or delivered/sent transition. Its historical `delivery:not_configured` field
remains unchanged for compatibility; it describes this provider-neutral intent,
not the separate `deletionSends` record below. Read notification inventory for
actual submission/pending state. The mutable intent is never itself sent.

Remaining live dependencies include RevenueCat recreation checks, applicable
Google/Apple grant handling and automatic contact/send verification. Credentials
and activation observations belong in [CONFIGURATION.md](CONFIGURATION.md), not
this contract. The v2 RevenueCat route replaces the planned v1 deletion route;
v1 GET is not used for absence verification. The [runbook](legal/DELETION_RUNBOOK.md)
separates scoped case work from broad backup/log/privacy work and records the
approved timing disclosure. Nothing here removes the owner guard or proves full automation.

Offline verification uses mocked fetch exclusively and scheduler-driven fixtures:
default-off/missing-secret behavior, pagination, retries/exhaustion, lost workers,
concurrent claims, stale/manual/config/owner conflicts, exact-file absence versus
generation uncertainty, old rows, and unique intent truth. Deployment cron timing,
real provider response compatibility, actual deletes and notifications are not
proved by those fixtures. Separate dated live results remain in STATUS.
Sources read 2026-09-23:
[Convex scheduling](https://docs.convex.dev/scheduling/scheduled-functions),
[Gemini Files](https://ai.google.dev/api/files),
[RevenueCat v1](https://www.revenuecat.com/docs/api-v1/customers).

Backup restores require a separately approved maintenance procedure: retain/replay
the current suppression ledger **before reopening access**, then rerun exact-owner
cleanup. Restoring a backup that drops the ledger defeats the guard. Offline tests
cover restored synthetic rows with a retained guard, not real backup restoration.
Likewise, old JWTs are blocked by the application guard, not cryptographically
revoked here. Live Clerk/Apple revocation, RevenueCat SDK behavior on other devices,
legacy in-flight actions from an older deployment, and provider residual retention
remain unverified; drain/verify old actions before intake activation.

Primary references checked 2026-09-23: [Convex storage metadata](https://docs.convex.dev/file-storage/file-metadata)
and [deletion](https://docs.convex.dev/file-storage/delete-files),
[Gemini Files](https://ai.google.dev/api/files),
[Clerk user management](https://clerk.com/docs/guides/users/managing),
[RevenueCat customer deletion](https://www.revenuecat.com/docs/dashboard-and-metrics/customer-profile#delete-customer),
and [Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/).
Public capability documentation is not verification of these deployments/settings.
Accepted disclosure/runbook input remains in `docs/legal/`; this candidate does not
edit or supersede its historical base-characterization results.

### Frozen completion notification

The fixed sender is `notifications@lessmeet.2m0r.com`. Production credential
provisioning was recorded Oct3. A manual status email has recipient-reported
receipt; this does not verify automatic contact capture or outbox delivery.
Do not read credentials for tests. Direct REST uses the existing runtime.
The public deletion response and routes are unchanged; no public contact setter,
arbitrary-recipient endpoint or webhook endpoint is added.

Oct4 local candidate separates collection from sending. Contact capture requires
`CLERK_CONTACT_INVENTORY_ENABLED=true` and `DELETION_CONTACT_RETENTION_APPROVED=true`.
It works with `DELETION_EMAIL_ENABLED=false`. Automatic submission still requires
`DELETION_EMAIL_ENABLED=true` plus the contact-retention gate and all existing
completion/configuration checks. Missing/false values fail closed. Activation is
not send permission. No production gate was changed for this candidate.

Human approved normal scoped fulfillment within7 calendar days of receipt, with
email updates/results and exception status/reason/next-update date. This does not
alter broad completion flags or the90-day purge clock. Contact/send rows are
personal data after identity deletion and follow the existing broad-ledger purge;
pending retention and general provider privacy are #4 limits. No new retention
period or all-copies-erased/legal claim is inferred.

#### Exact-user contact inventory and wire version

Optional `CLERK_CONTACT_INVENTORY_ENABLED=true` allows only authenticated server
GETs to `https://api.clerk.com/v1/instance` (credential-instance check) and then
`https://api.clerk.com/v1/users/{exactSubject}`. There are no user lists, sessions,
OAuth-token reads or destructive Clerk/Apple/RevenueCat adapters. No JWT/client
email is trusted, and secondary addresses are never fallback recipients.

Every Clerk read sends `Clerk-API-Version: 2026-05-12` and server-only
`CLERK_CONTACT_SECRET_KEY` as the Bearer credential. The selected current REST
schema is not the earlier 2021 schema or a camelCase SDK wrapper. Expected bodies:
instance object with `object:instance` and exact `id`; user object with
`object:user`, exact `id`, `primary_email_address_id`, and `email_addresses` array;
one matching email object with `object:email_address`, `email_address`, and
`verification.status:verified`. Missing/wrapped/malformed/ambiguous shapes fail
closed. The entire two-read operation is bounded to 20 seconds, each JSON body to
64 KiB, redirects rejected, and error bodies never persisted/logged.

Configuration prerequisites, set only by a separately authorized operator:

- `CLERK_CONTACT_ISSUER` must exactly equal `CLERK_JWT_ISSUER_DOMAIN` (HTTPS origin,
  no trailing slash), and the accepted owner must exactly equal `issuer|subject`.
- `CLERK_CONTACT_INSTANCE_ID` must be the verified `ins_...` instance for that
  issuer. The GET instance ID must match before reading the exact `user_...` subject.
  The issuer-to-instance association is an operator attestation; GET instance
  validates credential routing, not that attestation's truth. Do not repoint it.
- Provision an authorized server credential to `CLERK_CONTACT_SECRET_KEY` only
  after approving this read scope. None was read or provisioned here.

Intake schedules one capture independently of deletion cleanup. Apple revocation
does not wait for contact lookup. The Oct4 local Clerk candidate requires a durable
bound verified non-relay contact at new adoption and before destructive effects.
Historical observation/reconciliation remains possible without manufacturing one.
Only address,
exact owner/subject/issuer/instance, captured time and allowlisted outcome are saved
to `deletionContacts`; the full response/metadata/other addresses never are. A
successful captured recipient is immutable, including concurrent/repeated captures.
Failed capture can be explicitly retried while the identity still exists using the
internal exact-owner action; no unbounded automatic contact retries. A disappearing
identity leaves an exception, not permission to guess a destination.

Apple private-relay primary addresses yield `contact_relay_exception` without
retaining/sending the address. A non-relay secondary is not silently substituted.
Unknown relay forwarding after revocation is not delivery. This never delays or
reverses Apple revocation; ambiguous Apple revocation remains an operator exception.

#### Frozen send and retry contract

When sending is enabled, `publishIntent` schedules an exact-owner freeze check;
successful contact capture also schedules it, so either ordering works. Freeze requires current discovery and
stage classification `scope_complete`, no remaining owner work, exact intent
revision, and all six independent flags true: `localComplete`, `clerk`, `apple`,
`revenuecat`, `gemini`, `residuals`. No provider flag is written by email code.
Queued/blocked providers or only a local/Gemini-file success cannot produce mail.

One `deletionSends` row per request is transactionally created with immutable
request/owner/subject, source intent ID/revision, six completion flags, contact ID,
recipient, route reference, serialized payload and `lessmeet-deletion/{id}/completion-v1`
idempotency key. Sender and minimal, scope-qualified text are frozen in that JSON;
no recording/account content, template expansion, attachments or tracking fields.
Only state/attempt/fence/timing/provider-acceptance fields subsequently change.
Existing sends are never replaced by a newer intent or recipient. A changed
intent revision/configuration/contact/completion condition blocks submission or
retry as an exception, even if the new intent again says complete.

`RESEND_DELETION_CONFIG_REF` is a required immutable operator-attested route
reference (1–100 letters/digits/underscore/hyphen), binding the intended Resend
team/domain/credential route to this sender. `RESEND_API_KEY` stays server-only.
Never repoint a reference to a different team/domain; same-route key rotation
does not change the frozen payload/key. A wrong same-reference secret cannot be
independently identified using a sending-only credential; operator binding is
a release prerequisite, not established by these tests.

Transactional claims establish a first-attempt timestamp **before** HTTP and commit
a 90-second lease/watchdog. That timestamp never resets after ambiguity, pause or
restart. Up to eight claims (including abandoned claims) are allowed. A one-minute
cron recovers at most 32 due rows in each of queued/retry/running states per run.
Duplicate scheduled jobs cannot claim an active lease; stale/expired results cannot
overwrite a newer fence. No database-edit/budget-reset/resend escape hatch is added.

The adapter POSTs exactly the frozen JSON to `https://api.resend.com/emails` with
Bearer auth and `Idempotency-Key`, no redirects, and a 20-second fetch/body timeout.
`200` with an ID records `state:pending`, `delivery:pending` and sanitized provider
ID—**not delivery**. `408`, `429`, `5xx`, transport/malformed-success ambiguity and
`409 concurrent_idempotent_requests` retry the same bytes/key. Other 409s and
rejections are exceptions. Backoff starts at 30 seconds, doubles up to six hours,
and honors longer numeric/date Retry-After. Before a retry, the full 90-second
lease must fit strictly inside the 24-hour window from first claim; the adapter
also checks its 20-second operation fits both lease and window immediately before
POST. A longer Retry-After, elapsed window or exhausted budget is an exception,
never a new key. Queue delay before first claim consumes no deduplication window.
This is a conservative client dispatch bound, not proof of remote cancellation or
network timing; abort cannot retract a request already submitted.

Revoking completion while a POST is already in flight cannot unsend it. Its result
becomes an exception while retaining any provider acceptance ID; no further
automatic sends occur. A paused gate is not cancellation. Restore/fork/deployment
migrations must preserve send/contact records and original timestamps, and keep
email disabled until Lead reviews duplicate-send risks—never restart from an old
backup or clear the send row to create a new notification.

#### Delivery remains explicitly pending

There is intentionally no delivered transition, remote readback or authenticated
webhook implementation in this candidate. Accepted and exhausted/ambiguous sends
retain `delivery:pending`; operator follow-up is required. An accepted send is
terminal for automatic submission and will not be resent after 24 hours. The
sending-only key cannot be assumed to provide delivery lookup. Resend distinguishes
API success (`email.sent`) from recipient-mail-server acceptance (`email.delivered`),
which still is not proof that a person read the email. Future webhook work must
verify the raw body/signature/timestamp and handle replay, exact-message binding,
duplicate/out-of-order events and bounce/failure outcomes before exposing delivery.
Adding a verification dependency or public endpoint requires Lead's scope decision.

Internal operator inspection/recovery (not authorization to invoke live):

The narrowed #3 manual email path uses `manualDeletionEmailDraft` in
`notificationAdapter.ts`, not the broad `freeze` path. It is a pure helper, with
no handler, recipient or send effect. It adds exactly604800000ms to the recorded
receipt time. Exceptions require a reason and future next-update time. A completion
draft requires explicit trusted-operator acceptance, a private evidence reference,
completed scope and retained/unresolved limits. It does not verify that evidence
or accept the case itself. The operator supplies the immutable verified recipient
separately and obtains exact send authority. Do not copy case evidence or private
IDs into customer text. API submission remains distinct from delivery.

- `deletionNotifications:inventory({id,owner})`: sanitized contact code, completion
  eligibility, availability/configuration gap, submission state and timing. No
  address/payload is returned. Missing contact remains `contact_missing` explicitly.
- `captureContact({id,owner})`: bounded read-only exact-user retry after resolving
  configuration/contact failure, only while identity remains accessible. Capture
  does not require the send gate in the Oct4 local candidate.
- `freeze({id,owner})`: reevaluate an unsent request after contact/configuration is
  made ready. Does not recreate or rearm a send; old intents need accepted automation
  discovery/start first. There is no bulk adoption of legacy requests.
- `recover({})`: bounded due-send recovery, also registered as cron. It cannot
  resume pending/exception rows, extend deduplication or fix missing contacts.

`contactTarget`, `saveContact`, `claim`, `finish` and `dispatch` are internal worker
plumbing, not operator evidence setters or public APIs. Trusted admins/table edits
can defeat their invariants; do not forge contact results, clear records or rearm
exceptions. Scheduler arguments carry only IDs/owner, never keys or frozen payload.

Official sources checked 2026-09-24:
[Resend send REST](https://resend.com/docs/api-reference/emails/send-email),
[24-hour idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys),
[delivery events](https://resend.com/docs/webhooks/event-types),
[webhook authentication](https://resend.com/docs/webhooks/verify-webhooks-requests),
[Clerk version selection](https://clerk.com/docs/guides/development/upgrading/versioning),
[Clerk 2026-05-12 REST schema](https://raw.githubusercontent.com/clerk/openapi-specs/main/bapi/2026-05-12.yml).
Schema bytes inspected had SHA-256
`4c42713b9fc0d68a5f5263286fb6c87bab6320d74be261acb8a77bc1ad26d2bd`.
Offline fixtures establish request/state behavior only. Live Clerk/key/issuer
binding, Resend compatibility, delivery, cron timing and full deletion readiness
remain unverified. Existing identity/provider exceptions remain release blockers.

### Read-only provider preflight

This is a separate inventory sidecar of the accepted automation worker, not a
destructive provider adapter. `deletionAutomation.start` schedules it when enabled;
an internal exact-owner start can adopt an already initialized automation request.
It does not change the public/native API, `deletionStages`, any provider completion
flag, manual evidence, outbox classification, verified contact, or frozen send.
Existing unimplemented-provider exceptions remain authoritative. No OAuth token
read, session revoke/ban, user/subscriber DELETE, Apple call, or v1 RC GET exists
in this lane. All transport methods are GET on constructed fixed-origin routes.

#### Gates and immutable configuration

All three must explicitly be `true`: `DELETION_AUTOMATION_ENABLED`,
`DELETION_PREFLIGHT_ENABLED`, and `DELETION_PREFLIGHT_RETENTION_APPROVED`.
The last gate is a release/operator assertion, not a retention policy invented by
this implementation. Provider/external-account/session/alias identifiers are
personal data. Human approved the bounded preflight policy below on Sep 24; this
does not approve the main deletion ledger, contacts/sends, backups, destructive
provider activation or remaining RC recreation risk. The three activation gates
remain absent from audited dev configuration.

Each active preflight row has an inactivity deadline 30 days after its latest
accepted state transition. Claims, committed pages, retries, lease expiry and
terminal findings refresh that deadline; reads do not. A daily cron compacts at
most 16 expired rows per transaction even when all feature gates are off. It writes
one immutable minimal receipt containing only request reference, provider,
state/finding code, inventory-complete bit and lifecycle timestamps, then deletes
the row containing owner/subject duplicates, frozen config, cursors, external
account IDs, session IDs/statuses and RevenueCat aliases. The receipt prevents a
repeated start from recreating the frozen snapshot. Legacy rows without a deadline
are boundedly backfilled from their last update timestamp or compacted immediately
when already expired. No receipt contains provider identifiers, email, token,
credential, raw body or error prose. This candidate is deployed to dev
`zany-octopus-315`; schema migration and a no-op purge were verified with empty
preflight tables. It has not been rehearsed through a live synthetic deletion
request because the deletion-ledger policy was not approved at that checkpoint.
The later 90-day approval and bounded rehearsal resolve the ledger/intake-policy
dependency, but do not enable preflight, automation, contact capture, sends or
destructive provider calls.

Clerk reuses the accepted `contactBinding()` and `CLERK_API_VERSION` contracts:
`CLERK_JWT_ISSUER_DOMAIN`, equal `CLERK_CONTACT_ISSUER`, exact
`CLERK_CONTACT_INSTANCE_ID`, and server-only `CLERK_CONTACT_SECRET_KEY`.
Add nonsecret `CLERK_PREFLIGHT_CONFIG_REF` as an immutable credential/configuration
revision reference (1–100 ASCII letters/digits/underscore/hyphen). Issuer-instance
association is operator-attested; every page action GETs `/v1/instance` to check
the credential's instance before reading user/session data. Neither this preflight
nor its retention gate enables email/contact capture, or modifies captured contact.

RevenueCat uses separate `REVENUECAT_PREFLIGHT_SECRET_KEY` with v2
`customer_information:customers:read` permission, never the v1 billing credential.
Supply nonsecret `REVENUECAT_PREFLIGHT_CONFIG_REF`, exact
`REVENUECAT_PREFLIGHT_PROJECT_ID` (`proj...`), and
`REVENUECAT_PREFLIGHT_PROJECT_VERIFIED=true` only after operator verification of
credential/project/issuer mapping. The accepted application maps the exact Clerk
subject to the RC App User ID; there is no email search, global list or alternate-ID
guessing. The customer response's `project_id` must match. Attestation is still
necessary: a missing resource cannot independently establish the key's project.

The frozen canonical configuration includes revision, issuer, instance, wire
version and (RC only) project. Never repoint a revision to another credential's
scope. Secret rotation preserving scope requires operator review; the code does
not fingerprint secrets. Every claim, pre-dispatch authorization, subsequent GET,
and result commit checks current gates/configuration. Request ID, owner, subject
and original request timestamp are bound. Existing immutable rows are not reset
or repointed by repeated starts; no rearm/new-snapshot operation is supplied here.
Missing configuration freezes a blocked exception, not a future automatic target.

#### Wire contracts and bounded observations

Clerk requests pin `Clerk-API-Version: 2026-05-12`. The inspected official schema
digest is the same `4c42713b9fc0d68a5f5263286fb6c87bab6320d74be261acb8a77bc1ad26d2bd`
recorded above, not the old 2021 research schema. User GET returns a `user` with
the exact subject and an `external_accounts` array. Store only each external ID,
provider and provider user ID (maximum 128), not names, email, metadata or tokens.
Clerk `Session.List` in this version is a REST array, not the SDK's
`{data,totalCount}` wrapper. Session pages use
`GET /v1/sessions?user_id={subject}&limit=32&offset={offset}` with **no status
filter**, validate each `user_id`, and store only session ID and allowlisted status.
A short page ends traversal; a full page schedules the next offset. No operation
mutates the enumerated list. Duplicate IDs across pages block as changed inventory.
Concurrent provider changes can still evade detection; this is neither an atomic
snapshot nor a historical/all-session completeness guarantee. Clerk documents
that old/inactive sessions are periodically removed from list results.

RevenueCat first GETs `/v2/projects/{project}/customers/{subject}` and validates
customer/project identity, then GETs the same customer's `/aliases?limit=32`,
following `starting_after` only. The response must be a `list`, its `url` the exact
alias route, and every item a `customer.alias`. `next_page:null` ends traversal.
Non-null continuations must be relative, same-project/same-customer/same-alias
route, with one nonempty `starting_after` and optional `limit=32`; unknown/duplicate
query keys, fragments, absolute URLs and route escapes block. The cursor must
equal the last returned alias and must not repeat. The worker reconstructs the
URL; it never fetches a response-supplied URL. Aliases are deduplicated across
pages and conflicts block instead of being silently merged. Every alias other
than the exact subject, including anonymous IDs, is unexplained ownership here:
even a fully traversed list ends `blocked:alias_ownership_unverified`.

Clerk and RC each have a unique `deletionPreflights` row per request. Separate
phases persist user → sessions and customer → aliases; one page per leased action,
with at most two HTTP reads (Clerk instance plus page). Limits: 8 list pages,
256 accumulated items, 64 total claims per provider, 8 attempts per phase/page,
90-second fenced leases, 20-second action transport/body deadline and 64-KiB JSON
bodies. A full eighth session page without proof of termination is blocked; the
worker does not make an unbounded ninth request to establish absence. Page-limit
failures keep previously committed partial pages, not a completion assertion.

Only identifiers/statuses/cursors and allowlisted finding codes persist. Error
prose, full bodies, email, network metadata, credentials and tokens do not.
Redirects are rejected. Transport uncertainty, 408/423/429/5xx use the accepted
worker's bounded backoff policy (30-second base, 6-hour cap before provider hints),
honoring longer valid `Retry-After` and RC `backoff_ms`. Permanent rejections,
malformed payloads, binding conflicts and unsafe pagination block. Structured
Clerk `resource_not_found` / RC `resource_missing` 404 on exact user/customer/alias
reads means `resource_absent_inventory_unavailable`, **not** deletion completion,
Apple non-applicability or proof about unknown aliases. Generic 404 is malformed.

`inventoryComplete:true` means only that this bounded traversal terminated.
`observed` is not deleted, authorized-to-delete, globally quiescent or a clearance
of prerequisites outside this inventory. Linked Apple accounts always leave
`blocked:apple_provenance_unverified`: this lane has no original-client provenance
setter and reads no token. No currently observed Apple link does not establish
historical non-applicability. Missing identity/provenance must still be reconciled
before Apple disposition/Clerk deletion. The accepted Apple ambiguity rule remains
operator exception with no new raw-token persistence. Notifications never delay
revocation. None of these observations establishes all-device SDK quiescence,
permanent RC non-recreation, subscription cancellation, or removal of logs/backups.

#### Internal entry points and recovery

All are internal/server-only, not new public/native endpoints:

- `deletionPreflight.start({id,owner})`: idempotent exact-request adoption, only
  after accepted automation initialization; creates immutable Clerk/RC targets.
- `inventory({id,owner})`: at most two exact-request observations, including
  partial lists and explicit state/code. These contain personal identifiers and
  must not be exposed as public status or logged wholesale.
- `recover({})`: at most 16 due rows per queued/retry/running state; registered
  every minute alongside accepted worker/notification recovery. No global adoption
  or rearming of terminal rows. Disabled queued work resumes with its same frozen
  state when explicitly re-enabled and recovered. A disabled/config-changed result
  in flight is blocked rather than committed as an observation.
- `claim`, `authorized`, `finish`, `expire`, `run`: worker plumbing. Claim and
  watchdog commit transactionally; persisted wakeups and cron cover worker loss.
  Expired leases advance fences and retry/exhaust; they never imply success. Late
  results cannot overwrite a replacement claim. Scheduler args carry IDs/fences,
  never secrets or raw provider payloads. Internal DB/admin access remains trusted.

No operator should forge findings or mutate frozen rows. Changing config, refreshing
an old observation, accepting alias ownership or enabling destructive work needs
a separately reviewed next lane. Already-issued GETs cannot be recalled by a local
fence; stale results are discarded/blocked at commit, not treated as cancelled
provider activity. The separate provider stages and flags retain their existing
manual/unimplemented semantics; preflight deliberately cannot clear them.

Sources for this implementation: the pinned Clerk REST schema above and
[RevenueCat v2 customer/alias REST](https://www.revenuecat.com/docs/api-v2/customer).
Offline fixtures cover wire parsing, forbidden-route/method absence, config/owner
changes, pagination boundaries/conflicts, leases, bounded retries/cron and zero
provider completion or frozen-sender mutation. Live compatibility, secret-to-account
attestations, deployed scheduling and provider activation remain unverified.
