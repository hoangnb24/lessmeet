# Durable batch chat backend corrected candidate — 2026-09-25

Returned to Lead for technical acceptance; not self-accepted. Backend write
ownership relinquished at handoff. Offline implementation is complete; no essential
workflow branch is intentionally left as a disconnected stub.

## Terminal-status correction — supersedes reopened candidate

Lead reopened prior handoff
`c050d68c2ef302cead829dc7be9743ca6aa732e25b98f607b28ee5367dd5f496`.
The read-only review in /tmp/lessmeet-chat-review.BiJJUS/RESULTS.md reproduced
premature release for in_progress and requires_action. This correction changes
only the four paths below plus this handoff. The other twelve manifest paths still
match the frozen candidate. No public wire or lifecycle schema change was needed.

Installed @ai-sdk/google 4.0.76 dist/index.js was inspected locally:
- lines 5050–5070 map provider statuses to lossy unified finish reasons;
- lines 6069–6076 enumerate the six accepted statuses;
- lines 6841–6843 explicitly define terminal statuses as completed, failed,
  cancelled, incomplete;
- doGenerate around lines 7693–7724 polls nonterminal states only for agents and
  copies response.status directly into finishReason.raw.
Installed ai 7.0.109 dist/index.js line 6653 preserves that raw field as
rawFinishReason; lines 6871–6872 expose it on the final result.

The batch-only adapter now returns that explicit provider status; the worker
recognizes only the four terminal statuses above as proven remote termination.
It publishes text only for explicit completed plus unified stop and valid bounded
reply. Nonterminal, missing or unrecognized status remains unknown with intent,
deletionWork, quota and exclusion held. Unified stop alone is insufficient.
Unknown/missing status currently fails installed SDK validation and follows the
same conservative post-intent unknown path; direct worker tests additionally
cover unexpected mapped statuses. Legacy provider functions are unchanged.

Executed red tests BEFORE the production fix: focused integration reported
**2 failures / 24 passes**. in_progress and requires_action incorrectly returned
availability ready and pending null instead of attention/unknown/reserved.
Durable regressions now cover those two statuses, missing/future status, replacement
409, quota still reserved after recovery, retained intent/work, late exact-fence
completion accepted and consumed once, and duplicate late completion ignored.
Real-SDK mocks cover all four terminal status shapes: completed valid consumes;
completed empty/oversized, failed, cancelled and incomplete release without
publishing text. Failed receipts allow a new explicit UUID but never regenerate
automatically. Four direct-handler tests verify even unified stop cannot prove
termination for nonterminal/missing/unrecognized status.

Final correction verification (same offline environment/commands below):
both typechecks pass; **658 tests / 21 files pass** (1.43 s); focused chat
**36 tests / 3 files pass** (611 ms); scoped whitespace and all sixteen hashes pass.
No final failed check remains. No external/provider call, install, deploy, native
build, activation or contract change occurred. Live occurrence and production
runtime remain unverified. Lead acceptance is still required.

Installed inspected distribution SHA256:
- @ai-sdk/google/dist/index.js:
  `9034ebcbbd6aabc740593c55094a5e3268ddbbe8b26eb938e51b6ae97b8940f6`
- ai/dist/index.js:
  `292db4c449ea051bfca98a84fe6771bd497d78db929f0a2710b58dbd3f6ed7c8`

Correction before hashes identify the reopened candidate; full current after hashes
and original accepted-base before hashes remain in the complete manifest below.

| Path | Reopened candidate SHA256 |
| --- | --- |
| convex/gemini.ts | 35dd8fe6954535a2fb33812f744d473a49896f33c1e4015fe9dc606de067e6ac |
| convex/batchChatJobs.ts | b30264c9d8ac5404af199a3a09ab8baa02657b9bfdffd6251200963810da82dc |
| Tests/backend/batchChat.test.ts | 3fc3e4e2b98766834e09ef78783af04efc111079e9f8d4b7799d5a7a23b878a5 |
| Tests/backend/batchChatJobs.test.ts | 39aa1ed7b70b80a05edd792cd9172a29f208efc13851458f6ce6c1e443436fee |

