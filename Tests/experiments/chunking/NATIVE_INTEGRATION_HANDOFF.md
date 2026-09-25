# Native batch v1 integration candidate

## Validation correction snapshot (supersedes original candidate below)

2026-09-25. Both Lead-reopened validation gaps corrected; candidate awaits Lead
acceptance. Original base remains `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`.
Input candidate handoff was `cf2a0bc2f67975fe32795f032759876f99d5c94575ee8a72e5dfca8c0196bf25`.
Exactly three paths changed in this correction; all other original snapshot hashes
below were rechecked and remain unchanged. No DTO, transport, model/store/UI,
helper, fixture, Package.swift, backend, docs or other handoff edits.

| Correction path | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| Sources/LessMeet/Cloud/TranscriptionBatch.swift | `0605d6e74765ed89b228b9bd6e83f60cf7c749fac2a7773117e341fe96163adf` | `0b4e94853ee8f4e9b82e2cbfbc59d85ff1b54388764acdbe2a4451b62bb7a611` |
| Tests/LessMeetTests/BatchIntegrationTests.swift | `a56f7374bf3d053b568c63ef4db41b804bac7d29904b8677eda1ae955002c41e` | `7fa9114b454db140524c36fe8ccfe92ea9f95c6b6130117b947d6a584aa59fca` |
| Tests/experiments/chunking/NATIVE_INTEGRATION_HANDOFF.md | `cf2a0bc2f67975fe32795f032759876f99d5c94575ee8a72e5dfca8c0196bf25` | Supplied in final response to avoid self-reference. |

Read shared/local protocols, latest STATUS, complete BATCH_CONTRACT and accepted
RESULTS_HANDOFF, and inspected deterministic native/server counterexamples.
Read-only result contract inputs: `convex/chunkResults.ts` SHA
`2ed80c8e98374d09ab7e70fc2a44b9d365701ab2215942e3532657bdf7232d27`;
RESULTS_HANDOFF SHA `56af492e0bfd15b3d98043d9c42b3f00122f63833ef29f38e35b62888ac230a3`.
No boundary disagreement or contract change was needed.

Raw validation now requires exact root/segment keys, including present nullable
startMs/endMs/speaker. Rejects booleans/non-integral timestamps, unknown keys,
duplicate decoded keys (including escaped aliases), unpaired surrogate escapes,
and server-disallowed C0/C1/bidi controls. Text/speaker require content after
ECMAScript whitespace and Unicode Cf exclusion; tabs/CR/LF, ordinary Unicode,
combining marks and legitimate ZWJ strings are retained. Existing inclusive UTF8
384KiB raw /8192-byte text /128-byte speaker /2048-segment caps remain. No raw
normalization, trimming or reserialization occurs. Exact rational floor-ms bounds
and the sub-ms paired-null/empty-result policy remain unchanged.

Foundation parses the bounded input; a nonrecursive byte/string scan rejects
duplicate keys, limits object stack to two levels, and decodes each string to
reject malformed surrogate escapes. Additional executed regression established
Foundation accepts trailing commas unlike JSON.parse; the scan explicitly rejects
comma-before-object/array-close outside strings. No parser dependency was added.

Aggregate validation rejects every timed/untimed source or untimed section from
missingChunks, and validates version/revision/status, aggregate presence versus
state, sorted unique in-range missing indices, complete/partial missing semantics,
and inner/outer missing equality. Existing source range/ordinal checks remain.
The model already validates before aggregate save/publication, so no model change
was necessary. Actual URLProtocol->CloudClient->model->disk/reopen tests prove both
timed and untimed forged provenance plus inconsistent complete/missing state leave
the previous aggregate AND lastReadableAggregate intact. Status can still refresh;
the failure does not replace the saved readable partial with forged content.

### Executed failing-first and passing evidence

Environment: repo root, macOS26.4(25E246) arm64, Swift6.3.3, existing Swift5 mode.

