# Integrated batch backend corrected candidate — 2026-09-25

Returned to Lead for technical acceptance. Backend write ownership relinquished.
No commit, push, deployment, login, credentials, real fetch, paid call, codec
dependency, native build, root dependency change, or activation was performed.

## Correction checkpoint — supersedes rejected candidate

Lead rejected the previous handoff
`44ae3e2246f205f905893784088db750a1a48fb7aa7e2ef490872cc6498e75ce` for two
reproduced blockers. This candidate corrects both; it is not self-accepted.
No frozen wire/response contract change was needed. The complete original-base
manifest at the end now identifies the corrected bytes, including unchanged
implementation paths. Correction scope: the seven paths listed below plus this
handoff only. Native fixtures were read, never written.

### Queue/accounting correction

An owner+state index isolates the current owner's queued rows. Each claim examines
at most 25 rows before selecting up to two eligible jobs. Never-submitted queued
attempts with incompatible reservations transition atomically to terminal failed,
release their old quota once, clear the reservation, and expose `billing_changed`.
The existing first-attempt explicit retry reserves fresh quota; a second-attempt
billing failure is exhausted, never a third attempt. No failed work is automatically
re-reserved or submitted. Same-plan already-reserved work can proceed independently.

A drain schedules its next bounded pass only after releasing the dispatcher
verification lease. It works across >25 rows and can retire queued incompatibilities
even while two running/unknown jobs hold inventory. Those jobs, fences, reservations,
and provider outcomes are not modified by the drain. Provider claims still obey two
slots. Fresh verification/revision and deletion guards are unchanged.

### Original timing-table correction

Batch admission now reads original `stts`/`stsz` on the bounded sample-table box
path before MP4Box parsing, not from a reconstructed sample list. It requires one
of each table, positive bounded timing runs, exact summed sample count and exact
BigInt summed duration. Those declarations must also match media duration and each
reconstructed sample's duration. This rejects under/over-counts, extra empty runs,
huge run counts, and a final duration silently repaired by MP4Box. Legacy media
source and `audioSeconds` acceptance remain byte-for-byte unchanged in this round.

### Red/green and final verification

Before production corrections, focused regressions observed **4 failures / 25
passes**: Free->Pro and Pro->Free each left zero of the expected 25 rows failed;
native stts counts 60 and 62 (vs stsz 61) were incorrectly admitted. The additional
pre-fix media run observed **7 failures / 9 passes**, including five multirun
contradictions that were incorrectly accepted. These are preserved as executable
tests in `batches.test.ts` and `batchContract.test.ts`.

Final corrected commands (same offline environment described below):

```sh
npm run typecheck:backend
npm run test:backend
git diff --check
```

Observed: both typechecks pass; **622 tests / 18 files pass** (1.36 seconds);
diff check passes. This is the prior 607-test suite plus 15 correction/compatibility
cases. No final failed check remains. The same focused two-file command below
reproduces the correction tests.

Verified cases include the exact Free 25-slot / 7,200-second reservation plus new
Pro 2-second reservation: old slots terminal `billing_changed`, zero old reserved/
used seconds, later Pro job completes using two seconds. Both plan directions drain
30 old rows in a 25+5 bounded sequence without relying on old seal notifications;
repeat recovery does not settle twice; explicit retry reserves only its own current
plan allocation. Second-attempt billing changes do not expand the retry budget.
Already claimed/running and unknown-held attempts retain exact original records.

Read-only frozen native compatibility evidence:

- `chunks/chunk-00.m4a`: SHA256
  `210677dbc40079130e9dce06fd93df17133dead2c696565590f246a51a574863`, 12,288 bytes.
- `wire-manifest.json`: SHA256
  `e2050556b9325b748fefeba93d53bb860ab4d4449851de701081037339ffab08`.
- `evidence.json`: SHA256
  `e9bdfba0ec16da60be7211d36bba1abce049b50b5cbf8852e0bdddf98b39a409`.

All are under `Tests/fixtures/batch-native/`. Actual bytes pass exact 132301/44100
presentation; backend digest matches frozen native digest
`9812a2b6dd6d06eaf2fe302bc71b231449749f83fd32f4360a3d62bf3f63fba7`.
This establishes shared-fixture structural/digest compatibility, not decoding,
native UI/reopen acceptance, provider quality or activation approval.

Correction delta before hashes (the rejected candidate); corrected after hashes
are in the complete manifest below:

| Path | Rejected SHA256 |
| --- | --- |
| convex/batchJobs.ts | d089f1701ba115614177878d6bfbdd7932407c3b05002df589cac098b56fb8e0 |
| convex/batchMedia.ts | 3051d630c5d691b111191118379e23e3786a66f0619095fb72467ef79d771855 |
| convex/batchSchema.ts | ac7bc0c7a918b3899648e67dc308dcbfb828156b2959b9999d9e77c6a3c77e11 |
| convex/batches.ts | b3d83ac3e670a3402f18450509675a69d0a98316f31cb2416e78f80e20288de3 |
| Tests/backend/batchContract.test.ts | 30f1d53bb65e08a2d6d820a37bfbeea82e34276d85e68ae50f5adc449e14e61d |
| Tests/backend/batchMediaFixture.ts | 3d124907111774bd7f04378140822a6ee6cbc17370bfceb5474ec5dd3664acc2 |
| Tests/backend/batches.test.ts | 118abbc8f3df02258124025975838733c6b2453704cc04772f557b75945bfd10 |

## Identity and scope

Base HEAD: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`, plus the accepted dirty
baseline present at dispatch. Frozen contract read in full:
`docs/BATCH_CONTRACT.md` SHA256
`5c22fd88a98cd86659ff0c7eb8d7cf8851a9744454cebba9d54f04d4e3633412`.
Only the eighteen implementation/test paths in the manifest below and this new
handoff were changed by this writer. Native/STATUS/packaging changes in the shared
worktree belong to their existing owners and were not modified by this writer.

The API declaration module map was updated locally; no remote codegen/deploy ran.
New runtime functions are internal-only. No settings/environment files changed.

## Usable workflow

The real `/v1/transcription-batches` HTTP routes now implement create/recover,
bounded immutable chunk upload, seal, status, result, aggregate, and explicit
failed-chunk retry. BigInt geometry, fixed-array digest, exact presentation equality,
and the floor-actual timestamp bridge follow the frozen contract.

Parents, chunk slots, fenced attempts and a singleton two-job inventory are
durable. Seal atomically reserves canonical quota. Dispatcher/control billing
refreshes share a lease; claim requires the resulting fresh billing revision.
Workers acquire exclusive execution before action-local failures can settle quota.
Unknown generation keeps its slot/reservation despite timeout/file DELETE. Known
failure releases quota; success consumes once; retry never reruns successful siblings.

Provider calls use the actual pinned SDK/current model configuration with
`store:false`, `maxRetries:0`, unchanged output-token setting, and a raw structured
JSON transcription prompt. Provider completion and exact timestamp validation
precede publication. Raw successful JSON remains byte-for-byte intact. Aggregate
overflow returns `too_large` with original results still independently available.

Generation requires default-off `BATCH_TRANSCRIPTION_ENABLED`, exact
`BATCH_TRANSCRIPTION_OWNER` tokenIdentifier and the existing Gemini gate. Status
and result reads are owner-scoped and remain available when generation/allowlist
configuration is off. No activation is authorized by this candidate.

### Media evidence and limits

Batch extraction is structurally validated, never decoded. The accepted actual
Apple synthetic fixture returns 60,000 presentation samples, 2,112 priming,
352 padding and 62,464 coded samples at 48 kHz. Exact edit-only and agreeing
SMPB/edit variants pass; conflicting declarations fail. Batch extraction does not
reuse legacy approximate timing acceptance. Legacy `audioSeconds` is unchanged.

Pre-parser aggregate limits: 16,384 sample entries, 65,536 table entries, existing
4,096 boxes/depth 16, and actual bytes <=18 MiB. A 300-second table-only synthetic
fixture uses 14,065 access units and passes; over-cap/mismatched fixtures fail.
This is not a new actual dense 300-second export/decode test. The fixture builder
explicitly uses synthetic nondecoded payloads: it is not acoustic/decoder proof.

### Lifecycle, deletion and reconciliation

Provider transport retains the existing 210-second request deadline and 10-second
cleanup deadline. Batch attempts have a 240-second observation deadline; the
minute recovery job exposes unknown work but does not release its slot or rerun it.
Pre-submission stalled work is also conservatively held for explicit reconciliation.
No batch inventory is created by recovery when no inventory exists.

Batch cleanup precedes quota-bucket deletion, removes content in bounded passes,
and preserves unresolved operational evidence. Late worker results cannot recreate
deleted content. Existing deletion automation drains batch slot references only
under its existing terminal-work rules. Completed-ledger purge checks batch rows;
existing 30/90-day policies and provider automation gates are unchanged.

Internal exact-target recovery helpers (not HTTP endpoints):

- `batches.reconcile`: attempt ID, issuer-bound owner, fence, private evidence
  reference, `remoteStopped:true`, `filesReconciled:true`. Requires actual operator
  evidence; timeout/file absence are not evidence. Releases unresolved quota/slot,
  makes failed work eligible for its remaining explicit retry, preserves successes.
- `batches.reconcileAdmission`: parent/index/owner/fence/upload work plus evidence,
  `storageReconciled:true`, `actionStopped:true`. After operator reconciliation,
  resets only that immutable chunk's storage admission, never generation.
- Existing account-deletion `deletion.reconcileWork` drains matching batch attempt
  inventory before removing the work record. All work-target checks remain exact.

## Original implementation reproduction (historical; corrected totals above)

Environment: repository `/Users/tubakhuym/projects/lessmeet`, Darwin arm64,
Node v22.22.3, existing locked dependencies; no installs. All fetches in new
integration tests are replaced with an exhaustive mock that rejects unknown routes.
The real HTTP handlers, Convex test storage/transactions/scheduler, provider adapter,
and real pinned AI SDK execute; these are not mocked state-machine-only tests.

Original checkpoint commands:

```sh
npm run typecheck:backend
npm run test:backend
git diff --check
```

Original checkpoint observed: both TypeScript configurations passed; **607 tests / 18 files passed**;
diff check passed. This includes the prior 583-test baseline plus 24 new tests.
Original suite duration: 975 ms. No Swift/native UI tests were run by this writer.

Focused reproduction:

```sh
./node_modules/.bin/vitest run --config Tests/backend/vitest.config.mts Tests/backend/batches.test.ts Tests/backend/batchContract.test.ts
```

Evidence covers default-off/auth/owner refusal, hash-matching malformed media with
billing off, exact native gapless/edit admission, duplicate JSON keys, fixed digest,
sub-ms timestamp rejection, create/upload/seal replays, interrupted admission,
two slots across three parents, unknown remote holds after DELETE and timeout,
billing lease/revision refusal, duplicate executor/stale fence rejection, late
completion after deletion, known-failure retry/idempotency/quota, partial sibling
preservation, overflow originals, cleanup warnings, and generation-off exact-target
reconciliation. Full 25-slot structural 120-minute pipeline: 25 mocked generations,
complete state, 7,200 seconds used, zero reserved. Initial geometry sums to 7,320
provider presentation seconds. The suite never makes a real provider request.

Fixed cross-language digest vector in `batchContract.test.ts`: source hash `a` x64,
bytes 1, duration 5/4, one chunk hash `b` x64, bytes 1. SHA256:
`cf7f70ecfb89df934aaf59fdccd3814a325763ee598461595df1113b58977f8f`.
Native verification of this same vector is downstream work, not claimed here.

Initial failed checks were resolved: metadata fourcc decoding incorrectly treated
the non-UTF8 copyright atom as UTF8; exact edit fixture now passes. Initial TypeScript
narrowing/Buffer generic and route-array syntax issues were corrected before the
final passing runs. No failed final check remains.

## Preserved baseline and remaining limits

Accepted results module unchanged:
`2ed80c8e98374d09ab7e70fc2a44b9d365701ab2215942e3532657bdf7232d27`.
Accepted Clerk transport unchanged:
`39d3c407880a07aaf5aa931eff3def914895a15f88312161d9105cfcb6c23d74`.
Removing only this writer's exported preflight signature and optional batch budget
lines from current media bytes reproduces accepted media SHA256
`83c1c9ddd8dfb2f70b59cd89e408795ad8353ac256fb911a442a938ef584b720` exactly
(verified with Node SHA256). Existing test sources were not edited.

Implemented backend workflow is complete for offline integration; Lead acceptance
is still required. Human structural-only activation decision remains pending.
Full server decoder safety, hostile-parser runtime isolation, actual provider
speech/diarization quality, production Convex resource limits, native cache/reopen/UI
proof, signing and TestFlight delivery are unverified. No public-release gate is
waived. Batch chat remains the explicit follow-on checkpoint; legacy chat is preserved.
Known ambiguity can hold both slots indefinitely until exact reconciliation; this
is intentional safety, not a timeout-based refund/retry feature.

## Full changed-path SHA256 manifest

`before:null` means absent at dispatch. Other before hashes are HEAD bytes except
media, whose before hash is the accepted dirty baseline. This handoff is the only
additional changed path; its SHA256 is supplied separately to avoid self-reference.

```json
[
{"path":"convex/_generated/api.d.ts","before":"282d86e16256fdd802d87c9afc8e4bcb5311012fd10883aed63dd079f0b0d5a6","after":"5513ae5610b413e45675b8c7b244ccc13a1726ca78f9c0686be9c14b2333a9fe"},
{"path":"convex/crons.ts","before":"ede78b15d8a6360752211456436d73788cc06a5fe3c6ec5a482344b5c93c0a1a","after":"f599294a367b37543c85980a7cf166faf34f8bcc3830a3e0c1e308bbdf4506b2"},
{"path":"convex/deletion.ts","before":"94db43c7c40239d58d0f176b5acb9217cddab04355ac7e15b06074c1192e2869","after":"390fed8f81430a57739b1b039bf1ce8cf9016d1df997d9bdf7b1e59ef3cd16e8"},
{"path":"convex/deletionAutomation.ts","before":"40648dbbd7bc73bfb7ea290b80623541158d99ec4a6a445dc5ad7969d1b9ae64","after":"064702579eeb66a3eb778732073343367b9b73abf0add078e077140c27316b4d"},
{"path":"convex/deletionRetention.ts","before":"23f5a09bd5ad1a004470941185a3a6082722257a2e9caeef1d94c63100450a4a","after":"bbe1e0c66274b24c2a80e94c94eec96e680579cabe89a57e5b5607a0423f721f"},
{"path":"convex/gemini.ts","before":"a63d5bed12f7e1100387f98cd0c43fb69a405aba05485e706cca9c5e3ff6e291","after":"5cda8cda5bdf7ec882dbdadf9d31b762ba4af6753c93801acc1ce5b611dfefb1"},
{"path":"convex/http.ts","before":"2d6cabf4be17dc2df6c46dd008456a08a37815be70f42dd86d0faa0640494d13","after":"0030fcf59299230f3261af092e007167260af9eea1008b0a702e29f29b900f79"},
{"path":"convex/media.ts","before":"83c1c9ddd8dfb2f70b59cd89e408795ad8353ac256fb911a442a938ef584b720","after":"2c08b8e8cd383d9cdabfa75ca8921d466e9fce82388222862414ac5a03026ffd"},
{"path":"convex/schema.ts","before":"94befddcee3ba88804c66787df2c7a7ee04e432fd54a9b6e6f24715cea341f30","after":"507960d189967a6435d76e3635cb3b48fb2779a158a2ed38403a03743b5cdb13"},
{"path":"convex/batchContract.ts","before":null,"after":"eeeb59a9beca49563bdcf5cceba8c3341004c77279d6d825ad38073e0ace9530"},
{"path":"convex/batchHttp.ts","before":null,"after":"27a3618080aee07e96cea1124bb1f406d40685c44105cf82426485a6f15ae3ac"},
{"path":"convex/batchJobs.ts","before":null,"after":"251e0d80aba6b04ba33d078e6969e533453edb84a7fe1963948057facb75b816"},
{"path":"convex/batchMedia.ts","before":null,"after":"338b677e4d41bbe4d7cee9765621101994f65d87a09642ffd5d85bff79ff4b7f"},
{"path":"convex/batchSchema.ts","before":null,"after":"796bda044f92fc1ddc774b55ea54e707ee08b65eff7aef3f3f4b7a0417809e75"},
{"path":"convex/batches.ts","before":null,"after":"c63b1453f90059f122773ead2ff308220814e8fcba9ade0721f02c88e92eac9c"},
{"path":"Tests/backend/batchContract.test.ts","before":null,"after":"38cb2adc6830cde9cbe78c44ae58ca24534de65c475318d1bf154dc5631cd224"},
{"path":"Tests/backend/batchMediaFixture.ts","before":null,"after":"ac926687e94fe489957666ca6c515b53e5133b7c0f1ce82a292bc66bd498de59"},
{"path":"Tests/backend/batches.test.ts","before":null,"after":"5436ae2d4146c3c3ceea858ff01b3177c0d6cfe19d5fee1c3280f417f1c0d5e4"}
]
```
