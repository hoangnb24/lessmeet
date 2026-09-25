# Native local chunk preparation — current 300/295/5 candidate

2026-09-24. Implements Lead's newly authorized shared geometry:300-second windows,
5-second overlap,295-second stride, <=7200 seconds total, at most25 slots. This
section supersedes ALL600/590/10 geometry and conversion guidance in the historical
sections below. Ready for Lead acceptance, not self-accepted. All scoped writes
and exclusive Swift compilation ownership relinquished; no build process remains.

## Current deterministic snapshot

Base remains `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty inputs.
Shared/local protocols reread first. Only the same three owned paths changed.
SHA-256 before/after:

| Path | Before | After |
| --- | --- | --- |
| Sources/LessMeet/Cloud/TranscriptionChunks.swift | `5d50cbcd8dd0d8d5293ea19459d1b85ffe1282557479c4d5de7f9b72b4b6eb2f` | `f7091bd10383d12294a854f37182869dc1c8887759cf14ddfbb29af2c7bba27d` |
| Tests/LessMeetTests/TranscriptionChunksTests.swift | `e2a67b453b6f9b7d03f5d9ae31c12767b528438ea103e245190b731c83a6d338` | `a898705f90ec11450e1a4726d7718bb03ac6bbb8ce4416deeb75a855fc175905` |
| Tests/experiments/chunking/NATIVE_HANDOFF.md | `f42f700db901173f462c90688a266039d1ebc805d789d2503f5171b8faaf2b64` | Final response supplies document hash, avoiding self-reference. |

CaptureAudioRecorder, LongCaptureTests and Package.swift were rehashed unchanged;
full before/after hashes remain the original input table below. No other files,
DTOs, network/UI, backend or dependencies changed; no cross-scope imports. No
bitrate/preset changes, paid calls, upload, deployment, credentials or commit/push.

## Migrated contract and retained validation

Half-open rational windows now use start=295*i, end=min(start+300,T), stopping at
the first end=T. At7200s:25 chunks, first24 each300s, final [7080,7200)=120s,
total7320s. Exact300s =>1 chunk;595s =>2; no redundant overlap-only tail. Adjacent
overlap is exactly5s. Planner tests exercise +/-one frame at295/300/590/595/7200
for24k/44.1k/48k. Source total cap remains7200s; historical7200.4993 is rejected.

Actual generated presentation cap is now300s, with the prior exact-or-reject
duration/sample-representability policy unchanged. Real301s output is rejected
even if its requested range agrees. Real stereo44.1k/48k fractional export tests
now straddle300s +/-one frame (also3s +/-one frame);300s+one frame produces exactly
300s then5s+one frame. Actual decoded counts and presentation equal requested
rational durations. AAC-LC/track/channel/rate checks, full8192-frame-buffer decode,
cancellation/read-error/zero-progress checks,18MiB cap, source identity, no-overwrite
publication and owned-only staging cleanup remain enforced and regression-tested.

The native manifest remains local, version1 and rational. Later integer-ms geometry
would be N=1+ceil(max(0,T-300000)/295000), startMs=295000*i,
endMs=min(startMs+300000,T), but rational-to-ms conversion is STILL UNRESOLVED for
nonintegral endpoints. No silent rounding or DTO adapter was added. Native decoded
frames are presentation PCM after decoder priming/remainder handling, not raw
AAC packet count. No sample/packet tolerance or lossy-quality change was introduced.

## Commands and observed results for this snapshot

Environment unchanged: macOS26.4(25E246), arm64, Swift6.3.3, MacOSX26.5 SDK,
Swift5 language mode. Commands run at `/Users/tubakhuym/projects/lessmeet`:

1. `swift test --disable-automatic-resolution --filter TranscriptionChunksTests.testRealDenseStereoPreviouslyOversizeSucceedsWith300SecondWindows`
   PASS1 test,0 failures,5.363s. Same dense48kHz stereo PCM fixture,28799999 frames,
   continuous tone data (NOT replaced by silence). Source before=after SHA:
   `3b42302eb2f92a85ac102fa00b88a2453a6617bf2e96d7969ed68e44ca498535`.
   Unchanged capture exporter reproduces the old single-window18950335-byte result
   above18874368 bytes. New helper produces three outputs:
   bytes `[9478413,9432234,321331]`, actual decoded frames
   `[14400000,14400000,479999]`, all48kHz stereo. Source and historical combined
   output identities preserved. Every new output fully decoded both by production
   validation and an independent bounded read loop in the test. Durations exactly
   300s,300s,479999/48000s. No staging directory remains.
2. `LESSMEET_EXACT_CHUNKS_120=1 swift test --disable-automatic-resolution --filter TranscriptionChunksTests.testOptInExact120Minutes`
   PASS1 test,0 failures,9.309s. CAF and combined AAC each25 outputs; source hashes
   preserved. The same independent295s watchdog and2.5GB disk guard (100ms polling)
   cover both routes. Neither fired. Source fixture remains exact7200s, never the
   historical overlimit capture. Cumulative measured9.300208s.
3. `LESSMEET_EXACT_CHUNKS_120=1 swift test --disable-automatic-resolution`
   PASS84 tests,1 intentional original LongCapture skip,0 failures,18.243s.
   All10 chunk tests ran,17.848s. Dense regression5.273s; exact120min test9.310s;
   stereo fractional tests2.455s. Existing synthetic CoreData/XPC diagnostics only;
   no new compiler warnings or failed check. No failed run in this migration.
4. `git diff --check` passed. `shasum -a 256` and `git rev-parse HEAD` verified
   candidate and unchanged input identity.

Final full-run120min evidence:

- CAF345604096 bytes, before=after SHA
  `c6fb09626136c728ce19a048acde26312694ae713332cbff3e789498bb58017b`.
  25 derivatives total3981307 bytes; largest169717 bytes; first24 each7200000
  actual frames and final2880000 frames,24kHz mono. CAF stage measured5.101113s.
- Recorder-produced exact7200s combined AAC3844729 bytes, before=after SHA
  `36f2267cf7688bb054f4903c47d29053246eec94a8497fe5d4b04b57cd8b5b62`.
  25 derivatives total3940328 bytes, same exact actual-frame geometry. All fully
  decoded by production validation. Cumulative measured9.301883s. Sum of retained
  audio357370460 bytes plus two small manifests, below3GiB, with runtime disk guard.
- Both routes explicitly assert25 chunks, last120s and total7320s. The ordinary
  synthetic tone/silence fixture moved its boundary markers to295/299s to test the
  new overlap, hence a new CAF hash relative to the historical fixture. The dense
  regression fixture above was NOT changed. AAC container hashes vary between runs.
- Short combined route now301s =>300s and6s. Original CAF/combined/timeline hashes
  preserved; tone/silence windows at295/296/299/300 positioned correctly. Measured
  threshold crossing23999 versus24000 is reported only, not an admission tolerance.

Durable evidence is this report and deterministic tests in the same owned test
file; reruns print hashes, sizes, rational durations and actual decoded counts.
Synthetic scratch removed by test defers; no personal data touched. No watchdog
termination or orphan scratch was observed.

## Limits / ownership

The dense failure is resolved for the REAL tested input by300s geometry, without
changing audio or encoding settings. This is NOT proof that every300s source stays
under18MiB: size remains checked after export and still fails closed; no guessed
bitrate cap or automatic fallback. Full120min evidence is synthetic24k mono; dense
48k stereo proof spans just under600s. Other admitted rates, hostile containers,
decoder concealment and arbitrary edit lists remain unverified. No acoustic or
transcription quality, server trust, global resource safety, network/UI integration
or TestFlight-delivery claim. Local caller-controlled filesystem/source immutability,
best-effort cleanup/crash limits and priming semantics from hardening remain.
All native writes and Swift compilation ownership relinquished to Lead, who owns
acceptance and the still-unresolved integer-ms integration decision.

---

# Historical 600/590/10 output-validation revision (accepted; superseded above)

2026-09-24. This revision supersedes the original candidate's output-validation
claims and limits below. Original was accepted by Lead ONLY as a disconnected
primitive. This revision is ready for Lead review, not self-accepted. Native write
and exclusive Swift compilation ownership relinquished at this handoff; no build
process remains running. Integration remains Lead-owned and not authorized here.

## Revision snapshot (all changed paths)

Original base remains `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty
inputs. Shared/local protocols reread; target resolved explicitly. No writes beyond
the same three paths. All hashes are SHA-256:

| Path | Before | After |
| --- | --- | --- |
| Sources/LessMeet/Cloud/TranscriptionChunks.swift | `2a6d53771fc0c889ef8f8ccf31d4a88eb97e8a30891aaa66460263eca15d75dd` | `5d50cbcd8dd0d8d5293ea19459d1b85ffe1282557479c4d5de7f9b72b4b6eb2f` |
| Tests/LessMeetTests/TranscriptionChunksTests.swift | `cb75166d63e3219314998fd88e0083c3bfe1899a0241783efd7d26b8847ea499` | `e2a67b453b6f9b7d03f5d9ae31c12767b528438ea103e245190b731c83a6d338` |
| Tests/experiments/chunking/NATIVE_HANDOFF.md | `0de10d5f92024d9dc3bf9cd6b3dbc48144dc823091effbf7568a6a58c16f1a09` | Final response supplies this document's hash, avoiding self-reference. |

CaptureAudioRecorder, LongCaptureTests and Package.swift still match BOTH original
before/after hashes in the historical table below. No changes to network/UI/API,
backend, dependencies, capture, encoding preset, bitrate, shared contracts or files
owned by other writers. No personal recordings, credentials or external actions.

## New enforced output contract

Before publication every derivative is inspected as actual media, not just trusted
exporter metadata: exactly one zero-origin audio track, no video, track duration
equal to asset presentation duration, AAC-LC, one or two channels. Allowed actual
sample rates exactly match existing `convex/media.ts` admission policy:
8000,11025,12000,16000,22050,24000,32000,44100,48000 Hz. Set membership excludes
nonfinite/nonintegral/out-of-policy values. Both AVAsset format description and
AVAudioFile compressed/processing formats must agree in rate/channels/codec.
Local SDK CoreAudioBaseTypes.h identifies `kAudioFormatMPEG4AAC` as MPEG-4 Low
Complexity AAC (no flags); this native identifier is used, not a new bitstream parser.