- Before production edits:
  `swift test --disable-automatic-resolution --filter 'BatchIntegrationTests.test.*Regression'`
  exited1: three tests,13 failed assertions,1.210s. Exact raw
  `{"version":1,"segments":[{"text":"x"}]}` did not throw. Timed301s partial with
  missingChunks[1] and295000..296000/source1, plus untimed/source1, did not throw;
  actual model accepted and replaced saved/published/reopened partial content.
- Same regression command after fix exited0: three tests,zero failures,1.021s.
- Added strict syntax test:
  `swift test --disable-automatic-resolution --filter BatchIntegrationTests.testStrictRawSchemaUnicodeAndByteBoundaries`
  exited1 before trailing-comma correction: one test,one failed assertion,0.205s
  for `{"version":1,"segments":[],}`. This is fixed, not skipped.
- Final scoped `swift test --disable-automatic-resolution --filter BatchIntegrationTests`
  exited0:19 tests,one intentional fixture-generation skip,zero failures,3.431s.
  Coverage includes each missing nullable key, root/segment extras, duplicate and
  Unicode-escaped keys, malformed syntax/surrogates, number-vs-bool/fractional values,
  raw/text/speaker/segment inclusive boundaries and one-over, allowed Unicode/raw
  byte retention, invalid missing/state combinations, direct and model regressions.
- Final `swift test --disable-automatic-resolution` exited0:103 tests,three
  intentional skips,zero failures. Existing CoreData/XPC diagnostics persist.
  Skips: long capture, exact120 opt-in, tiny fixture generation. Accepted120 evidence
  was not rerun by this correction; Lead's reported9.359s proof remains separate.
- `git diff --check` passed. `shasum -a 256` verified the complete original17-file
  artifact set: only the two source/test hashes above differ; helper/tests/old
  helper handoff and all committed synthetic fixture bytes remain unchanged.

No real service/provider calls, backend tests/writes, credentials, new dependencies,
signing, deployment, commits or orchestration. Parser/runtime overhead is not a
global resource-safety proof; this is schema/provenance rejection, not authenticated
provider truth or recomputation of aggregate equivalence. No acoustic/codec/server
readiness claim. Existing UI/production limits below remain. Batch chat remains an
unmet separately owned follow-on, not implemented or accepted here.

Correction scope complete for review. Native writes and exclusive Swift-build
ownership relinquished; no build remains active. Lead decides acceptance.

## Original integration snapshot and evidence (historical)

2026-09-25. Ready for Lead review, not self-accepted. This is actual native workflow
wiring, not another disconnected helper. All assigned native write scope and
exclusive Swift compilation ownership relinquished at handoff. No build remains
running. No backend deployment, gate activation, credentials, real network/provider
call, signing, commit/push, new dependency or orchestration occurred.

## Base, contract and complete snapshot

