import CoreML
import Foundation
import OSLog
import WhisperKit

enum LocalWhisperError: Error, Equatable {
    case localDirectoryRequired
    case invalidTokenizer(String)
    case missingTokenizer
    case incompatibleModel(String)
    case invalidSamples
    case invalidTiming
    case transcriptionInProgress
}

actor LocalWhisperAdapter {
    private let engine: LocalOnlyWhisperKit
    private var transcribing = false
    private static let logger = Logger(subsystem: "com.lessmeet.app", category: "LocalWhisperAdapter")

    init(modelDirectory: URL, tokenizerDirectory: URL) async throws {
        try Task.checkCancellation()
        guard modelDirectory.isFileURL, tokenizerDirectory.isFileURL else {
            throw LocalWhisperError.localDirectoryRequired
        }
        let tokenizer = try await LocalWhisperTokenizer.load(from: tokenizerDirectory)
        let engine = try await LocalOnlyWhisperKit(WhisperKitConfig(
            modelFolder: modelDirectory.path, tokenizerFolder: tokenizerDirectory,
            verbose: false, prewarm: false, load: false, download: false
        ))
        engine.tokenizer = tokenizer
        try Task.checkCancellation()
        try await engine.loadModels()
        try Task.checkCancellation()
        try engine.validateLargeV3()
        self.engine = engine
    }

    /// Input is mono PCM at 16 kHz. Output times are relative to this input window.
    func transcribe(samples: [Float]) async throws -> [LocalTranscriptSegment] {
        try Task.checkCancellation()
        try Self.validateSamples(samples)
        guard !transcribing else { throw LocalWhisperError.transcriptionInProgress }
        if Self.isDigitalSilence(samples) { return [] }
        transcribing = true
        defer { transcribing = false }
        let options = DecodingOptions(
            task: .transcribe, detectLanguage: true, skipSpecialTokens: true,
            withoutTimestamps: false, wordTimestamps: engine.textDecoder.supportsWordTimestamps,
            concurrentWorkerCount: 1, chunkingStrategy: nil
        )
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let converted = try Self.convert(results.flatMap(\.segments), sampleCount: samples.count)
        if converted.segmentFallbackCount > 0 {
            Self.logger.warning("Word alignment absent or zero-duration; used timed segments: \(converted.segmentFallbackCount)")
        }
        if converted.discardedTailWordCount > 0 {
            Self.logger.warning("Excluded word predictions beyond input audio: \(converted.discardedTailWordCount)")
        }
        return converted.segments
    }

    static func validateSamples(_ samples: [Float]) throws {
        guard samples.count <= 16_000 * 300, samples.allSatisfy(\.isFinite) else {
            throw LocalWhisperError.invalidSamples
        }
    }

    /// Exact zero PCM contains no speech. Do not apply a threshold to quiet audio.
    static func isDigitalSilence(_ samples: [Float]) -> Bool {
        samples.allSatisfy { $0 == 0 }
    }

    static func convert(_ input: [TranscriptionSegment], sampleCount: Int) throws
        -> (segments: [LocalTranscriptSegment], segmentFallbackCount: Int, discardedTailWordCount: Int) {
        guard sampleCount > 0, sampleCount <= 16_000 * 300 else { throw LocalWhisperError.invalidSamples }
        let durationMs = Int64(sampleCount / 16)
        var segments: [LocalTranscriptSegment] = []
        var fallbackCount = 0
        var discardedTailWordCount = 0
        func bounds(_ start: Float, _ end: Float) throws -> (Int64, Int64) {
            guard start.isFinite, end.isFinite, start < end else { throw LocalWhisperError.invalidTiming }
            let clampedStart = min(max(Double(start) * 1000, 0), Double(durationMs))
            let clampedEnd = min(max(Double(end) * 1000, 0), Double(durationMs))
            let startMs = Int64(clampedStart.rounded(.down))
            let endMs = Int64(clampedEnd.rounded(.up))
            guard startMs < endMs else { throw LocalWhisperError.invalidTiming }
            return (startMs, endMs)
        }
        func append(_ text: String, _ start: Float, _ end: Float) throws {
            let (startMs, endMs) = try bounds(start, end)
            segments.append(LocalTranscriptSegment(startMs: startMs, endMs: endMs, speaker: nil, text: text))
        }
        for segment in input {
            if let words = segment.words, !words.isEmpty {
                var needsParentTiming = false
                var retained: [WordTiming] = []
                for word in words {
                    // Whisper pads its final decoder input to 30 seconds. A sentence
                    // that crosses the real audio end can include predictions in that
                    // padding. Do not clamp those words into the saved transcript.
                    let duration = Double(sampleCount) / 16_000
                    if word.start.isFinite, word.end.isFinite, word.start <= word.end,
                       Double(word.start) >= duration,
                       segment.start.isFinite, segment.end.isFinite,
                       segment.start >= 0, Double(segment.start) < duration,
                       Double(segment.end) > duration, Double(segment.end) <= duration + 30,
                       word.end <= segment.end {
                        discardedTailWordCount += 1
                        continue
                    }
                    if word.start.isFinite, word.end.isFinite, word.start == word.end {
                        // Alignment can assign no duration to a recognized word. Use the
                        // original sentence timing; do not drop text or invent a word span.
                        guard word.start >= 0, Double(word.start) * 1000 < Double(durationMs),
                              word.start >= segment.start, word.end <= segment.end,
                              !segment.text.isEmpty else { throw LocalWhisperError.invalidTiming }
                        _ = try bounds(segment.start, segment.end)
                        needsParentTiming = true
                    } else {
                        // Check every word even if another word needs the parent fallback.
                        _ = try bounds(word.start, word.end)
                    }
                    retained.append(word)
                }
                if needsParentTiming {
                    // Parent text includes padding predictions when words were removed.
                    let text = retained.count == words.count ? segment.text : retained.map(\.word).joined()
                    try append(text, segment.start, segment.end)
                    fallbackCount += 1
                } else {
                    for word in retained { try append(word.word, word.start, word.end) }
                }
            } else if !segment.text.isEmpty {
                try append(segment.text, segment.start, segment.end)
                fallbackCount += 1
            }
        }
        return (segments, fallbackCount, discardedTailWordCount)
    }
}

