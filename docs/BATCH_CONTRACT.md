# Internal batch v1 integration contract

Lead-frozen 2026-09-25. Implementation status/ownership lives only in STATUS.md.
Default-off, owner-allowlisted internal beta. No live activation, paid tests or
claim of complete AAC decoder safety follows from this contract.

## Geometry and identity

Source cap7200seconds; window300seconds; stride295seconds; overlap5seconds;max25.
Native preserves originals and validates derivative presentation by local decode.
Server never trusts native decoder claims. Keep existing18MiB actual-byte cap.

Wire manifest has EXACT keys:

```ts
type Rational = { value: number; timescale: number };
type Manifest = {
  version: 1;
  source: { sha256: string; bytes: number; duration: Rational };
  chunks: { sha256: string; bytes: number }[];
};
```

SHA256 lowercase64hex. Bytes positive safe integers, chunk bytes<=18874368.
Rational positive reduced integers; timescale<=2147483647; value<=7200*timescale.
Use BigInt backend rational arithmetic (never serialize BigInt), checked integer/
CMTime arithmetic native. Source identity is a declaration, not verified original
content or interval/overlap equality. Actual uploaded chunks must match hashes and
lengths and independently derived structural presentation.

Digest is SHA256 of compact UTF8 JSON array (fixed order, base10integers,no newline):
`["lessmeet.batch.geometry.v1",source.sha256,source.bytes,value,timescale,[[0,sha,bytes],...]]`.
No names, paths, decoder claims or caller-selected billable duration.
clientBatchId and requestId are lowercase canonical UUID strings.

Exact T=value/timescale; N=1+ceil(max(0,T-300)/295); start(i)=295*i;
duration(i)=min(300,T-start(i)). Actual structural presentation must equal each
duration exactly. Validate exact caps before any display rounding.
Envelope D=ceil(1000*T); result-module starts=295000*i and ends=min(start+300000,D).
Before merge validate each timed result end<=floor(1000*actualChunkDuration).
For sub-ms audio only paired-null timestamps or zero segments are valid; use the
positive envelope for existing JSON validation, never clamp/rewrite provider text.
Display enclosing-ms end as approximate, not extra audio. No sample tolerance.

Canonical quota=ceil(T). Perchunk allocation is cumulative-ceiling differences of
nonoverlapping [start(i),start(i+1)) and final[start(last),T); sum exactlyceil(T).
Human approved fixed protocol-overhead allowance for internal beta only; maximum
initial provider input7320seconds at T7200. No content-equality claim or paidtest
authorization. Initial attempt plus ONE explicit retry; never retry unknown work.

## Routes and response DTOs

Base `/v1/transcription-batches`; all requests authenticate. Mutations require
`BATCH_TRANSCRIPTION_ENABLED === "true"` and exact issuer-bound owner allowlist
`BATCH_TRANSCRIPTION_OWNER` (one exact tokenIdentifier, no email/subject shortcut).
Provider work also requires existing GEMINI billable gate. Reads/reconciliation/
deletion must remain possible with generation off for the existing exact owner.

- POST base: `{clientBatchId,manifest}` ->201 new/200 identical replay BatchStatus.
- GET base: exactly one `batchId` or `clientBatchId` ->200 BatchStatus.
- PUT base+`/chunk?batchId=...&index=...`: raw audio/m4a ->200 admitted/replay or
  202 unresolved admission, BatchStatus. No client storage ID. No overwrite.
- POST base+`/seal`: `{batchId,manifestDigest}` ->202 BatchStatus, idempotent.
- POST base+`/retry`: `{batchId,index,expectedAttempt,expectedFence,requestId,
  confirm:"retry-failed-chunk"}` ->202 BatchStatus; exact failed attempt only.
- GET base+`/result?batchId=...&index=...&attempt=...` ->200
  `{version:1,batchId,index,attempt,rawText}` (bounded selected successful result).
- GET base+`/aggregate?batchId=...` ->200
  `{version:1,batchId,revision,status,missingChunks,aggregate}`; status is
  pending/complete/partial/too_large, aggregate null when unavailable.