Repo `/Users/tubakhuym/projects/lessmeet`, original base
`b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty candidates.
Shared/local protocols and COMPLETE frozen `docs/BATCH_CONTRACT.md` read first.
Contract SHA-256: `5c22fd88a98cd86659ff0c7eb8d7cf8851a9744454cebba9d54f04d4e3633412`.
STATUS latest integration section inspected. No shared/backend files changed.

All changed paths, SHA-256 before/after (ABSENT means newly created):

| Path | Before | After |
| --- | --- | --- |
| Sources/LessMeet/Cloud/CloudClient.swift | `c689e20ba787e3c6051fbb89b970aaa7d8a6865a3e9c617bbd0369e03d776d1b` | `a325ef818a3c2ff69d9653d6036a9fe037a7507d8c3c29f4d59dbdc3339a168c` |
| Sources/LessMeet/Cloud/TranscriptionBatch.swift | ABSENT | `0605d6e74765ed89b228b9bd6e83f60cf7c749fac2a7773117e341fe96163adf` |
| Sources/LessMeet/Recordings/Recording.swift | `deebb55ff5ba3e1e680d056cf019dc12c43ce73ce874b1f279b59e116180f0d9` | `c20be6be8c134e4403041ff6829d74ba57160a194d3a97c455374417fb9c10c1` |
| Sources/LessMeet/Recordings/RecordingStore.swift | `9cf82028f38e85a5887ccb4f5affb43532399c8f84091a0ec5b5721a34be6182` | `b1ed0c93f2ae10881f0cd32a4c5a87076f0db1e2c89997256beabd9306316b2b` |
| Sources/LessMeet/Presentation/RecordingCloudModel.swift | `0113383f5ef13b9b3cb61824d4f43d3b155999f1682c06fbb82792e289ae7210` | `2f8943f571ac92cbaf193105777f05b6b710f92872f5889a4ebb24e20cc77bf1` |
| Sources/LessMeet/Presentation/LibraryView.swift | `48b69348d48e9dbc60330af307a121b5fac17a1143520385a4eff97ee79d337e` | `caf8894e9e76267fafbd00b1e23c06515fafa31e93fad03a2bdce5453e24fe3b` |
| Sources/LessMeet/Presentation/BatchTranscriptView.swift | ABSENT | `238ad971b6f5fea4e54fabb961839120b45c8032d33578b6ce3b95d731d579ff` |
| Tests/LessMeetTests/RecordingCloudModelTests.swift | `4c5cc9be6c4b7a6a371ba6b801494f74e66e1aa945b249fafa5ceaf3e20d41d1` | `6b57e3ffa092cd1fd5dfe08984d5f8fc774bbecfa2b36bdb886325227b2100d4` |
| Tests/LessMeetTests/BatchIntegrationTests.swift | ABSENT | `a56f7374bf3d053b568c63ef4db41b804bac7d29904b8677eda1ae955002c41e` |
| Tests/fixtures/batch-native/system.caf | ABSENT | `af3af515f2f3536c609df841b66b12f9d2cdfa4b108c2d3911c04611a7db9c90` |
| Tests/fixtures/batch-native/combined.m4a | ABSENT | `210677dbc40079130e9dce06fd93df17133dead2c696565590f246a51a574863` |
| Tests/fixtures/batch-native/chunks/chunk-00.m4a | ABSENT | `210677dbc40079130e9dce06fd93df17133dead2c696565590f246a51a574863` |
| Tests/fixtures/batch-native/chunks/manifest.json | ABSENT | `9f9d7e641fa06edbb61400d6f72b977db634d20c8d15068ed779026178cc5474` |
| Tests/fixtures/batch-native/wire-manifest.json | ABSENT | `e2050556b9325b748fefeba93d53bb860ab4d4449851de701081037339ffab08` |
| Tests/fixtures/batch-native/evidence.json | ABSENT | `e9bdfba0ec16da60be7211d36bba1abce049b50b5cbf8852e0bdddf98b39a409` |
| Tests/fixtures/batch-native/digest-vectors.json | ABSENT | `f7e64d91c49bc4bbd7085ea60c21ad28f7c53ef67b70f443b1dc0323470309fa` |
| Tests/fixtures/batch-native/ui-saved-partial.png | ABSENT | `56083be312193fdb622f4aa4aa15715d72ffb8c9a4dba7c69d16b9d8cc78bbff` |
| Tests/experiments/chunking/NATIVE_INTEGRATION_HANDOFF.md | ABSENT | Final response supplies this document's hash, avoiding self-reference. |

Accepted helper/test/handoff remain unchanged, respectively:
`f7091bd10383d12294a854f37182869dc1c8887759cf14ddfbb29af2c7bba27d`,
`a898705f90ec11450e1a4726d7718bb03ac6bbb8ce4416deeb75a855fc175905`,
`4a75859d7883bd117b6009bb74be45840ff76ffb8526710c9262994b898bb9b9`.
Package.swift remains `d84a648912e37e25eeaaccbff3e09c37977b2dc9cea4b0ade610692a4b7036f2`.
Other existing dirty candidates and concurrent backend-writer changes were not edited.

## Implemented workflow and decisions

- Create Transcript now invokes accepted native preparation, rational wire reduction,
  batch creation, streamed chunk PUTs and explicit seal through CloudClient. No
  fallback to legacy upload on503 or other failures. The original legacy transport
  remains as `transcribeLegacy()` for its existing regression tests; legacy caches,
  decoding and chat remain separate. UI new-transcription action uses `transcribe()`.
- Source duration is a reduced positive Int64/Int32 rational. Checked multiplication,
  safe-integer validation, exact7200/300 caps and native canonical window checks
  precede canonical UTF8 compact-array SHA256. No names, paths, decoded claims,
  caller-selected quota or ms-rounded source duration enter the wire manifest.
  The only ms projection is the contract's ceil envelope for display/aggregate;
  raw timed ends are checked against floor(1000*exact chunk duration). Sub-ms input
  therefore permits paired-null timestamps/zero segments, not an invented1ms span.
- Implements exactly the versioned create, lookup-by-clientBatchId, raw chunk PUT,
  seal, failed-chunk retry, original result and aggregate routes. Requests use fresh
  bearer tokens and reject redirects. JSON control requests are bounded16KiB.
  PUT streams the checked local file with Content-Length; mock transport reads and
  hashes those actual bytes. Responses are read with bounded AsyncBytes accumulation
  (status128KiB, raw escaped envelope6*384KiB+4KiB, aggregate envelope384KiB+16KiB),
  then raw text/compact aggregate are separately checked against384KiB. Slash escaping
  is disabled for compact aggregate size measurement, matching JS JSON.stringify.
  Batch error text is locally generated from HTTP status, not echoed server content.
- Optional `Recording.batches` dictionary is backend+account-scoped independently
  of the legacy cache. Durable clientBatchId, immutable manifest and relative chunk
  paths are saved in recording.json BEFORE any network request. Each mutation gets
  a saved pending-operation record BEFORE sending; retry includes the lowercase UUID
  requestId and exact attempt/fence. Results/status are saved atomically before
  publication into AppModel. Relative paths permit reopening/moving the library;
  saved paths are checked against their canonical batch UUID/index before use.
- Response loss leaves the pending record. Refresh looks up clientBatchId and only
  reconciles/reads; it never generates. Continue is an explicit user action which
  first reconciles, then resumes only missing uploads or an unsealed all-uploaded
  batch. An unresolved admission/unknown generation cannot be automatically rerun.
  If a lost create is definitively absent, explicit Continue reuses the SAME UUID
  and manifest, not a new batch. Same failed-attempt explicit retry reuses its saved
  nonce after loss; attempt advancement/unknown or success makes further retry
  ineligible. The native path has no application-level mutation retry loop.
- Account/session/selection/generation fences run after token acquisition and before
  every save. A late response cannot publish under a replacement account/session.
  Cancellation stops local work/waiting, never claims remote generation stopped.
  No background polling is added: initial submit reads progress, and Refresh is
  on demand, including after reopen. One saved batch per recording/account/backend
  prevents accidental fresh generation of successful chunks.
- UI/library status now reflects prepared/processing/partial/attention/complete
  batches. Detail shows completion counts, perchunk states and enclosing ranges,
  unresolved operations, cleanup warning, missing output, explicit failed-chunk
  retry confirmation and saved aggregate revision. A last readable partial view is
  retained if a newer aggregate is pending/too_large and labeled as earlier data.
  All fetched original JSON strings remain unchanged and keyed by index:attempt;
  disclosure labels expose chunk/attempt and derived text shows segment provenance
  and chunk-local speaker labels. No global speaker identity inference.
- Batch chat is explicitly unavailable. If a legacy transcript exists, its existing
  chat remains usable but is labeled LEGACY and not presented as batch chat. Original
  audio and legacy transcript/messages remain unchanged. Batch service503 yields a
  recoverable disabled/unavailable notice with preparation/identity still saved.

## Verification and actual results

Environment: macOS26.4(25E246), arm64, Apple Swift6.3.3, MacOSX26.5 SDK, existing
Swift5 package mode. All commands run in repo root. No real provider/network access.

Commands actually run:

1. `swift test --disable-automatic-resolution --filter RecordingCloudModelTests`
   PASS4 legacy tests after integration,0 failures,0.081s.
2. `swift test --disable-automatic-resolution --filter BatchIntegrationTests`
   Incremental passes:8 tests; later11 tests/1 fixture-generation skip,0 failures,
   1.323s. One intermediate build failed on an XCTest Int-vs-Int64 assertion with
   Swift's "failed to produce diagnostic" error; fixed by explicit Int64 conversion.
   No failed fixture assertion was hidden or converted to a skip.
3. `LESSMEET_BATCH_NATIVE_FIXTURE=1 swift test --disable-automatic-resolution --filter BatchIntegrationTests.testGenerateNativeBackendFixtureOptIn`
   PASS1 test,0 failures,0.076s. Created the bounded synthetic artifacts above.
   Generator refuses to overwrite this directory; later opt-in runs skip if present.
4. `LESSMEET_BATCH_UI_SNAPSHOT=1 swift test --disable-automatic-resolution --filter BatchIntegrationTests.testSavedPartialViewRenders`
   PASS1 test,0 failures,1.055s.900x700 panel snapshot saved and visually inspected:
   missing-chunk warning, range/state, retry action, partial text, local-speaker
   provenance and original-result disclosure are readable without clipping.
5. `swift test --disable-automatic-resolution`
   First full pass97 tests/3 skips,0 failures,11.410s. FINAL snapshot full pass:
   **98 tests,3 intentional skips,0 failures,11.232s**. Skips are existing opt-in
   long capture, accepted120min chunk probe, and native fixture generation.
   Existing CoreData/XPC synthetic diagnostics persist; no new compiler warnings.
   Accepted120min proofs were not rerun. Existing bounded dense/stereo regressions
   ran as part of full Swift and passed; accepted helper files remain unchanged.
6. `git diff --check` passed. `shasum -a 256`, `sw_vers`, `swift --version`,
   `git rev-parse HEAD`, `wc -c` and scoped fixture inventory established this snapshot.
7. Independent `node -e` runs using built-in crypto/assert/fs (no imports from backend,
   no dependencies) verified five canonical vectors and the emitted Swift fixture.
   Final output: `PASS five JS canonical vectors + Swift native fixture canonical/digest/source/chunk checks 9812a2b6dd6d06eaf2fe302bc71b231449749f83fd32f4360a3d62bf3f63fba7`.

Equivalent JS reproduction for the independent digest/checksum check:

```js
const fs = require("node:fs"), crypto = require("node:crypto");
const assert = require("node:assert/strict"), p = "Tests/fixtures/batch-native/";
const read = f => JSON.parse(fs.readFileSync(p + f, "utf8"));
const hash = x => crypto.createHash("sha256").update(x).digest("hex");
const v = read("digest-vectors.json");
for (const x of v.vectors) {
  const slots = Array.from({length:x.chunks}, (_,i) => [i,v.chunkSHA,v.firstChunkBytes+i]);
  assert.equal(hash(JSON.stringify(["lessmeet.batch.geometry.v1",v.sourceSHA,
    v.sourceBytes,x.value,x.timescale,slots])),x.digest);
}
const w = read("wire-manifest.json"), e = read("evidence.json"), n = read("chunks/manifest.json");
const canonical = JSON.stringify(["lessmeet.batch.geometry.v1",w.source.sha256,
  w.source.bytes,w.source.duration.value,w.source.duration.timescale,
  w.chunks.map((x,i) => [i,x.sha256,x.bytes])]);