**Precision decision: exact or reject.** Actual presentation must be positive,
<=600 seconds and rationally EQUAL to the requested window duration. Its conversion
to the actual output sample rate must also be exact (conversion is checked by
CMTime equality, never accepted just because conversion returned a rounded value).
No sample/packet tolerance, trim, rounding or >600-second exception is implemented.
Fractional seconds ending on a PCM frame work in the tested formats. A one-frame
duration mismatch or a half-frame requested endpoint rejects. This is NOT a policy
for network millisecond rounding; that remains an explicit integration decision.
No failure of exactness was observed in the actual exported fractional fixtures,
so no alternate quantization policy or scope expansion was needed.

`decodedFrames` now counts frames actually returned by AVAudioFile reads, not just
its declared length. Reads use a reusable8192-frame Float32 mono/stereo buffer
(at most65536 bytes of application PCM). Declared presentation length must first
equal the exact sample count implied by actual presentation duration. Every frame
through that length is then read; zero progress, more-than-requested frames, read
errors, final position/length mismatch and cancellation reject. Cancellation is
checked before each read and after the final read. The manifest is published only
after full validation and the unchanged source-identity recheck.

AAC priming/remainder semantics: these are the PCM presentation frames returned by
AVAudioFile after native decoder priming/edit handling, NOT raw AAC packet count
times1024. The reader is bounded by the declared presentation frame length, then
compared with actual reads/position and exact requested duration; it does not read
beyond that endpoint to count encoded padding. The prior1024-frame assertions were
removed. The tone's measured threshold crossing is reported, not used as media
admission tolerance or proof of waveform identity. Lossy re-encoding remains.

Two narrow test seams were added: a post-export closure runs BEFORE every ordinary
admission check; a bounded frame-count loop accepts a read closure for deterministic
read-error/stall/cancellation tests. Neither bypasses checks or is connected to UI/
network. Production uses the unchanged two-argument prepare entry point.

## Revision verification

Same macOS26.4(25E246), arm64, Swift6.3.3, MacOSX26.5 SDK and Swift5 language mode.
All commands ran in `/Users/tubakhuym/projects/lessmeet`:

1. `swift test --disable-automatic-resolution --filter TranscriptionChunksTests.testStereoFractionalPresentationPrecision`
   First probe failed after7.103s because dense48kHz stereo near600s exceeded18MiB,
   NOT because of a precision mismatch. 44.1kHz cases and short48kHz cases had exact
   presentation and frame lengths. A separate dense oversize regression now retains
   that finding. Longer precision fixtures use a short tone followed by silence to
   isolate precision from size admission (no production encoding change).
2. Same command after output-validation implementation and fixture separation:
   1 passed in5.013s, including both stereo rates and all fractional cases.
3. `swift test --disable-automatic-resolution --filter TranscriptionChunksTests`
   10 tests,1 intentional120min opt-in skip,0 failures,8.021s.
4. FINAL SOURCE/TEST SNAPSHOT:
   `LESSMEET_EXACT_CHUNKS_120=1 swift test --disable-automatic-resolution`
   84 tests,1 intentional original LongCapture skip,0 failures,17.868s;
   all10 chunk tests passed in17.485s. Opt-in test9.109s. No new compiler warnings;
   existing synthetic CoreData/XPC diagnostics persisted without failed tests.
5. `git diff --check` passed; `sw_vers`, `swift --version`, `git rev-parse HEAD`
   and `shasum -a 256` verified environment/base and all candidate/input hashes.

Specific actual coverage:

- Stereo44100/48000 exports at3s minus/plus one frame and600s minus/plus one
  frame. Exact input presentation, output presentation, channel/rate and actual
  decoded counts all agree. For600s+one frame, first derivative is exactly600s;
  second is10s+one frame. No gap, extra tail, hidden rounding or cap exception.
- Real601s combined AAC passed to the output validator directly rejects even
  with a requested601s range. A real valid fractional output supplied with a
  one-frame-short or half-frame-long requested duration rejects. PCM CAF supplied
  as an output rejects. Geometry +/-one-frame tests from the original remain.
- Count-loop seams reject zero total length, initial zero progress, late zero
  progress, excessive returned frames, thrown decoder error, and cancellation
  between reads. Legitimate partial reads are accumulated rather than assumed
  to equal each requested buffer length. Final actual position/length checked.
- Source append fault injected after export leads to `sourceChanged`; helper
  preserves the bytes intentionally changed by the TEST and does not rewrite the
  source. Truncated128-byte generated output rejects, as does an output extended
  to18MiB+1. Each case leaves source and unrelated sentinel only, no destination
  or owned staging. Active cancellation and concurrent-destination tests still pass.
- Real dense48kHz stereo fixture: generated18950335 bytes >18874368-byte cap.
  Fails closed; original SHA unchanged; owned staging removed. This is a real
  unchanged-preset oversize result, not merely a size-guard unit test. Making this
  input succeed would require a separate Lead encoding/quality-policy decision;
  the primitive intentionally does not retry, lower bitrate, or shorten geometry.

### Bounded120-minute CAF AND combined-AAC results

Same opt-in test/watchdogs cover both routes, with one295s independent global-queue
process-exit timer and100ms disk guard at2.5GB. Neither fired. Input is new exact
7200s/172800000-frame24kHz mono PCM, not the historical7200.4993s fixture.

- CAF source345604096 bytes; before=after SHA
  `a597f8c8ba0e11e570c0e1dadc974d841fca77d5483cf296bbe0084acdd1d324`.
  CAF route13 derivatives totaling3982504 bytes; largest329668 bytes.
  Fixture/export/source hashes/production full decode plus independent test decode
  completed in4.894575s.
- Then unchanged CapturedAudio.exportCombined produced exact7200s combined AAC,
 3841047 bytes; before=after SHA
  `10950522266d0ed5de392854211ef2a22890dbbcfae6f20bd83e251727a8df10`.
  Re-encoded AAC route13 derivatives totaling3922174 bytes. Each was fully decoded
  by production validation. Cumulative elapsed9.102214s; entire test9.109s.
- Both routes decoded first12 chunks to14400000 frames each (600s), final chunk
  to2880000 frames (120s), with exact requested presentation durations. Total
  submitted duration7320s. Both input identities preserved. Sum of retained audio
  bytes357349821 plus two small manifests, well below3GiB; runtime disk guard
  additionally checked the directory during processing. No peak-RSS claim.
