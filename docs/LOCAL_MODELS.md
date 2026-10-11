# Pinned local model catalog

`Sources/LessMeet/LocalModels/LocalModelManifest.swift` defines the static
`LocalModelCatalog.artifacts` input for an app-owned downloader. It does not
download, load, or verify installed models. No model payload was downloaded
during the initial catalog audit. Later runtime evidence appears below.
The catalog candidate starts at `714dc6f210bcacfc0d35408763c2351de4d47337`
on `pivot/local-models`; the original pivot base is
`b08b3cdae5aeb4cbbd5c771a5f887584afaa518c`.

## Inventory

| Artifact ID and local directory | Files | Exact bytes |
| --- | ---: | ---: |
| `whisper-large-v3` | 19 | 3,090,319,899 |
| `whisper-tokenizer` | 3 | 2,764,732 |
| `nemotron3-int8` | 14 | 107,083,235 |
| Total | 36 | 3,200,167,866 |

These are transfer sizes, not peak disk or memory requirements. Staging, resume
data, Core ML caches, and loaded models require extra space.

Immutable primary inventories:

- [Argmax Core ML large-v3](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3): all 19 files under `openai_whisper-large-v3/`. This is full large-v3, not Turbo.
- [OpenAI tokenizer](https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1): exactly `tokenizer.json`, `tokenizer_config.json`, and `config.json`.
- [Community Nemotron conversion](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8/tree/db823d36c2230d5535a6165c932f8a5369484b7a): both complete `Nemotron3Head.mlmodelc` and `Nemotron3PreEncoder.mlmodelc` bundles, plus `learnable_silence.f32`, `config.json`, `LICENSE`, and `NOTICE`. README, `.gitattributes`, and `run_chunk.py` are not runtime inputs.

## Downloader contract

1. Resolve each file at `https://huggingface.co/<repository>/resolve/<revision>/<path>`.
2. Place it below `<root>/<artifact.directory>/<file.path>` without flattening paths.
3. Check the downloaded byte count and raw SHA-256 against the catalog.
4. Publish readiness only after every required file passes verification.

For example, the Whisper encoder weight goes below
`<root>/whisper-large-v3/openai_whisper-large-v3/AudioEncoder.mlmodelc/weights/weight.bin`.
The Whisper model folder is `<root>/whisper-large-v3/openai_whisper-large-v3`,
not `<root>/whisper-large-v3`. The tokenizer folder is
`<root>/whisper-tokenizer`. The Nemotron folder is `<root>/nemotron3-int8`.

The catalog uses repository-relative paths and separate stable local roots.
It does not encode Hugging Face cache paths. Consumers must reject traversal
and symlink escapes, keep partial data separate, and verify bytes before use.
Static path tests do not establish filesystem confinement or downloader safety.

## Tokenizer selection

Source inspection used WhisperKit revision
`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`:

