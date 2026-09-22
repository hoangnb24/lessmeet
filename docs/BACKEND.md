# Gemini backend contract

Development endpoint: `https://zany-octopus-315.convex.site`.
Implementation and deployment acceptance are tracked in [STATUS.md](STATUS.md).

**Current state: billable access paused.** Development has
`GEMINI_BILLABLE_ENABLED=false`. Both POST routes return503 before reading uploads
or invoking Gemini, regardless of JWT. Background/provider entry points also fail
closed; absent configuration is disabled. Read-only authenticated routes still work.
Do not enable until the owner accepts cost/retention limits and enforcement is
verified. The endpoint descriptions below document the fixture-tested enabled
contract, not permission for live paid testing. No retention proposal is accepted.

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

The development implementation is not a billing or quota system. Authentication
and per-record ownership are required, not substitutes for spending limits when
opening the product to a wider audience. Production rollout remains separate.
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
not part of these offline checks. The Swift cloud buttons are a separate
integration step; backend acceptance does not mean the full UI flow is complete.

```sh
npm run typecheck:backend
npm run test:backend
```

Tests use fake identities, synthetic bytes and mocked Gemini transport. They do
not read deployment secrets or incur Gemini charges.