- Short combined route still preserves CAF/combined/timeline identities and
  expected tone/silence positioning. Observed threshold crossing23998 versus24000
  expected is lossy-signal evidence only. Final short combined before=after SHA:
  `a3e25123c5bb19c5bc22bd748eb6497cc8f66df777f2261e483a8d2c54b8eb3e`.

Durable evidence: this report plus same-file deterministic tests, which print
precision/frame counts, identities, output sizes and timings when reproduced.
All synthetic scratch was removed by test defers; no personal audio or artifacts
were touched. Watchdog termination would leave only the printed unique scratch
directory for explicit cleanup; none occurred.

## Remaining limits / acceptance boundary

This is still a disconnected local primitive, not server safety evidence. It uses
native decoder behavior, including any decoder concealment; it does not validate
every AAC packet independently or prove raw-padding/sample payload semantics.
Real stereo44.1/48k and24k mono were tested; other admitted rates, pathological
edit lists, multi-track/video hostile fixtures, hardware capture/TCC and acoustic/
transcription quality are unverified. Structural multi-track/video guards are
implemented, but dedicated malformed-container fixtures for those guards were not
added. Corrupt-output test exercises rejection of a truncated container; decoder
error/stall paths additionally use deterministic read seams, not hostile AAC corpus
coverage. No global decoder/resource-security claim.

Exact sample-representable fractional endpoints were verified; arbitrary
sub-sample edit endpoints are not promised and cannot be silently quantized. If
integration must admit such inputs, REOPEN its precision contract. Integer-ms DTO
mapping still must be agreed by Lead. New full120min combined-AAC proof supersedes
the historical CAF-only limitation below, but is synthetic24k mono, not all audio.
Oversize rejection is a real usability limit; no bitrate/quality changes authorized.

Source/destination parent must remain caller-controlled, with source immutable.
Before/after hash checks are not a lock against mutate-and-restore or hostile
filesystem races. Cleanup remains best effort on filesystem errors/process death;
crash recovery and a production hard wall-clock watchdog are not implemented.
No network, UI, DTO integration, quota/batch aggregation or server trust added.
Lead decides acceptance; write and Swift compilation ownership relinquished.

---

# Historical original candidate (accepted disconnected-only; superseded above)

2026-09-24. Ready for Lead review, not self-accepted. All native write and Swift
build ownership relinquished at handoff. No remaining process/build is running.

## Snapshot and authority

