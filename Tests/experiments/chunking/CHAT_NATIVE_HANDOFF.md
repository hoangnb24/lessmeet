# Native batch chat candidate

## Status-only pending correction (current snapshot)

2026-09-25. Corrects Lead's reopened status-discovered-operation gap; ready for
Lead review, not self-accepted. Base remains
`b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty candidates.
Input handoff SHA was
`bffbbf9f3802ba6fd8d7d428221d7e26881da529fdaa6528bc5b9295b6149979`.
Shared/local protocols, complete BATCH_CONTRACT and current STATUS were read first.
Contract remains `4e2f52c7e2d21937c59a538db28356542f39ca6fc9bd56465598744468c51869`.
No backend inspection or edits in this correction; no DTO/shared-contract change.

Exactly five changed paths in this correction:

| Path | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| Sources/LessMeet/Cloud/BatchChat.swift | `6f58867474c29e1791524bc9c2643967cd7056d6ee92449b0cedb1b99caba4a0` | `640c62633042ec5f9c89d3e47938d75b1cfd750a76efaf8e684d74b07cdfffb5` |
| Sources/LessMeet/Cloud/CloudClient.swift | `4b13356ac440cf9616d5a9961f86407bbbfe97461b039f020ad6976e9736fa08` | `fbd107005309d96d12bd85e5148fc62bfd52ebe2348a26ee67488466227901f6` |
| Sources/LessMeet/Presentation/RecordingCloudModel.swift | `5ed55f92915fec45156f4b762f063e136f08e0d459631a3fff41024cf2fd07d3` | `481c87300c3377345b1e60411546ac101931b1686d53780a49c15852f74fc394` |
| Tests/LessMeetTests/BatchChatTests.swift | `ce5fa3c2fc0bd4452c6414d2b47a338b5c9f503b31bb58a5810b91c0d6d8d4f3` | `4e16167ddc7735facb7329de35c36531e3d9a9bb03d16789292c90eb9de620b4` |
| Tests/experiments/chunking/CHAT_NATIVE_HANDOFF.md | `bffbbf9f3802ba6fd8d7d428221d7e26881da529fdaa6528bc5b9295b6149979` | Final response supplies this document's SHA. |

TranscriptionBatch.swift, LibraryView.swift and BatchChatView.swift remain at their
original chat snapshot hashes below (rechecked). No other source/test/fixture,
Package, docs, scripts or handoff edits. Transcription DTOs/strict validation and
legacy chat remain unchanged.

### Correction behavior

One shared BatchChatOperation transition validator now protects local-request,
status-discovered and exact-ID GET receipts: immutable batch/question/context;
nondecreasing per-identity version; unknown cannot regress to queued/running;
running cannot regress to queued; equal-version payloads must agree including
exact UTF8 text/error bytes; terminal receipts cannot be rewritten. No operation
version is compared with completed-history revision.

BatchChatStatus validation compares same-identity pending operations with prior
pending evidence even when there is no local request. Disappearance or replacement
requires an explicit validated terminal receipt for the OLD identity. Known success
also requires its matching context and exact reply in the authoritative exchange
list; known failure must not have a successful exchange. A still-unknown receipt,
404, lower/conflicting version, changed context or missing/inconsistent success
history rejects the incoming snapshot and preserves prior disk/published status.

The model resolves disappearance/replacement using the EXISTING GET operation route
with only batchId/clientMessageId. The new native overload is read-only; it does not
construct a BatchChatRequest, invent a message/history precondition or POST. Already
saved matching local terminal receipts may resolve the prior pending identity too.
An optional local-only observedOperation retains one bounded status-discovered
receipt and protects it against later same-identity regressions. This is not a new
wire field or an unbounded workflow/archive. A different pending identity replaces
the old one only after proven terminal resolution. Incoming evidence is also checked
against a stronger matching submitted-operation receipt, even after local failure
has cleared its request payload.

All status-only changes are validated before atomic cache save/publication. Failed
saves and invalid responses leave the stronger prior pending evidence visible.
Legitimate late success/history advancement and known failure recover through GET;
both unblock a later fresh explicit question. Unknown remains blocked, including
when the server returns pending:null. No reset/resend/automatic-POST shortcut added.

### Executed red/green and final proof

Environment unchanged: repo root, macOS26.4(25E246) arm64, Swift6.3.3,
MacOSX26.5 SDK, Swift5 package mode, URLProtocol-only synthetic requests.

- BEFORE production edits:
  `swift test --disable-automatic-resolution --filter 'BatchChatTests.testStatusOnlyRegression'`
  exited1: two tests,32 failed assertions,0.315s. Direct validation and actual
  model/store/reopen accepted revision3 unknown -> revision2 running, equal-version
  quota conflict, higher-version context change, unknown -> running, equal-version
  canonically equivalent but byte-different error text, disappearance and replacement.
  Incoming invalid state overwrote disk/published/reopened snapshots.
- Same command AFTER correction exited0: two tests,zero failures,0.121s.
- `swift test --disable-automatic-resolution --filter BatchChatTests`
  exited0:25 tests,zero failures,1.098s. Added direct/model red regressions plus
  exact-ID disappearance recovery for late success and known failure, fresh explicit
  Send after each resolution, unknown/404 hold, identity replacement only after old
  terminal proof, disk-failure/reopen preservation, missing success history and exact
  UTF8 reply checks. Recovery assertions show no local request and zero POSTs.
- FINAL `swift test --disable-automatic-resolution` exited0:128 tests,three
  intentional skips,zero failures,13.274s (suite13.283s). Includes all25 chat tests
  and the accepted19 transcription integration regressions. Skips remain long
  capture, exact120 opt-in and native fixture generation. No new skip or compiler
  warning; existing CoreData/XPC diagnostics persist. No exact120 rerun.
- `git diff --check` passed; shasum verified all current changed-path hashes and
  the three unchanged source/UI hashes in the original chat snapshot.

No external call, activation, credential access, paid test, dependency, backend
inspection/edit, signing, deployment or commit. Mock receipt/history evidence proves
native recovery behavior, not backend generation/quota/deletion correctness. Existing
UI, local-filesystem, live compatibility and absent-changed-context limitations below
remain. This correction cannot reconstruct an identity already discarded by an older
buggy cache; it preserves identities present in saved pending/receipt evidence.

Correction complete for Lead review. Native write and exclusive Swift compilation
ownership relinquished; no build remains active. No unresolved contract dependency.

## Original chat integration snapshot (historical)

2026-09-25. Actual native transport/model/cache/UI integration, ready for Lead
inspection; not self-accepted. Native write and exclusive Swift-build ownership
relinquished at handoff. No build remains active. No backend/fixture/Package/docs/
script/other-handoff writes, dependency, real network/provider call, credential
access, signing, deployment, paid test, commit/push or orchestration.

## Base, inputs and complete changed snapshot

Repo `/Users/tubakhuym/projects/lessmeet`, original base
`b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty candidates.
Read shared/local protocols and COMPLETE frozen contract before implementation.
Accepted native handoff input SHA:
`01f5dd0aa740718301da8cabb0a5ec706bd87093b0587f06f336cd2fc1ee12ee`.
Accepted backend handoff input SHA:
`850994e592cc94fae934b33a3ba9b4266eccf88377301184343f84e743ec2074`.
Both handoffs remain unchanged. Other dirty files and K's concurrent backend work
were preserved; backend implementation is not validated by this native handoff.

