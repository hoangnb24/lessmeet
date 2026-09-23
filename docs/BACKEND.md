# Gemini backend contract

Development endpoint: `https://zany-octopus-315.convex.site`.
Implementation and deployment acceptance are tracked in [STATUS.md](STATUS.md).

**Current policy: all authenticated users may use owner-funded Gemini, without
aggregate quotas for now.** The owner explicitly accepted indefinite retention of
audio, transcripts and chat. Development is enabled with
`GEMINI_BILLABLE_ENABLED=true`. The switch remains reversible: false/missing blocks
uploads/chat and provider entry points while preserving authenticated reads.
Technical request/storage limits below remain. Paid agent tests and production
rollout remain separate from this development configuration approval.

Every request sends `Authorization: Bearer <Clerk session token>`. The server
validates Clerk's issuer and `aud: convex`. Never send a Gemini key from Swift.
The application does not accept a client-supplied owner or storage ID.

## Upload and transcription

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
Supported MIME types include `audio/m4a`, `audio/mp4`, `audio/mpeg`, `audio/mp3`,
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

Billing enforcement is implemented locally behind an opt-in switch; the current
development deployment is not changed by local code. Authentication and
per-record ownership remain required. Production rollout is separate.
No audio, transcripts, tokens or provider error bodies should appear in logs.

Bounds: 384 KiB serialized transcript, 8 KiB question, 32 KiB serialized reply,
128 KiB saved history and 20 exchanges. Oversize/incomplete model responses are
rejected rather than saved partially. Jobs expire after five minutes; abandoned
chat reservations expire after two minutes. There is no automatic retry.

Convex keeps uploaded audio, transcripts and messages indefinitely in this version;
there is no deletion UI or retention scheduler yet. Temporary Google Files are
deleted after transcription on success or failure when their ID is known. Cleanup
failure is surfaced; an ambiguous upload failure before Google returns a file ID
cannot be cleaned up explicitly. Google-side expiry is not immediate deletion.

## Acceptance

Before deployment, verify unauthenticated requests fail, a second user cannot
read or chat with the first user's recording, and the owner can complete the
upload/transcript/chat path using a mocked provider. Live audio/API testing is
not part of these offline checks. Swift cloud buttons are integrated and verified
with URLProtocol fixtures; real OAuth/upload/model behavior remains unverified.

```sh
npm run typecheck:backend
npm run test:backend
```

Tests use fake identities, synthetic bytes and mocked Gemini transport. They do
not read deployment secrets or incur Gemini charges.

## Subscription integration (local; rollout pending)

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
- Verify sandbox purchase, restore, cancellation, renewal, account-switch and
  server reconciliation in the properly signed Mac App Store app. Current local
  packaging is ad hoc, not store distribution acceptance. Confirm resource loading.
- Confirm actual audio parsing and measure AI/storage/transfer cost before public
  activation. Enforced uploads are non-fragmented AAC-LC M4A only, still max
  18 MiB. Sample-table validation is not a full audio decode; malicious payload
  resistance, parser CPU/memory amplification and long-recording duration/size
  remain rollout concerns. Sample expansion is bounded but not exhaustively
  fuzzed. AAC padding plus per-upload rounding can add a second to the charge.
  The actual native synthetic 1.25s source/export compatibility fixture passes
  backend validation and reserves/charges 2 seconds only on saved success.

No live deployment, key sharing, store purchase or production switch change is
included in offline implementation acceptance.