## Identity and boundaries

Base HEAD: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`, plus accepted dirty backend
handoff `850994e592cc94fae934b33a3ba9b4266eccf88377301184343f84e743ec2074`.
Native input was Lead-accepted `01f5dd0…`; this writer did not build or verify native.

The complete contract was read at dispatch SHA
`4377b494a7f4e7a32b2775b74db9c2acb2ce6279d2c150e7e550ffca6d245aa4`.
Lead subsequently resolved revision semantics in STATUS and the contract; the
complete updated contract was read at SHA
`4e2f52c7e2d21937c59a538db28356542f39ca6fc9bd56465598744468c51869`.
Implemented that clarification: ChatStatus revision starts zero and advances only
with a successfully saved exchange (equals exchange count). Each operation starts
at revision one, advances independently on observable changes, and never advances
on identical replay. Failure/unknown/admission do not change history revision.
No wire fields, geometry, native files, fixtures, docs, scripts, root dependencies,
or settings were changed by this writer.

Only the 16 paths in the manifest below plus this new handoff were written.
The existing BACKEND_HANDOFF remains byte-for-byte at the accepted SHA above.
Shared-worktree native/STATUS activity belongs to its existing owners.

## Implemented integration

Actual authenticated GET chat, POST chat/message and GET chat/message routes under
`/v1/transcription-batches` implement frozen DTOs/statuses and strict bounded JSON.
Exact owner+batch+message UUID and all submitted fields resolve before billing;
terminal exact replay returns 200, new/unresolved 202, conflicting identity 409.
Atomic admission binds context/history, reserves one question, persists the receipt,
and schedules work. One unresolved operation excludes new questions for its batch;
it does not use transcription's two slots or create a global chat inventory.

Complete aggregate and every selected successful raw are required. Context includes
ALL raw segments, including duplicated overlap and untimed alternatives, within
384 KiB; no truncation, summary, or deduplication. Digest hashes unchanged UTF8 raw
bytes in the frozen ordered fixed array. Context snapshots are separate documents;
receipts keep their exact request identity separately from the bounded prompt
history. Message, reply, history and response limits are enforced before publication;
space for a whole next exchange is reserved before admission.

The real pinned SDK adapter receives full context and full history, current model,
store:false, maxRetries:0, 8192 output tokens and a 90-second local wait bound.
A transaction claims execution once; fresh billing compatibility, deletion guards,
and an exact fenced deletionWork intent precede generation. Thrown SDK errors after
intent are unknown, not the legacy error-as-known shortcut. Valid known completion
atomically appends history and consumes once; known pre-submit/completed-invalid
failure releases once. Unknown holds quota and exclusion indefinitely until late
same-fence completion or exact evidence reconciliation. No automatic generation
retry or replacement endpoint exists. Persistence retries carry only the already
observed result/fence; after two failed writes they schedule settlement, not generation.

Generation requires the exact issuer-bound owner and all three gates:
BATCH_TRANSCRIPTION_ENABLED, BATCH_CHAT_ENABLED, GEMINI_BILLABLE_ENABLED.
None was activated. Existing-owner reads, exact replay, recovery, reconciliation,
and deletion work when generation is off.

## Lifecycle and operational limits

Queued claims have a 120-second preparation observation deadline. Minute recovery
reads at most eight due rows per queued/running state; unclaimed queued work may
be re-delivered through the once-only claim. Expired preparing work fails known;
expired intent becomes unknown, never a timeout refund or new generation.

Deletion drains at most eight content-bearing receipts per pass, then bounded
history/context documents, before batch/quota-bucket deletion. A separate deleted
index keeps an unresolved early operational tombstone from hiding later content.
Questions, replies, prompt/context references and reservations are removed; late
completion cannot recreate content. Operational tombstones retain no prompt text.

Internal `batchChat.reconcile` requires exact operation/owner/fence, private evidence
identifier and remoteStopped:true; it settles without inventing a saved reply.
Existing deletion.reconcileWork exact attestation removes linked chat tombstones.
Retention orphan guards now include chat rows. Existing 30/90-day policies and
paid-background retention behavior are unchanged.

Concurrent identical requests can transiently encounter the existing shared billing
verification conflict while the first admission is in flight; exact identity
recovery/replay then resolves the single saved operation. There is no duplicate
reservation or generation. If settlement writes AND fallback scheduling all fail,
recovery conservatively retains unknown work; it cannot recover lost response text
or automatically regenerate it.

## Original candidate verification and durable evidence (correction totals above)

Environment: /Users/tubakhuym/projects/lessmeet, Darwin arm64, Node v22.22.3,
existing installed locked dependencies. No installs, live fetches, credentials,
paid calls, deploy/login, commits/pushes, activation or native builds.

Executed final commands:

```sh
npm run typecheck:backend
npm run test:backend
./node_modules/.bin/vitest run --config Tests/backend/vitest.config.mts Tests/backend/batchChat.test.ts Tests/backend/batchChatContext.test.ts Tests/backend/batchChatJobs.test.ts
git diff --check -- convex Tests/backend
```

Observed: both backend/test TypeScript configurations pass; full suite **646 tests /
21 files pass** (1.42 s); focused chat **24 tests / 3 files pass** (519 ms);
scoped tracked whitespace check passes. Additional manifest checks include new
untracked paths and verify current hashes. No final failing check remains.

Revision clarification red/green: before correction, the focused integration suite
reported **2 failures / 14 passes** (history incorrectly 3 instead of 1 after success,
and 1 instead of 0 after admission). Those assertions and an independent-operation
transition test now pass. Earlier expanded suite was 641 tests; final suite includes
all 622 accepted baseline tests plus 24 chat tests.

Durable executable evidence:
- batchChat.test.ts: real HTTP -> Convex test storage/transactions/scheduler ->
  actual pinned SDK -> exhaustive fetch mock -> durable history. Synthetic native
  AAC bytes traverse existing create/upload/seal/transcription before chat. Covers
  lost response replay, conflicting payload, cross-issuer refusal, concurrent
  admission, duplicate claim, stale context/history, full follow-up history,
  independent revisions, known invalid/oversized completion, billing-plan change,
  disabled generation, unknown/late result once, exact reconciliation off, deletion
  and no resurrection, multi-page receipt cleanup, quota exhaustion and explicit
  new question after pre-submit expiry.
- batchChatContext.test.ts: unchanged-raw digest/attempt binding, all overlapping
  and untimed segments retained, unavailable raw, aggregate prerequisite, exact
  384 KiB boundary and one byte over, history/reply bounds.
- batchChatJobs.test.ts: direct action-handler persistence-fault injection proves
  one provider invocation across lost settlement acknowledgments and fallback;
  duplicate settlement safety is separately covered by integrated mutations.

Mocks replace all network routes and reject unknown URLs. Fault-injection handler
tests do not claim deployed network/database fault reproduction. No acoustic,
decoder, provider-quality or native UI/disk/reopen evidence is claimed.

## Preserved baseline and remaining acceptance limits

Node SHA256 verification matched all ten untouched accepted manifest paths exactly.
For the eight additive integration paths, removing only chat additions reproduces
their accepted before hashes exactly. Legacy transcription/chat/media/billing
bodies are therefore preserved, not just covered by passing tests.
Accepted chunkResults:
`2ed80c8e98374d09ab7e70fc2a44b9d365701ab2215942e3532657bdf7232d27`.
Accepted Clerk transport:
`39d3c407880a07aaf5aa931eff3def914895a15f88312161d9105cfcb6c23d74`.

Lead technical acceptance remains required. Native chat acceptance belongs to Lead/H.
Real Convex runtime/resource limits, real SDK/network failure behavior, provider
answer quality, full server AAC decoding, live 120-minute quality, signing/TestFlight,
and Human structural-only activation approval remain unverified/pending. Crypto
digest and transactional resource behavior were exercised in convex-test, not a
deployed Convex runtime. No guarantee every 120-minute transcript fits chat context.
Default-off/public-release gates are not waived.

## Complete before/after SHA256 manifest

Before hashes are the accepted dirty baseline, not HEAD. null means absent at
dispatch. This new handoff is the only additional changed path; its hash is supplied
separately to avoid self-reference.

```json
[
  {
    "path": "convex/_generated/api.d.ts",
    "before": "5513ae5610b413e45675b8c7b244ccc13a1726ca78f9c0686be9c14b2333a9fe",
    "after": "61c48fdf4bce0e67f3983198a65b05265830b55a6861998bc15504ac38abb7e0"
  },
  {
    "path": "convex/crons.ts",
    "before": "f599294a367b37543c85980a7cf166faf34f8bcc3830a3e0c1e308bbdf4506b2",
    "after": "42010f4ce6592adfc730ffb2dceb1e693ca39f9754d9d4f4def8e6189b49cd52"
  },
  {
    "path": "convex/deletion.ts",
    "before": "390fed8f81430a57739b1b039bf1ce8cf9016d1df997d9bdf7b1e59ef3cd16e8",
    "after": "f3f627212b80e8eab1de9523c188504ecfd531585c8368a5a855c779aa36361c"
  },
  {
    "path": "convex/deletionRetention.ts",
    "before": "bbe1e0c66274b24c2a80e94c94eec96e680579cabe89a57e5b5607a0423f721f",
    "after": "5a85836f90176cc502662c7f6d91f982520a942b3df687c68a465072e065aedb"
  },
  {
    "path": "convex/gemini.ts",
    "before": "5cda8cda5bdf7ec882dbdadf9d31b762ba4af6753c93801acc1ce5b611dfefb1",
    "after": "d1c2c6be64c5ce35d0ffaed93cd0203f9add10170fb5518de63f18c237c340ee"
  },
  {
    "path": "convex/http.ts",
    "before": "0030fcf59299230f3261af092e007167260af9eea1008b0a702e29f29b900f79",
    "after": "f6320818a11b0c6548d116f7110710aee9a8f428b349e5ba1023ee9117bb8428"
  },
  {
    "path": "convex/schema.ts",
    "before": "507960d189967a6435d76e3635cb3b48fb2779a158a2ed38403a03743b5cdb13",
    "after": "7352ec57d4bbe894880619ddfc52a24c95f8ff5e8d13af590c4d398b8891bca1"
  },
  {
    "path": "convex/batchHttp.ts",
    "before": "27a3618080aee07e96cea1124bb1f406d40685c44105cf82426485a6f15ae3ac",
    "after": "ddd03422464f42750a2188d1942d667111766ddb6f6b7443144a64b245794876"
  },
  {
    "path": "convex/batchChat.ts",
    "before": null,
    "after": "ef32f433942efcc7c4d0235ea5e1229234026a8cfbe796e10173f3002eefb645"
  },
  {
    "path": "convex/batchChatContext.ts",
    "before": null,
    "after": "4f74ef3fa12aa14a60c8282978020c9516a76cb424be08ffa4e4efc7b5037bca"
  },
  {
    "path": "convex/batchChatSchema.ts",
    "before": null,
    "after": "35b08abc2f1fd05f9ecfbad587ed875f8f0604d319d80f5a66c07334168696c6"
  },
  {
    "path": "convex/batchChatJobs.ts",
    "before": null,
    "after": "9259e6502453021907c4cddb0bf51db6023ab0d58fd5e411abeeb494f0504637"
  },
  {
    "path": "convex/batchChatHttp.ts",
    "before": null,
    "after": "5e49e5ddd2fba951edc33bb06fe174299909b44d9a77a3e334ea988f4e9d117d"
  },
  {
    "path": "Tests/backend/batchChat.test.ts",
    "before": null,
    "after": "eac281a63429c96157bbfc117b377d07308aafc4b1b000930ff84b869587d975"
  },
  {
    "path": "Tests/backend/batchChatContext.test.ts",
    "before": null,
    "after": "f3b7786762634979c25167ccb6f3a399c96b0f1d3acd1cf28e6d5d94c233278a"
  },
  {
    "path": "Tests/backend/batchChatJobs.test.ts",
    "before": null,
    "after": "8e6ca23e35501f6591faef29a7af9fb17cfe08300a126d437f0770a8a841b6e9"
  }
]
```