final class LocalOnlyWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        try Task.checkCancellation()
        guard tokenizer is LocalWhisperTokenizer else { throw LocalWhisperError.missingTokenizer }
        textDecoder.isModelMultilingual = true
        // Never call super: its error recovery can download a tokenizer.
        // modelVariant stays .tiny on this route. Only loaded shapes establish compatibility.
    }

    func validateLargeV3() throws {
        guard let mel = (featureExtractor as? FeatureExtractor)?.model,
              let encoder = (audioEncoder as? AudioEncoder)?.model,
              let decoder = (textDecoder as? TextDecoder)?.model else {
            throw LocalWhisperError.incompatibleModel("missing loaded Core ML model")
        }
        try Self.validateShapes(
            melInputs: Self.shapes(mel.modelDescription.inputDescriptionsByName),
            melOutputs: Self.shapes(mel.modelDescription.outputDescriptionsByName),
            encoderInputs: Self.shapes(encoder.modelDescription.inputDescriptionsByName),
            encoderOutputs: Self.shapes(encoder.modelDescription.outputDescriptionsByName),
            decoderInputs: Self.shapes(decoder.modelDescription.inputDescriptionsByName),
            decoderOutputs: Self.shapes(decoder.modelDescription.outputDescriptionsByName)
        )
    }

    private static func shapes(_ features: [String: MLFeatureDescription]) -> [String: [Int]] {
        features.compactMapValues { $0.multiArrayConstraint?.shape.map(\.intValue) }
    }

    static func validateShapes(melInputs: [String: [Int]], melOutputs: [String: [Int]],
                               encoderInputs: [String: [Int]], encoderOutputs: [String: [Int]],
                               decoderInputs: [String: [Int]], decoderOutputs: [String: [Int]]) throws {
        let requirements: [(String, [String: [Int]], [String: [Int]])] = [
            ("mel input", melInputs, ["audio": [480000]]),
            ("mel output", melOutputs, ["melspectrogram_features": [1, 128, 1, 3000]]),
            ("encoder input", encoderInputs, ["melspectrogram_features": [1, 128, 1, 3000]]),
            ("encoder output", encoderOutputs, ["encoder_output_embeds": [1, 1280, 1, 1500]]),
            ("decoder input", decoderInputs, ["input_ids": [1], "cache_length": [1],
                "key_cache": [1, 40960, 1, 448], "value_cache": [1, 40960, 1, 448],
                "kv_cache_update_mask": [1, 448], "decoder_key_padding_mask": [1, 448],
                "encoder_output_embeds": [1, 1280, 1, 1500]]),
            ("decoder output", decoderOutputs, ["logits": [1, 1, 51866],
                "key_cache_updates": [1, 40960, 1, 1], "value_cache_updates": [1, 40960, 1, 1]])
        ]
        for (component, actual, expected) in requirements {
            for (name, shape) in expected where actual[name] != shape {
                throw LocalWhisperError.incompatibleModel("\(component): \(name)")
            }
        }
        if let alignment = decoderOutputs["alignment_heads_weights"], alignment != [1, 1500] {
            throw LocalWhisperError.incompatibleModel("alignment_heads_weights")
        }
    }
}