Initial BATCH_CONTRACT SHA was
`4377b494a7f4e7a32b2775b74db9c2acb2ce6279d2c150e7e550ffca6d245aa4`.
Raised revision-clock ambiguity to Lead. Lead resolved it in STATUS and the additive
contract; COMPLETE updated spec was reread. Final contract SHA:
`4e2f52c7e2d21937c59a538db28356542f39ca6fc9bd56465598744468c51869`.
History revision equals completed exchange count; operation version is independent.
No cross-counter comparison remains. This decision is resolved, not an open blocker.

Exactly eight changed paths in this assignment. ABSENT means newly created:

| Path | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| Sources/LessMeet/Cloud/BatchChat.swift | ABSENT | `6f58867474c29e1791524bc9c2643967cd7056d6ee92449b0cedb1b99caba4a0` |
| Sources/LessMeet/Cloud/CloudClient.swift | `a325ef818a3c2ff69d9653d6036a9fe037a7507d8c3c29f4d59dbdc3339a168c` | `4b13356ac440cf9616d5a9961f86407bbbfe97461b039f020ad6976e9736fa08` |
| Sources/LessMeet/Cloud/TranscriptionBatch.swift | `0b4e94853ee8f4e9b82e2cbfbc59d85ff1b54388764acdbe2a4451b62bb7a611` | `7a24ffb5a5b577572cb003d336c3a5588d7ee176b782eef157225632e5d8d66a` |
| Sources/LessMeet/Presentation/RecordingCloudModel.swift | `2f8943f571ac92cbaf193105777f05b6b710f92872f5889a4ebb24e20cc77bf1` | `5ed55f92915fec45156f4b762f063e136f08e0d459631a3fff41024cf2fd07d3` |
| Sources/LessMeet/Presentation/LibraryView.swift | `caf8894e9e76267fafbd00b1e23c06515fafa31e93fad03a2bdce5453e24fe3b` | `d4f68b0e6be05efc798696e21e28635b00a2d7499996a3962a4fefaf6732342b` |
| Sources/LessMeet/Presentation/BatchChatView.swift | ABSENT | `a204a989c9f7064049da16c6ba78a8c89448371e43837a3ea20dbf9034303c49` |
| Tests/LessMeetTests/BatchChatTests.swift | ABSENT | `ce5fa3c2fc0bd4452c6414d2b47a338b5c9f503b31bb58a5810b91c0d6d8d4f3` |
| Tests/experiments/chunking/CHAT_NATIVE_HANDOFF.md | ABSENT | Final response supplies this document's SHA to avoid self-reference. |