assert.equal(canonical,e.canonicalJSON); assert.equal(hash(canonical),e.manifestDigest);
assert.equal(hash(fs.readFileSync(p+"combined.m4a")),w.source.sha256);
for (const [i,x] of w.chunks.entries()) {
  const b = fs.readFileSync(p+"chunks/"+n.chunks[i].file.name);
  assert.equal(b.length,x.bytes); assert.equal(hash(b),x.sha256);
  const d = n.chunks[i].window.duration;
  assert.equal(BigInt(d.value)*BigInt(w.source.duration.timescale),
    BigInt(w.source.duration.value)*BigInt(d.timescale)); // one-chunk fixture
}
```

The14 batch test methods exercise actual RecordingCloudModel -> CloudClient ->
URLProtocol -> RecordingStore/AppModel paths, not a disconnected fake model:
durable identity/body/digest/pending records before every request; streamed upload
byte/hash equality; full create/upload/seal/result/cache/reopen; account/backend
isolation and original preservation; response loss at create/upload/seal; same-key
recovery with no automatic repeat; default503 then explicit resume; disk failure
before first network, before status publication and before aggregate publication;
account switch before response; retained partial data through unknown/pending;
too_large with missing raw then recovery; explicit retry nonce across reopen;
unknown/successful chunk retry exclusion; raw oversize and manifest-digest mismatch
rejection; sub-ms timestamp rejection and invalid provenance; UI rendering.

## Usable downstream fixture

`Tests/fixtures/batch-native/chunks/chunk-00.m4a` is a synthetic440Hz mono tone,
44100Hz,132301 frames, exact132301/44100 seconds (ceil display3001ms).
Derivative12288 bytes; requested rational range, actual native duration/count,
channel/rate and checksum are in `chunks/manifest.json`. `wire-manifest.json` is
the EXACT v1 network manifest; `evidence.json` records canonical JSON and digest.
CAF268698 bytes and combined M4A12288 bytes are retained synthetic input evidence.
Total audio293274 bytes. Combined and derivative have identical hashes in this
run: hashes bind actual bytes, not an assumption that export always changes bytes.
No acoustic, re-encoding-quality, hostile-media or server-decoding claim.

Lead can pass these owned fixture paths to backend acceptance without any native
code import. Structural admission against K's new backend was NOT run by this Peer;
server storage/worker/billing/deletion effects remain its separate verification lane.

## Remaining limits and next acceptance checkpoint

No wire/size/precision contradiction was observed against the frozen spec. Native
fixtures/mocks do not prove compatibility with the final backend implementation,
live JWT/allowlist, HTTP streaming through Convex, provider generation, actual
default-off deployment state, save/reopen across crashes/power loss, signing or
TestFlight delivery. Batch chat is intentionally unavailable. Full-window navigation,
retry dialog interaction/accessibility and human acoustic/model quality are untested;
the image proves one offscreen saved-partial panel only, not full UI acceptance.

The local cache is account/backend scoped, not encrypted or a hostile-filesystem
boundary. Before/after source checks and checked paths do not lock files against
concurrent replacement/symlink attacks by another local writer. If preparation
finishes but a context change/first metadata write fails, an unreferenced completed
batch directory can remain locally; no network has occurred then. Originals are
preserved; no automatic destructive cleanup of completed artifacts was added.
Atomic recording.json saves precede publication but do not promise power-loss fsync.
Read response accumulation is bounded in application code, not a global bound on
URLSession/decoder/system resource use. Platform decoder concealment and unknown
remote-side effects remain outside native proof. Source identity is only a server
declaration; never use native checksum/decoded claims as server admission authority.

Candidate is complete for the requested native integration scope with these limits.
Lead owns acceptance, final cross-lane backend/fixture verification and any live
activation decision. Write and Swift-build ownership explicitly relinquished.
