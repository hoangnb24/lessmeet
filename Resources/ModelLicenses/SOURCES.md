# Model and SDK license sources

These files preserve upstream license and notice text. The names below are
local names, not claims that the upstream repositories use these filenames.
Retrieved on 2026-10-11. No model weights are included in this directory.

| Local file | Immutable source | Applies to |
| --- | --- | --- |
| `WhisperKit-LICENSE.txt` | [LICENSE](https://github.com/argmaxinc/WhisperKit/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/LICENSE) | WhisperKit / Argmax OSS SDK; MIT |
| `WhisperKit-NOTICES.txt` | [NOTICES](https://github.com/argmaxinc/WhisperKit/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/NOTICES) | Embedded swift-transformers code; upstream notices and full Apache-2.0 text |
| `speech-swift-LICENSE.txt` | [LICENSE](https://github.com/soniqo/speech-swift/blob/cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa/LICENSE) | speech-swift SDK; Apache-2.0 |
| `OpenAI-Whisper-LICENSE.txt` | [LICENSE](https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE) | Upstream OpenAI Whisper code and weights; MIT |
| `Nemotron-LICENSE.txt` | [LICENSE](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8/blob/db823d36c2230d5535a6165c932f8a5369484b7a/LICENSE) | Nemotron source and derived weights; OpenMDW-1.1 |
| `Nemotron-NOTICE.txt` | [NOTICE](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8/blob/db823d36c2230d5535a6165c932f8a5369484b7a/NOTICE) | NVIDIA copyright and exact source checkpoint provenance |

The OpenAI source commit pins the license text only. It does not replace the
tokenizer or model artifact revisions. The pinned Argmax model card declares
MIT but has no root LICENSE file. We do not invent an Argmax copyright notice
or claim the OpenAI text was supplied in that model repository.

The Nemotron binary is a third-party Core ML INT8 conversion by `aufklarer`.
Its NOTICE identifies NVIDIA source checkpoint
`a435e9867d79e789e90053f9b6d6834053af564a`. NVIDIA's pinned model card declares
OpenMDW-1.1; that source repository has no standalone LICENSE file at this pin.
The retained OpenMDW text is the converter's exact distributed text.

Keep applicable copyright and origin notices with redistributed material.
Include these files in app packaging. Preserve the Nemotron LICENSE and NOTICE
beside downloaded weights too. Packaging is not configured or verified by this
catalog change. Transitive SDK license review remains a separate integration
task; this directory is not a complete software bill of materials.
