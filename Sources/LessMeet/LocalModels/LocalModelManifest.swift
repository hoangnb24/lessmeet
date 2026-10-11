// Pinned source inventory. See docs/LOCAL_MODELS.md for provenance and limits.
// LFS hashes are published hashes, not proof of locally verified model payloads.

struct LocalModelArtifact: Equatable, Sendable {
    let id: String
    let name: String
    let repository: String
    let revision: String
    let directory: String
    let files: [LocalModelFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct LocalModelFile: Equatable, Sendable {
    // Repository-relative path. Preserve its nesting under artifact.directory.
    let path: String
    let bytes: Int64
    let sha256: String
}

enum LocalModelCatalog {
    static let artifacts: [LocalModelArtifact] = [
        LocalModelArtifact(
            id: "whisper-large-v3",
            name: "Whisper large-v3",
            repository: "argmaxinc/whisperkit-coreml",
            revision: "0f63a7800b00dd0226abd051b906c246e1907482",
            directory: "whisper-large-v3",
            files: [
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/analytics/coremldata.bin",
                    bytes: 243,
                    sha256: "195e35e9fbaa218cd59eca69988a2165245e5bfccc4a5d9776847e8955d1625a"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/coremldata.bin",
                    bytes: 348,
                    sha256: "273d6cd004f95763e9d03e5d36622f11038819a81b9eafed64b1d95444e04f62"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/metadata.json",
                    bytes: 1826,
                    sha256: "db0d80a1046e03e211928cd2918d5e5924947f4ecbcee5232b125f0f59757fbc"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/model.mil",
                    bytes: 581035,
                    sha256: "3e7737df445ef8fc13238970e3e518c0c6455bcadb6371df2ede1f22dcb8a8e0"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/model.mlmodel",
                    bytes: 408667,
                    sha256: "bf0987c0d8c3fe180877b12ba5b4ac1d890e011f2103926e53186089feced575"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/weights/weight.bin",
                    bytes: 1273974400,
                    sha256: "eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/config.json",
                    bytes: 1163,
                    sha256: "798b69c08cf93b2b03d94bea6eb3eb25fd4712259712d8a62ed2483fdf818a9e"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/generation_config.json",
                    bytes: 2810,
                    sha256: "d24f9cca0f448609a71ae044b736023706382f45e9700e0dffb2559d10cf1fea"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/analytics/coremldata.bin",
                    bytes: 243,
                    sha256: "091a361134891f94e613562771beea0d93a9aefbc6984ba86c60f856e07a508f"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/coremldata.bin",
                    bytes: 329,
                    sha256: "f3c5778c86d6fbc6a9817a56dbcac05a946a4d95c77f6db8355572f3be9e9a68"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/metadata.json",
                    bytes: 1850,
                    sha256: "1a94f4dfaec25549cbb386fe59b68c67a7a5af4a1c672a5998e5a84b9111135b"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/model.mil",
                    bytes: 10187,
                    sha256: "17977ed2332430c6cc4c1da2516f2cd4deb662d65ae38d72725ab157f32d4949"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/weights/weight.bin",
                    bytes: 373376,
                    sha256: "97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/analytics/coremldata.bin",
                    bytes: 243,
                    sha256: "7c151c6259c279aa7922d60e82c7851bbad1df10018b1cebc566aa6c2aee5e0f"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/coremldata.bin",
                    bytes: 637,
                    sha256: "f41a7939b47f7cf127aa69dfd8c552a141dc773b936bf8621aeffcd201fb9e30"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/metadata.json",
                    bytes: 4770,
                    sha256: "de900a968f7640e9775c28268e348a0bc6559a4a92defae07d91e7effa838246"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/model.mil",
                    bytes: 1010477,
                    sha256: "f8273cbf61aac4a43118a9090fc4d580678ea04abda473b4cb9dda2647d25c27"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/model.mlmodel",
                    bytes: 745579,
                    sha256: "680d8dfb7c7d8f1f852071ac7bdc96e55c696d0b822e70861045efb426b0a27b"
                ),
                LocalModelFile(
                    path: "openai_whisper-large-v3/TextDecoder.mlmodelc/weights/weight.bin",
                    bytes: 1813201716,
                    sha256: "680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55"
                ),
            ]
        ),
        LocalModelArtifact(
            id: "whisper-tokenizer",
            name: "Whisper large-v3 tokenizer",
            repository: "openai/whisper-large-v3",
            revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
            directory: "whisper-tokenizer",
            files: [
                LocalModelFile(
                    path: "config.json",
                    bytes: 1272,
                    sha256: "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b"
                ),
                LocalModelFile(
                    path: "tokenizer_config.json",
                    bytes: 282843,
                    sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"
                ),
                LocalModelFile(
                    path: "tokenizer.json",
                    bytes: 2480617,
                    sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"
                ),
            ]
        ),
        LocalModelArtifact(
            id: "nemotron3-int8",
            name: "Nemotron 3 diarization INT8 (community conversion)",
            repository: "aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8",
            revision: "db823d36c2230d5535a6165c932f8a5369484b7a",
            directory: "nemotron3-int8",
            files: [
                LocalModelFile(
                    path: "config.json",
                    bytes: 2174,
                    sha256: "e79ce1f621da90f6bb7b66bd1bcc4670623f1f12a448fc8d8985baa511f103b8"
                ),
                LocalModelFile(
                    path: "learnable_silence.f32",
                    bytes: 2048,
                    sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"
                ),
                LocalModelFile(
                    path: "LICENSE",
                    bytes: 2619,
                    sha256: "2ab44b68365473c112f5092211a38f231cb23e50de68b75a13369adbd76a74df"
                ),
                LocalModelFile(
                    path: "Nemotron3Head.mlmodelc/analytics/coremldata.bin",
                    bytes: 243,
                    sha256: "b83762ffca520790211707c5c57c99cf9b9a8a93d35f6cf509fb6111f9133de1"
                ),
                LocalModelFile(
                    path: "Nemotron3Head.mlmodelc/coremldata.bin",
                    bytes: 418,
                    sha256: "aa5a39243351deb724153a6c41315da577ed3e401c4b90041972ea9d8bf77e99"
                ),
                LocalModelFile(
                    path: "Nemotron3Head.mlmodelc/metadata.json",
                    bytes: 2786,
                    sha256: "8f4c0d178795bd2af2015f1e1197c8116a372308011dffa4dfa0f64a4979e57c"
                ),
                LocalModelFile(
                    path: "Nemotron3Head.mlmodelc/model.mil",
                    bytes: 422835,
                    sha256: "d433c8c1f1b0b5aed63accfadb2e8abecd0f3d9562a9c00e630e618b86b36006"
                ),
                LocalModelFile(
                    path: "Nemotron3Head.mlmodelc/weights/weight.bin",
                    bytes: 106087744,
                    sha256: "07a473fa166ceadbe750f3fae68632188ffa42fc21dcf2618f1f9c2ec8368402"
                ),
                LocalModelFile(
                    path: "Nemotron3PreEncoder.mlmodelc/analytics/coremldata.bin",
                    bytes: 243,
                    sha256: "b186aeaa8744776d56343c3a8e23eb7ba6ccb76416493f0bfa111145350c38d8"
                ),
                LocalModelFile(
                    path: "Nemotron3PreEncoder.mlmodelc/coremldata.bin",
                    bytes: 325,
                    sha256: "8ebc335e5a14f1f58a5c4f0591ed2685556298c7406b05cffd3eba9413aef3a2"
                ),
                LocalModelFile(
                    path: "Nemotron3PreEncoder.mlmodelc/metadata.json",
                    bytes: 1665,
                    sha256: "b30bb69b4625293335d55bc20bf2333b661d0bca53186d34576da9819f4acdf2"
                ),
                LocalModelFile(
                    path: "Nemotron3PreEncoder.mlmodelc/model.mil",
                    bytes: 1544,
                    sha256: "9776cec88d6713286da0b163280d467433760606dabaa5a556a6ccf1501fb5cf"
                ),
                LocalModelFile(
                    path: "Nemotron3PreEncoder.mlmodelc/weights/weight.bin",
                    bytes: 558336,
                    sha256: "6e4de3172736850d9adbd97ce3b7c6364cd6d131e3f8171f48b444f00dbcb538"
                ),
                LocalModelFile(
                    path: "NOTICE",
                    bytes: 255,
                    sha256: "32318cfb5e97ad0da7067bb56cd3f05279df932efeddbac1ab85c9ad6d008a98"
                ),
            ]
        ),
    ]
}
