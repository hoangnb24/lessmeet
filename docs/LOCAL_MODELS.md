# Pinned local model catalog

`Sources/LessMeet/LocalModels/LocalModelManifest.swift` defines the static
`LocalModelCatalog.artifacts` input for an app-owned downloader. It does not
download, load, or verify installed models. No model payload was downloaded
for this catalog. This candidate starts at `714dc6f210bcacfc0d35408763c2351de4d47337`
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
payload bytes have NOT been downloaded or independently hashed locally.
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

Model payload integrity, Core ML loading, tokenizer execution, offline inference,
download recovery, resource packaging, UI, and performance remain UNVERIFIED.
No recordings, credentials, paid API, cloud writes, or uploads were used.