```ts
type BatchStatus = {
  version: 1; batchId: string; clientBatchId: string; manifestDigest: string;
  revision: number;
  state: "uploading"|"queued"|"processing"|"attention"|"complete"|"partial"|"failed";
  quotaSeconds: number;
  chunks: {
    index: number;
    state: "missing"|"admitting"|"uploaded"|"queued"|"running"|"unknown"|"succeeded"|"failed";
    attempt: 0|1|2; fence: number; retryAllowed: boolean; resultAvailable: boolean;
    error: {code:string;message:string}|null;
  }[];
  aggregate: {state:"pending"|"complete"|"partial"|"too_large";available:boolean};
  cleanupPending: boolean;
};
```

Strict bounded JSON16KiB control requests; unknown/duplicate keys rejected. Status
contains no transcript/storage/provider IDs or URLs. Perchunkraw and aggregate each
384KiB max, never truncate; original result retrieval remains available on overflow.
Errors `{version:1,error:{code,message}}`:400malformed,401auth,403notallowed/deleting,
404absent/foreign,409conflict,413size,415media,429quota,503off/unavailable,502upstream.
Sanitize messages. Unknown side effects must remain observable, not invite retry.

## Backend invariants

One parent, immutable chunk slots, bounded attempts, singleton two-job inventory.
At most TWO batch transcription jobs across deployment, NOT a new chat/globalcap.
Atomic seal reserves quota for all slots. Fresh billing revision shared by dispatcher
avoids concurrent refresh invalidation. Fence claims/intents/results; persist intent
before each external side effect. Distinguish completedgeneration from filecleanup.
Unknown submission retains slot/reservation; timeouts/fileabsence do not prove stop.
Known failures release once; successes consume once; failed-chunk explicitretry
reserves only that allocation. No rerunning successful siblings. Partial preserved.

Validate media regardless billingtoggle. Batch structural extractor must reconcile
rate-one edits and native iTunSMPB gapless metadata with exact checked relationships,
including agreeing/conflicting declarations. No fields called decoded. Pre-parser
aggregate table/sample budgets verified against nativefixtures before acceptance.
Legacy audioSeconds behavior/billing must remain unchanged. This is bounded
structural checking, not proven decoding or hostile-input resource safety.

All side effects participate in existing deletion work: bounded cleanup of new
audio/results/attempts/parents and reservations BEFORE quota bucket removal.
Late work cannot recreate content. Unresolved external evidence/slots survive until
exact-target reconciliation. Existing30/90day operational policies unchanged.

Gemini batch responses use accepted chunkResults schema, raw JSON with segments,
nullable timestamps, local speaker labels. Keep store:false,maxRetries0; do not
change model/paidsettings. Strict provider finish and exact-time adapter precede
publication. Preserve originals/provenance; same-text/time equivalence is a derived
view, not verified utterance/speaker equality. Expose raw alternatives in native UI.

## Native integration invariants

Persist account/backend-scoped clientBatchId, immutable manifest and local chunk
paths before first network call; recover by key after lost response/relaunch.
Never automatically redo ambiguous upload/seal/provider intent. Refresh first;
only explicit eligible failed-chunk retry. Save results/status before publishing;
preserve legacy recordings/caches, account/session fences and localoriginals.
Cancellation stops local work/waiting, not presumed remote generation. Show actual
progress, saved partial output, missing/unknown ranges and cleanup warnings.
Cross-language digest/boundary vectors are required. Deterministic mocked
HTTP-to-storage-to-worker-to-cache evidence does not prove live provider behavior.
Batch chat is implemented under the separate contract below; it does not replace
legacy chat or imply that either production gate is enabled.

## Batch chat v1 follow-on contract (2026-09-25)

Legacy chat remains unchanged. New chat requires exact owner allowlist,
`BATCH_CHAT_ENABLED === "true"`, the batch enable gate and existing Gemini gate.
Gate-off permits existing-owner reads/recovery/deletion, not new generation.
Only complete batches with complete aggregate and every selected successful raw
result may chat. Build context server-side from ALL validated raw segments, without
deduplication, summarization, truncation or discarding untimed alternatives:

```ts
type ChatContext = { version:1; durationMs:number; chunks:{
  index:number; attempt:number; startMs:number;
  segments:{segmentIndex:number;startMs:number|null;endMs:number|null;
    speaker:string|null;text:string}[];
}[] };
type ChatOperation = {
  version:1; batchId:string; clientMessageId:string; revision:number;
  contextDigest:string;
  state:"queued"|"running"|"unknown"|"succeeded"|"failed";
  quota:"reserved"|"consumed"|"released"|"not_enforced";
  text:string|null; error:{code:string;message:string}|null;
};
type ChatStatus = {
  version:1;batchId:string;revision:number;contextDigest:string|null;
  availability:"ready"|"disabled"|"incomplete"|"context_too_large"|
    "history_full"|"busy"|"attention";
  exchanges:{clientMessageId:string;contextDigest:string;message:string;reply:string}[];
  pending:ChatOperation|null;
};
```