Base HEAD: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`, plus the accepted dirty
inputs in STATUS. Shared and local WORKSPACE_PROTOCOL read first; existing
CaptureAudioRecorder export and LongCaptureTests inspected before implementation.
Only these three new paths were written (all before states: ABSENT):

| Path | After SHA-256 |
| --- | --- |
| Sources/LessMeet/Cloud/TranscriptionChunks.swift | `2a6d53771fc0c889ef8f8ccf31d4a88eb97e8a30891aaa66460263eca15d75dd` |
| Tests/LessMeetTests/TranscriptionChunksTests.swift | `cb75166d63e3219314998fd88e0083c3bfe1899a0241783efd7d26b8847ea499` |
| Tests/experiments/chunking/NATIVE_HANDOFF.md | Reported separately in final handoff to avoid a self-referential hash. |

Verified unchanged input before AND after hashes:

| Path | SHA-256 |
| --- | --- |
| Sources/LessMeet/Capture/CaptureAudioRecorder.swift | `ae88bea38136fb6cf358a7ef95040b3c68aa8e1e8fb94d974d1d51b287171e03` |
| Tests/LessMeetTests/LongCaptureTests.swift | `6fb76577092c5bc9616dd5b352a4af8ddbb6148e84c8d3d291b2d382d9f69d84` |
| Package.swift | `d84a648912e37e25eeaaccbff3e09c37977b2dc9cea4b0ade610692a4b7036f2` |

No CloudClient/UI/backend integration, new dependency, bitrate override, personal
audio, upload, credentials, paid API, deployment, signing, commit/push or agent
orchestration. Other dirty work remains owned by its existing writers.

## Usable primitive and contract

`try await TranscriptionChunks.prepare(source: closedCombinedURL, destination: newDirectoryURL)`
returns a version-1 Codable manifest and publishes `manifest.json` plus numbered
AAC-LC M4A derivatives in that directory. Parent directory must already exist;
destination must not exist. Source must stay closed and immutable throughout.
One zero-origin audio track, no video, PCM or AAC-LC, mono/stereo are supported by
the admission guard. CAF and recorder-produced combined M4A were actually tested.
Other formats fail closed; do not extend format policy without Lead review.

Planning uses exact CMTime rational comparison, never Double boundary rounding:
positive duration <=7200 presentation seconds; [start,end) windows <=600 seconds;
start=590*i; end=min(start+600,duration); stop as soon as end reaches duration.
No overlap-only tail: 600 =>1,1190 =>2,7200 =>13. At7200 the last window is
[7080,7200), and total submitted window duration is7320 seconds. Adjacent windows
overlap exactly10 seconds with no gap. Tests cover +/-one frame at24k/44.1k/48k
around590/600/1180/1190/7200, including rejection of7200+one frame and7200.4993.
The historical7200.4993 fixture was NOT reused or admitted.

Each chunk records stable index, rational source offset/duration, file basename,
byte length, SHA-256, actual asset presentation duration, AVAudioFile decoded-frame
length, sample rate and channels. Source identity includes basename, bytes, SHA-256
and rational presentation duration. Source identity is rechecked before publishing.
No durable source file path or account identity is recorded.

AVMutableComposition plus AVAssetExportPresetAppleM4A matches the existing capture
export choice; no bitrate setting or fallback compression policy is introduced.
Every derivative must report AAC-LC, nonempty positive duration and <=18MiB.
Oversize fails the entire preparation; no truncation, automatic bitrate reduction
or partially published manifest. Work is sequential and hashed with1MiB reads.
Only a uniquely created sibling `.chunks-UUID.partial` directory is cleaned up.
Successful output is moved to the new destination with no overwrite. Cancellation
uses the native async export operation plus explicit checks before publication.

### Later client conversion (not implemented)

This is a local rational-time manifest, NOT the backend/network DTO. Later client
code owns clientBatchId creation/persistence and mapping file.bytes to byteLength.
For an exact integer-millisecond source duration T, convert rational times only
when value*1000/timescale is exactly integral (use checked integer arithmetic),
set durationMs=T, startMs=590000*i, endMs=min(startMs+600000,T), and verify
N=1+ceil(max(0,T-600000)/590000). SHA-256 identifies the derivative bytes to upload.
Do NOT map exported priming/padding duration to source range endpoints.
Sub-millisecond source endpoints are retained exactly here: a future DTO adapter
must explicitly resolve their rounding policy with Lead, or reject conversion;
silently flooring/ceiling could change count or misstate coverage. No such adapter
or network DTO was requested. Source offsets and checksums are untrusted claims
server-side; independent server admission remains required. Quota/overlap billing
approval and transcript deduplication/aggregation remain separate work.

## Verification and reproduction

Environment: macOS26.4 (25E246), arm64, Apple Swift6.3.3,
SDK MacOSX26.5, package Swift5 language mode. Working directory:
`/Users/tubakhuym/projects/lessmeet`.

Commands actually run:

1. `swift test --disable-automatic-resolution --filter TranscriptionChunksTests`
   Initial run:4 tests,1 skipped,1 failure. Fixture incorrectly put a tone at600s
   while the assertion expected silence. Corrected fixture; rerun4 tests,1 skip,
   zero failures. Initial explicit cancellation closure produced a non-Sendable
   warning; removed in favor of native async export cancellation. Final builds
   produced no new compiler warning.
2. `LESSMEET_EXACT_CHUNKS_120=1 swift test --disable-automatic-resolution --filter TranscriptionChunksTests.testOptInExact120Minutes`
   Initial metadata/preservation pass:1 test,0 failures,4.422s. Added complete
   decoded-frame verification; first rerun failed with AVAudioFile nilError after
   reading past declared frame length. Corrected test to bound reads by remaining
   frames (same pattern as existing LongCaptureTests), not suppress decoder errors.
3. `swift test --disable-automatic-resolution`
   79 tests,2 intentional opt-in skips,0 failures,1.129s (before last test-loop fix).
4. **Final candidate:** `LESSMEET_EXACT_CHUNKS_120=1 swift test --disable-automatic-resolution`
   79 tests,1 intentional LongCapture skip,0 failures,5.560s. All5 chunk tests ran.
   Exact120-minute case4.430s; fixture/export/hash/full decode measured4.424483s.
   Existing synthetic CoreData/XPC diagnostics appeared; no failing test.
5. `git diff --check` passed. `sw_vers`, `swift --version`, `git rev-parse HEAD`,
   scoped `git status --short` and `shasum -a 256` established environment/snapshot.

Durable evidence is this report and the deterministic fixture/test code. Tests
print per-output hashes and metadata on reproduction. Synthetic scratch directories
are removed by test defers; no audio artifacts retained. On watchdog exit, the
printed unique scratch path may remain for explicit cleanup. No watchdog fired.

### Final observed results

- 601s synthetic CAF through unchanged CapturedAudio.exportCombined then helper:
  combined329856 bytes, source SHA-256 before=after
  `6289e4e56650a66f85071b00478fb9b4e5535becbad0acaefa173ce8df3c4cbc`.
  CAF and timeline sentinel before/after identities also compared equal in tests.
  Derivatives:600s/14400000 frames/329668 bytes and11s/264000 frames/9878 bytes,
  both24kHz mono. Their final-run hashes respectively:
  `4439fc0e34f427e1e66f3db8ee6913a13207baed68f6b2cf7989006922f60bbe`,
  `7c54374b86e9f9b9109b612e1daa862482ecc17924da9c7761b2f4c99573bdac`.
- At source590 and599, second chunk contains the expected tone; source591 and600
  are silent. Last loud frame at the first tone boundary=23998 versus24000 expected
  (2 samples early). Test allows one1024-frame AAC packet, not bit-exact recovery.
- Active-preparation cancellation observed staging before cancelling, rejected
  publication, preserved source SHA and unrelated partial sentinel, left no owned
  partial directory. Concurrent destination creation forced publish failure;
  unrelated destination sentinel and source survived and owned staging was removed.
- Exact120min input is a newly streamed24kHz mono PCM CAF,172800000 frames,
 345604096 bytes. Before=after SHA-256:
  `a597f8c8ba0e11e570c0e1dadc974d841fca77d5483cf296bbe0084acdd1d324`.
 13 outputs totaled3982504 bytes; largest329668 bytes. Each of first12 decoded
  exactly14400000 frames/600s; last2880000 frames/120s. Actual asset durations
  matched those frame durations. Full read through declared frame length succeeded
  for every output. Source+derivatives349586600 bytes plus small manifest, below
 3GiB. Independent global-queue295s process-exit watchdog and100ms disk guard at
 2.5GB protected the opt-in case; no personal input or historical overlimit fixture.
-18MiB equality admitted and18MiB+1 rejected by the exact production byte guard's
  unit test. A real encoder-produced >18MiB output was not generated, so that
  specific export-to-oversize-cleanup path remains unexercised end to end.

## Limits and acceptance decision

AAC export is lossy; combined AAC may be decoded and re-encoded, with new priming,
padding and generation loss. Exact source ranges do not promise bit/sample-exact
acoustics. Export duration and decoded frame count are recorded separately rather
than assumed equal to requested range. Container hashes can vary across exports
because of container metadata; manifest hashes bind the actual generated bytes.
No audible quality, transcription quality, live capture/TCC, UI/save-reopen,
network, upload, provider duration tolerance, server safety, quota, or TestFlight
delivery claim. The120min native proof uses CAF; short proof covers the actual
combined AAC route, not a120min combined-AAC re-encode. Real-export stereo/44.1k/
48k variants and arbitrary pathological edit lists are untested. Planner frame
boundary coverage at those rates is not codec quality proof.

Caller must keep source and parent directory under its control; this is not a
hostile-filesystem/symlink defense or source lock. Before/after hashes detect ordinary
source changes but not mutate-and-restore races. Crash recovery is not implemented;
best-effort defer cleanup can fail on filesystem errors and process death can leave
the unique partial directory. Native framework export runtime is not hard-capped
in production; watchdog bounds the opt-in experiment only. No workflow framework,
retry policy, transport, or aggregation was added.

Requested bounded local outcome is implemented and verified to the limits above.
Lead owns candidate acceptance and any downstream integration/precision decision.