TranscriptionBatch.swift changes ONLY by adding optional `LocalBatch.chat`; accepted
raw strict validation, rational geometry and provenance checks are unchanged.
CloudClient adds separate chat methods and chat-specific503 wording; existing
transcription request/response bounds and DTOs are unchanged. Legacy chat transport
and RecordingChatView are unchanged. Optional cache decoding keeps old recordings
usable; the existing model/store tests exercise pre-chat metadata and legacy chat.

Unchanged, rechecked accepted inputs:

- TranscriptionChunks.swift `f7091bd10383d12294a854f37182869dc1c8887759cf14ddfbb29af2c7bba27d`
- TranscriptionChunksTests.swift `a898705f90ec11450e1a4726d7718bb03ac6bbb8ce4416deeb75a855fc175905`
- BatchIntegrationTests.swift `7fa9114b454db140524c36fe8ccfe92ea9f95c6b6130117b947d6a584aa59fca`
- Package.swift `d84a648912e37e25eeaaccbff3e09c37977b2dc9cea4b0ade610692a4b7036f2`
- All eight frozen batch-native fixture artifacts retain the SHA values listed in
  NATIVE_INTEGRATION_HANDOFF.md, verified with shasum; no new fixture/media writes.

## Implemented behavior and decisions

New transport uses exactly GET `/v1/transcription-batches/chat`, GET and POST
`/v1/transcription-batches/chat/message`, the frozen five-field POST and response
DTOs. Chat POST50176bytes, status256KiB and operation64KiB are enforced separately
from transcription bounds. Uses existing fresh bearer-token and redirect rejection
transport. HTTP503 says chat is disabled/unavailable, not that transcription is off.