Context compact UTF8 JSON must fit384KiB; otherwise context_too_large before quota
or provider work. Canonical context digest: SHA256 of compact UTF8 fixed array
`["lessmeet.batch.chat.context.v1",manifestDigest,[[index,attempt,rawSHA256],...]]`,
ordered by chunk index, rawSHA256 over unchanged rawText UTF8. Context-format version
binds the deterministic projection above. No claim that every120min transcript fits.

- GET base+`/chat?batchId=...` ->200 ChatStatus, complete bounded saved history.
- POST base+`/chat/message` exact body `{batchId,clientMessageId,
  expectedContextDigest,expectedHistoryRevision,message}` ->202 ChatOperation
  for new/unresolved operation,200 identical terminal replay.
- GET base+`/chat/message?batchId=...&clientMessageId=...` ->200 ChatOperation,
  404 exact-owner absent. Existing batch error envelope/status rules apply.

IDs lowercase UUID; digests lowercase64hex; revisions nonnegative safe integers.
ChatStatus.revision is completed-history revision: starts at0 and increments exactly
once per successfully persisted exchange. Admission/running/unknown/failure does
not increment it. expectedHistoryRevision matches that revision at new admission;
identical existing-operation replay is resolved before checking current revision.
ChatOperation.revision is an independent per-operation monotonic version starting
at1, incremented on durable observable operation changes; identical replay/reads
do not increment it. NEVER compare operation revision to history revision. Native
compares operation revisions only for the same clientMessageId and keeps history
revision nondecreasing, preserving the already saved exchange prefix. With no
history reset, ChatStatus.revision equals exchanges.length (0..20). Recovering an
operation does not itself establish a newer history snapshot: refresh ChatStatus
to publish the complete authoritative exchange list. No equal-revision conflicting
history or operation payload may replace saved data.
Chat-only POST bound50176bytes permits escaped8KiB decoded message; all other
control limits remain16KiB. Strict keys/duplicates. Bound decoded replies to32KiB
JSON-encoded string; histories20exchanges/128KiB in legacy role/text representation.
Check space for entire next exchange before admission; never silently drop history.
ChatStatus wire bound256KiB and operation64KiB; no context/provider IDs in responses.

Uniqueness owner+batchId+clientMessageId, identical complete submitted fields only;
conflicting reuse409. Resolve existing identity before new billing refresh/reserve.
Atomically bind immutable context and history revision, reserve one existing chat
question, persist operation, and schedule. At most one unresolved chat per batch;
do not use transcription two-slot inventory or claim a global chat cap.
Fresh verified billing and reservation compatibility required before generation.
Persist fenced execution intent linked to deletionWork before provider call;
duplicate scheduler delivery cannot generate twice. Existing model/output settings,
store:false,maxRetries:0,90s local provider waiting bound, no tools/retrieval.
Treat context/history as untrusted data; labels are chunk-local and overlap may
repeat speech. Model references are not authenticated citations.

Known completion+valid reply: append exchange and consume quota atomically once.
Known failure before submission or proven terminal completion: release once.
Timeout/disconnect/ambiguous generation: unknown retains reservation/exclusion;
no replacement question, retry endpoint or timeout-as-remote-stop. Late same-fence
completion may settle once. Persistence retry must never repeat generation.
Internal exact-target reconciliation requires durable evidence, not elapsed time.
Failed terminal operation permits a fresh explicit question with new UUID, not an
automatic retry. Keep receipts separate from prompt history with bounded deletion.
Deletion removes questions/replies/context references and settles reservations
before quota buckets; unresolved operational evidence remains, no late resurrection.

Native saves account/backend/batch-scoped UUID and exact payload before POST.
After loss/reopen, GET by same identity first; only explicit same-payload resend
after confirmed404. Save outcome/history before UI publication. Unknown visibly
blocks Send; cancellation stops waiting only. Keep saved partial transcription
readable but chat unavailable until complete; legacy chat remains separate.
Validate operation identity/context/revisions/state and bounded history before save.
Deterministic mocked tests must cover replay/conflict, lost responses/reopen,
account switch, timeout/late result, gate-off recovery, deletion and quota once-only.