- [Hub.swift, `LanguageModelConfigurationFromHub.loadConfig`](https://github.com/argmaxinc/WhisperKit/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/ArgmaxCore/External/Hub/Hub.swift) reads `tokenizer.json`, optional `tokenizer_config.json`, and optional `config.json` from the local folder.
- [Tokenizer.swift, `AutoTokenizer.from(modelFolder:)`](https://github.com/argmaxinc/WhisperKit/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/ArgmaxCore/External/Tokenizers/Tokenizer.swift) requires the parsed tokenizer configuration. It constructs the tokenizer from that configuration and tokenizer data.

The pinned `tokenizer_config.json` names `WhisperTokenizer`. The pinned
`tokenizer.json` contains a BPE model with 50,257 vocabulary entries, 50,000
merge rules, and 1,609 added tokens. Separate `vocab.json`, `merges.txt`, and
`added_tokens.json` are not read by this path. Nor are `normalizer.json`,
`special_tokens_map.json`, or `preprocessor_config.json` required by it.
`config.json` is retained as agreed model metadata; it is not a strict minimum
for this tokenizer when `tokenizer_class` is already present. No extra file
requirement surfaced. This is source/data inspection, not a runtime load test.

WhisperKit's higher-level loader can fall back to the network after a local
tokenizer error. Model download being disabled does not prove offline behavior.
The integration must prove fail-closed loading separately.

## Hash evidence

The Hugging Face tree APIs were queried at the exact revisions on 2026-10-11.
For LFS entries, the catalog uses the published LFS SHA-256 and size. Those
payload bytes were not downloaded during that initial audit. The later runtime
check downloaded all 36 files and independently verified their hashes.
For small Git entries, the raw files were downloaded at the immutable revision.
Their byte counts and Git blob SHA-1 identities were checked against the tree.
SHA-256 was then computed over the raw bytes, not the Git object header.
All 36 catalog hashes have an observed source; none is a placeholder.

Raw inventory JSON, small files, source excerpts, and the reproducible collector
are retained under `.artifacts/model-audit/catalog-20261011/` (ignored).
`collect.mjs` refuses Git downloads above 3 MB. It does not fetch LFS payloads.
The checked-in Swift file is static; builds do not run the collector or use a
mutable branch. A future pin update needs a fresh inventory and review.

## Redistribution and provenance

Exact upstream texts are retained in `Resources/ModelLicenses/`.
`SOURCES.md` identifies the source and scope of each text. No package or app
resource configuration changed here. The packaging owner must include these
notices in the shipped app and verify their presence. This directory alone
does not prove redistribution compliance for the full dependency graph.

WhisperKit is MIT with embedded Apache-2.0 notices. speech-swift is Apache-2.0,
not MIT. OpenAI Whisper code and weights are MIT. The pinned Argmax model card
also declares MIT, but its repository has no root LICENSE file at this pin.
The included OpenAI text is identified as an upstream source license, not a
fabricated Argmax model-repository license.

Nemotron weights use OpenMDW-1.1. The converter's exact LICENSE and NOTICE are
both downloadable catalog files and retained redistribution texts. Preserve
their copyright and origin notices. The upstream NVIDIA source revision is
`a435e9867d79e789e90053f9b6d6834053af564a`; its
[model card](https://huggingface.co/nvidia/Nemotron-3-Diarization/blob/a435e9867d79e789e90053f9b6d6834053af564a/README.md)
declares OpenMDW-1.1. The compiled INT8 files are published by `aufklarer`, not
NVIDIA. Do not present them as NVIDIA-official binaries or an endorsement.

The [pinned converter card](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8/blob/db823d36c2230d5535a6165c932f8a5369484b7a/README.md)
reports warm CPU-only timing for short chunks on an M5 Pro. That check excludes
audio preprocessing and cache updates. Its separate speech-swift diarization
score is also an upstream report. Neither is a LessMeet benchmark. Treat this
integration as unvalidated until local long-file accuracy, memory, latency,
speaker continuity, and device compatibility checks pass.

## Validation boundaries

`LocalModelManifestTests` checks revisions, hashes, safe paths, unique entries,
exact sizes, complete bundle counts, notices, tokenizer selection, and the
non-Turbo model identity. Isolated `swiftc` verification uses only the catalog
and these tests; it does not build or resolve the app package.

On 2026-10-11, all six isolated XCTest cases passed on arm64 macOS 26.4
(25E246), Apple Swift 6.3.3. Reproduce from the repository root with
`bash .artifacts/model-audit/catalog-20261011/verify.sh`.
The runner and full compiler commands are retained there. Results are in
`verification.log`. Initial standalone runner attempts failed to locate XCTest
or its support libraries; explicit Xcode framework, import, library, and runtime
search paths fixed the harness. No package configuration changed.
An independent source check matched all 36 Swift records to the saved inventories
and raw hashes. All six retained license/notice texts match their source bytes.
`git diff --check` passed. Package integration tests were not run in this scope.

Those catalog tests alone do not verify payload integrity, Core ML loading,
tokenizer execution, inference, download recovery, packaging, UI or performance.
No user recordings, credentials, paid API, cloud writes or uploads were used.

## Local runtime evidence (2026-10-11)

Runtime checks used macOS 26.4 arm64 on Mac16,9 with 36 GiB RAM. The pinned
dependencies are WhisperKit `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4` and
speech-swift `cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa`. Human selected Apple
Silicon-only support on 2026-10-11. The supported architecture is arm64;
Intel Macs are not supported. An arm64-only build follows product policy and
does not need an Intel-support exception.

The production manager downloaded all 3,200,167,866 catalog bytes into a private
cache under `.artifacts/local-inference/models`. A controlled cancellation kept
partials. A new manager resumed them and reached ready. Independent SHA-256
verification passed for all 36 files. Startup reached ready with OS network
access denied and no download. The default model or recording library was not
used by these checks.

| Check | Observed time | Maximum process RSS |
| --- | ---: | ---: |
| Controlled download cancellation | 8.51 s | 33,865,728 bytes |
| Resume and complete all files | 150.31 s | 61,849,600 bytes |
| Offline integrity recheck | 1.12 s | Not measured here |
| 31.174 s synthetic WAV: real Whisper + Nemotron | 47.06 s inference | 1,924,136,960 bytes |
| Synthetic M4A: finalization callback through real models and sidecar reopen | 51.59 s test | 1,971,585,024 bytes |
| 650 s synthetic WAV, first attempt: FAILED in window 2 | 119.72 s before failure | 371,834,880 bytes |
| 650 s synthetic WAV, second attempt: runtime PASS, overlap quality FAIL | 182.65 s inference | 1,897,381,888 bytes |
| 10 s exact-zero WAV after correction: empty transcript PASS | 28.77 s inference | 1,922,613,248 bytes |

Times are single-run observations, not performance guarantees. They include
model loading. The standalone inference entry point used optimized app sources
and debug dependency objects. The finalization check used the SwiftPM debug
test bundle. RSS is the process maximum from `/usr/bin/time -l`; it is not a
measurement of total system or accelerator memory.

The first real inference attempt failed with `invalidTiming`. Raw Whisper
alignment assigned ` We` the range 0.02–0.02 seconds while its parent sentence
had 0.02–1.72 seconds. The adapter now uses the valid parent sentence when a
word has zero duration. It preserves text and does not invent a word duration.
It still rejects other malformed timing. Regression tests first reproduced the
failure, then passed with the correction in `bbcc8a8`.

The corrected WAV run returned 10 segments with two speaker labels. The first
word of the second voice remained `speaker: null`; attribution did not have
enough coverage. This is expected conservative behavior, not a diarization
accuracy score. English macOS voices generated the fixture; these results do
not establish Vietnamese speech accuracy or real meeting quality.

The first 650-second run failed with `invalidTiming` in window 2 and saved no
output. Raw output placed three tail words in the decoder's padded audio.
Correction `c0f6056` excludes only bounded, parent-contained tail predictions
from a sentence crossing the real audio end. It keeps in-window words and
still rejects malformed timing. Captured-window replay and 14 focused tests
passed. Correction `9a5eb10` also matches an unambiguous sentence against its
word sequence, with at most 1 ms internal rounding overlap.

The second 650-second run completed all three windows and saved 229 segments.
JSON round-trip and time bounds passed. Content inspection failed at the
590-second boundary: `We We`, repeated `are`, and `project project` remain.
Raw windows show timing drift above 250 ms and a word crossing the overlap
edge by 60 ms. A further bounded merger correction is in progress. Runtime
completion is not overlap-quality acceptance. Failed and passing evidence
remain separate in `long-run-1.log`, `long-run-2.log`, and `long-result-2.json`.

The first ten-second digital-silence run failed with `invalidTiming`. Whisper
predicted `you` at 29.52–29.62 seconds in padded audio. The adapter now skips
transcription for exact zero PCM only; it does not discard quiet nonzero audio.
Fifteen focused tests passed with the pinned tokenizer and OS network denial.
The corrected full pipeline also passed with network denied: it loaded the
models, skipped Whisper decoding, ran Nemotron, and saved/reopened a valid empty
transcript. Evidence: `silence-run-2.log` and `silence-result-2.json`.
Correction `384fde3` does not establish robustness for ambient noise or quiet
speech. Model loading still occurs even for an all-zero recording.

`LocalRealInferenceTests` exercises the production path:
synthetic capture finalization → `AppModel.onRecordingFinalized` →
`LocalTranscriptionModel` → real Whisper and Nemotron → atomic sidecar save →
reopen through a new `RecordingStore`. It verifies one callback, unchanged
ready metadata, one completion notification and a valid nonempty transcript.
Only capture is injected. The test never opens a microphone or drives UI.

Evidence is retained under `.artifacts/local-inference/`: `download-cancel.log`,
`download-resume.log`, `independent-hashes.log`, `offline-ready.log`,
`dialogue-run-1.log`, `raw-timings.log`, `dialogue-run-2.log`,
`dialogue-result-2.json`, and `finalization-run-1.log`.
The finalization test prints the exact retained private library and sidecar path.
Focused correction tests with network denied passed 27/27; their receipt is
`.artifacts/dependency-validation/zero-duration-offline.log`.

### Repeat the finalization check

1. Run `bash scripts/make-local-inference-fixtures.sh` with already installed
   `say` voices and `ffmpeg`. Keep the printed fixture directory. No voice
   download occurs.
2. Build the opt-in test without input variables:
   `swift test --scratch-path .artifacts/dependency-validation/build --disable-keychain --disable-netrc --filter LocalRealInferenceTests`.
   It skips inference until all three input paths are supplied.
3. Set `LOCAL_INFERENCE_MODEL_ROOT` to the verified catalog root,
   `LOCAL_INFERENCE_AUDIO` to the generated `dialogue.m4a`, and
   `LOCAL_INFERENCE_OUTPUT_ROOT` to a private evidence directory. Use absolute
   paths. Each run creates a new UUID-named recording library and retains it.
4. Run the built test bundle with network access denied:

   ```sh
   sandbox-exec -p '(version 1)(allow default)(deny network*)' \
     /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
     -XCTest LessMeetTests.LocalRealInferenceTests \
     .artifacts/dependency-validation/build/arm64-apple-macosx/debug/LessMeetPackageTests.xctest
   ```

Run the compiled bundle directly for this check. Wrapping SwiftPM itself in
that sandbox failed at its nested manifest sandbox before any tests ran.
That failed attempt is retained separately from passing test evidence.

Model setup component UI is accepted only for the isolated fixture documented
in `.artifacts/verify-lessmeet/local-model-ui/RESULT.md`. Full shell wiring,
microphone/system-audio capture, transcript UI, live auth/chat, release packaging,
long-file overlap quality, and broad device/language coverage remain separate
checks. `docs/STATUS.md` records current owners and later results.