Before Send, an explicit read refresh obtains authoritative chat availability.
Native recomputes context SHA from selected original raw UTF8 SHA values and the
accepted manifest digest; strict raw validation is reused. It neither builds a
provider prompt nor claims the server384KiB context policy from native metadata.
Complete local batch/aggregate/selected results are necessary before ready Send.
Server context_too_large/incomplete/disabled/history_full remains visible and does
not cause native truncation, fallback or automatic generation.

An optional LocalBatchChat lives inside the existing account/backend/batch-scoped
LocalBatch. It holds complete saved ChatStatus, exact pending BatchChatRequest,
operation receipt, last settled request and confirmed-absence flag. Existing
RecordingStore atomic-save and account/session/selection/generation fences are reused.
The lowercase question UUID and exact five submitted fields are saved BEFORE POST
or token acquisition for that POST. Reopen reads these same fields, not a new UUID.
Questions/previous history compare exact UTF8, not Swift's canonical Unicode
equivalence; no normalization or trimming rewrites submitted/stored text.

Refresh with a saved request always GETs its identity first, then GETs ChatStatus.
No refresh path POSTs. After confirmed404, only a separate explicit resend action
can POST the same payload; it rechecks404, unchanged context/history, ready state
and no pending operation. Previously observed operation, pending status or successful
exchange evidence cannot become resendable merely because a later lookup returns404.
Queued/running/unknown remain exclusive. Unknown cannot regress to queued/running;
late terminal completion may settle. Known terminal failure retains receipt/question
for display and allows only a fresh explicit new question/UUID when availability
is ready. No retry endpoint, timeout-as-stop or automatic replacement exists.

Operation identity/context is matched to the saved request; per-operation versions
start1 and compare only within that identity. Equal-version conflicting payloads
and version/state regressions cannot replace cached evidence. Terminal replay cannot
rewrite a receipt. History revision equals exchanges.count(0..20), never decreases,
and preserves the exact saved exchange prefix. No operation/history clock comparison.
Success receipt alone does not publish a reply as conversation history: a matching
authoritative saved exchange list is required to clear the request. Missing/stale
history retains the pending identity and blocks new Send until consistent recovery.

Replies are bounded by32KiB JSON-encoded-string size; messages by8KiB decoded UTF8;
saved history by20 exchanges and128KiB legacy role/text representation. Incoming
operation/history is validated before save, then saved before AppModel publication.
Disk-failure cases retain the last published history; later GETs recover without
repeating POST. Cancellation stops waiting only; late/account-switched responses
cannot publish under a different context. Deletion access locking continues through
the existing token provider; native makes no provider-stop or remote-deletion claim.

Batch Chat tab now has a real separate panel: ready/disabled/incomplete/context-too-
large/history-full/busy/attention explanations, saved conversation and failed-question
receipt, unresolved exact question, refresh, stop-waiting, explicit absent-resend
confirmation and bounded composer. A separately labeled switch preserves legacy
transcript chat when it exists. Transcript/partial/raw-provenance views remain
readable. Chat warns about repeated overlap and chunk-local speakers; references
are not represented as authenticated citations.

## Executed verification and reproduction

Environment: `/Users/tubakhuym/projects/lessmeet`, macOS26.4(25E246) arm64,
Swift6.3.3, MacOSX26.5 SDK, existing Swift5 package mode. No dependency resolution
or actual endpoint/provider use; URLProtocol intercepts all new test requests.

Commands actually run:

1. `swift test --disable-automatic-resolution --filter BatchIntegrationTests`
   PASS19 tests,one intentional fixture skip,zero failures,3.416s after integration.
   An earlier compile failed because a throwing `&&` expression lacked enclosing
   `try`; fixed directly. No failed test assertion was hidden/skipped.
2. `swift test --disable-automatic-resolution --filter BatchChatTests`
   Incremental11,13,16,17,18,19-test passes. FINAL20 tests,zero failures,0.845s,
   including Lead's clarified independent revision semantics. No skipped chat tests.
3. `swift test --disable-automatic-resolution`
   FINAL123 tests,three intentional skips,zero failures,12.903s (suite12.911s).
   Chat20 and accepted transcription19 regression tests pass, as do existing legacy,
   account-deletion and dense/fractional native tests. Skips: long capture, accepted
   exact120 opt-in, native fixture generation. Accepted120 was not rerun. Existing
   CoreData/XPC diagnostics persist; no new compiler warning in the final build.
4. `git diff --check` passed. `shasum -a 256` verified all changed and listed
   accepted/frozen artifact hashes. No write outside the eight paths above.
5. Independent `node -e` using built-in crypto/JSON.stringify computed the context
   digest vector below. Swift actual workflow asserts the same value; no backend
   import or added dependency. Test raw UTF8 includes leading/trailing spaces.

```js
const c = require("node:crypto");
const h = x => c.createHash("sha256").update(x).digest("hex");
const m = h(JSON.stringify(["lessmeet.batch.geometry.v1","a".repeat(64),1,3,1,
  [[0,"b".repeat(64),1]]]));
const raw = ' {"version":1,"segments":[{"startMs":null,"endMs":null,"speaker":"A","text":"Keep originals."}]} ';
console.log(h(JSON.stringify(["lessmeet.batch.chat.context.v1",m,[[0,1,h(raw)]]])));
// 4a195290a6dc1ce464d0b85052bda62331d13f17a293cb7eb7005a79f4cae2e0
// manifest b8c1bbb289b9992a4af2df02b6529336da19db539b5fe1386ac49290833e06fe
// raw a82a6ab542a0f97df1b3a57d60fb5893069e18d820234df0e33ac965e96a4ac9
```

The20 tests use actual RecordingCloudModel -> CloudClient -> URLProtocol -> atomic
RecordingStore/AppModel -> fresh-model reopen. They check durable exact body before
every POST; lost-before/lost-after responses; unknown replacement exclusion and late
settlement; terminal200 replay handling and409 conflict; gate-off reads/503 retention;
account/backend isolation and account-switch/cancel fences; failures saving request,
receipt and history; wrong batch/question/context/revision/state/quota/oversized reply;
exact Unicode history rewrite rejection; missing success history; independent clocks
and equal-version conflict; observed status evidence after404; changed history after
absence; 50176-byte chat-only body route; response64/256KiB limits; message/reply/
history bounds; unchanged legacy/transcription data. Backend uniqueness/generation/
quota/deletion once-only is not proven by a native mock and remains K/Lead's lane.

All seven availability states with a saved exchange render to bounded900x700
NSHostingView bitmap representations in memory. No snapshot file was written and
no screenshot was visually inspected. This proves rendering executes, NOT clipping,
visual quality, keyboard/dialog interaction, accessibility or whole-window acceptance.

## Limits and acceptance checkpoint

No live JWT/allowlist/gate, provider/model reply, Convex streaming, backend candidate
end-to-end compatibility, signing, TestFlight, acoustic quality or global resource-
safety proof. New chat tests use synthetic metadata/raw strings, not personal media.
Context construction/cap enforcement, provider intent, question quota and deletion
settlement remain server-owned; the native digest/validation is never server trust.

Reads are explicit Refresh/on-Send reconciliation, not background polling. If a
confirmed-absent payload's context/history changes, native refuses to rewrite/resend
it and retains it; there is no discard-and-replace/reset UI in this candidate.
Known terminal failures retain the latest receipt/question, not an unbounded local
failure archive. Unsent editor drafts are not durably saved; submitted payloads are.
Cache inherits existing unencrypted/local-filesystem and atomic-not-powerloss-fsync
limits. Bounded response accumulation is not a bound on all URLSession/Foundation
or rendering overhead. Offscreen in-memory rendering is not full UI acceptance.

Scope complete for review against clarified contract. No unresolved revision/DTO
dependency remains. Lead owns final backend/native compatibility and UI acceptance.
All native writes and exclusive Swift compilation ownership relinquished.
