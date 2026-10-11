import Foundation
import WhisperKit
import XCTest
#if !LOCAL_WHISPER_STANDALONE
@testable import LessMeet
#endif

final class LocalWhisperAdapterTests: XCTestCase {
    private func tokenizerDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LOCAL_WHISPER_TOKENIZER_FIXTURE"] else {
            throw XCTSkip("Set LOCAL_WHISPER_TOKENIZER_FIXTURE to the pinned local tokenizer directory; no test downloads files.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testEveryRequiredTokenIsValidatedInBothDirections() throws {
        let expected = Dictionary(uniqueKeysWithValues: LocalWhisperTokenizer.requiredTokens)
        let reverse = Dictionary(uniqueKeysWithValues: expected.map { ($0.value, $0.key) })
        XCTAssertEqual(LocalWhisperTokenizer.languages.count, 100)
        XCTAssertEqual(expected["<|vi|>"], 50278)
        XCTAssertEqual(expected["<|yue|>"], 50358)
        XCTAssertEqual(expected["<|30.00|>"], 51865)
        try LocalWhisperTokenizer.validate(tokenToID: { expected[$0] }, idToToken: { reverse[$0] })
        for (token, id) in expected {
            XCTAssertThrowsError(try LocalWhisperTokenizer.validate(
                tokenToID: { $0 == token ? nil : expected[$0] }, idToToken: { reverse[$0] }))
            XCTAssertThrowsError(try LocalWhisperTokenizer.validate(
                tokenToID: { $0 == token ? id + 1 : expected[$0] }, idToToken: { reverse[$0] }))
            XCTAssertThrowsError(try LocalWhisperTokenizer.validate(
                tokenToID: { expected[$0] }, idToToken: { $0 == id ? "wrong" : reverse[$0] }))
        }
    }

    func testLocalLoaderAndAdapterRejectMissingAndCorruptFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lessmeet-whisper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["missing", "corrupt", "missing-config"] {
            let directory = root.appendingPathComponent(name)
            if name != "missing" {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data((name == "corrupt" ? "{" : "{}").utf8)
                    .write(to: directory.appendingPathComponent("tokenizer.json"))
                if name == "corrupt" {
                    try Data("{".utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
                }
            }
            do {
                _ = try await LocalWhisperAdapter(modelDirectory: root, tokenizerDirectory: directory)
                XCTFail("Accepted \(name)")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
        }
        do {
            _ = try await LocalWhisperTokenizer.load(from: URL(string: "https://example.invalid/tokenizer")!)
            XCTFail("Accepted remote directory")
        } catch { XCTAssertEqual(error as? LocalWhisperError, .localDirectoryRequired) }
    }

    func testRealPinnedTokenizerInjectionAndRetention() async throws {
        let directory = try tokenizerDirectory()
        let tokenizer = try await LocalWhisperTokenizer.load(from: directory)
        XCTAssertEqual(tokenizer.allLanguageTokens, Set(50259...50358))
        XCTAssertEqual(tokenizer.specialTokens.transcribeToken, 50360)
        XCTAssertEqual(tokenizer.specialTokens.timeTokenBegin, 50365)
        let engine = try await LocalOnlyWhisperKit(WhisperKitConfig(
            modelFolder: directory.path, verbose: false, prewarm: false, load: false, download: false))
        do {
            try await engine.loadTokenizerIfNeeded()
            XCTFail("Accepted nil tokenizer")
        } catch { XCTAssertEqual(error as? LocalWhisperError, .missingTokenizer) }
        engine.tokenizer = tokenizer
        try await engine.loadTokenizerIfNeeded()
        XCTAssertTrue(engine.textDecoder.isModelMultilingual)
        XCTAssertEqual(engine.textDecoder.tokenizer?.convertTokenToId("<|vi|>"), 50278)
        // A nonexistent folder cannot trigger a reparse or network fallback.
        engine.tokenizerFolder = directory.appendingPathComponent("does-not-exist")
        try await engine.loadTokenizerIfNeeded()
        XCTAssertEqual(engine.tokenizer?.decode(tokens: [220]), " ")
        engine.tokenizer = nil
        do {
            try await engine.loadTokenizerIfNeeded()
            XCTFail("Accepted cleared tokenizer")
        } catch { XCTAssertEqual(error as? LocalWhisperError, .missingTokenizer) }
    }

    func testVietnameseUnicodeAndMultilingualWordPieces() async throws {
        let directory = try tokenizerDirectory()
        let tokenizer = try await LocalWhisperTokenizer.load(from: directory)
        let base = try await AutoTokenizerWrapper.from(modelFolder: directory,
            hubApi: HubApiWrapper(downloadBase: directory, hfToken: "", endpoint: "http://127.0.0.1:9"))
        let cases: [(String, [String]?)] = [
            (" Xin chào Việt Nam!", [" Xin", " chào", " Việt", " Nam", "!"]),
            (" Hello world!", [" Hello", " world", "!"]),
            (" Tiếng Việt rất đẹp.", [" Tiếng", " Việt", " rất", " đẹp", "."]),
            (" Cafe\u{301} naïve 👩🏽‍💻!", nil),
            (" Xin\nchào\tViệt\u{a0}Nam", nil),
            (" abc � def 😀 é � xyz", nil),
            ("你好世界，这是中文测试。", nil),
            ("日本語の文字を正しく分割します。", nil),
            ("ภาษาไทยเป็นภาษาที่สวยงาม", nil),
            ("مرحبا بالعالم", nil),
            ("", [])
        ]
        for (text, expected) in cases {
            let tokens = base.encode(text: text, addSpecialTokens: false)
            let pieces = tokenizer.splitToWordTokens(tokenIds: tokens)
            XCTAssertEqual(pieces.wordTokens.flatMap { $0 }, tokens, text)
            XCTAssertEqual(pieces.words.joined(), tokenizer.decode(tokens: tokens), text)
            XCTAssertFalse(pieces.wordTokens.contains(where: \.isEmpty), text)
            if !text.contains("�") { XCTAssertFalse(pieces.words.contains { $0.contains("�") }, text) }
            if let expected { XCTAssertEqual(pieces.words, expected, text) }
            if text.hasPrefix("你好") || text.hasPrefix("日本語") { XCTAssertGreaterThan(pieces.words.count, 2) }
        }
        let tokens = [50258, 50278] + base.encode(text: " Xin chào", addSpecialTokens: false) + [50257]
        let pieces = tokenizer.splitToWordTokens(tokenIds: tokens)
        XCTAssertEqual(pieces.wordTokens.flatMap { $0 }, tokens)
        XCTAssertEqual(pieces.words, ["<|startoftranscript|>", "<|vi|>", " Xin", " chào", "<|endoftext|>"])
        // UTF-8 EF BF BD encodes a literal replacement character. Keep its
        // individual byte tokens together, rather than emitting three U+FFFDs.
        let replacementBytes = try ["ï", "¿", "½"].map { try XCTUnwrap(tokenizer.convertTokenToId($0)) }
        let fragmented = tokenizer.splitToWordTokens(tokenIds: replacementBytes)
        XCTAssertEqual(fragmented.words, ["�"])
        XCTAssertEqual(fragmented.wordTokens, [replacementBytes])
    }

    func testTimedWordsPreserveSpacingAndClamp() throws {
        let input = TranscriptionSegment(start: 0, end: 2, text: "ignored", words: [
            WordTiming(word: " Xin", tokens: [], start: -0.1, end: 0.5, probability: 1),
            WordTiming(word: " chào", tokens: [], start: 0.5, end: 1.1, probability: 1)
        ])
        let result = try LocalWhisperAdapter.convert([input], sampleCount: 16000)
        XCTAssertEqual(result.segmentFallbackCount, 0)
        XCTAssertEqual(result.segments, [
            LocalTranscriptSegment(startMs: 0, endMs: 500, speaker: nil, text: " Xin"),
            LocalTranscriptSegment(startMs: 500, endMs: 1000, speaker: nil, text: " chào")
        ])
        for segment in result.segments { try segment.validate() }
    }

    func testMissingAlignmentUsesTimedSegmentAndReportsCount() throws {
        let result = try LocalWhisperAdapter.convert([
            TranscriptionSegment(start: 0, end: 1, text: " Xin chào"),
            TranscriptionSegment(start: 1, end: 2, text: " Việt Nam", words: [])
        ], sampleCount: 32000)
        XCTAssertEqual(result.segmentFallbackCount, 2)
        XCTAssertEqual(result.segments.map(\.text), [" Xin chào", " Việt Nam"])
        XCTAssertEqual(result.segments.map(\.startMs), [0, 1000])
        XCTAssertEqual(result.segments.map(\.endMs), [1000, 2000])
    }

    func testZeroDurationWordUsesValidParentWithoutDroppingText() throws {
        let text = " We are testing a local meeting recorder."
        let parent = TranscriptionSegment(start: 0.02, end: 1.72, text: text)
        let aligned = TranscriptionSegment(start: 0.02, end: 1.72, text: text, words: [
            WordTiming(word: " We", tokens: [], start: 0.02, end: 0.02, probability: 1),
            WordTiming(word: " are testing a local meeting recorder.", tokens: [],
                       start: 0.02, end: 1.72, probability: 1)
        ])
        let result = try LocalWhisperAdapter.convert([aligned], sampleCount: 32_000)
        let expected = try LocalWhisperAdapter.convert([parent], sampleCount: 32_000)
        XCTAssertEqual(result.segments, expected.segments)
        XCTAssertEqual(result.segmentFallbackCount, 1)
        XCTAssertEqual(result.segments.map(\.text), [text])
    }

    func testZeroDurationFallbackDoesNotHideOtherInvalidTimes() {
        let zero = WordTiming(word: " We", tokens: [], start: 0.125, end: 0.125, probability: 1)
        for (start, end): (Float, Float) in [(.nan, 1), (0, .infinity), (1, 0), (2, 3), (-2, -1)] {
            XCTAssertThrowsError(try LocalWhisperAdapter.convert([
                TranscriptionSegment(start: 0, end: 1, text: "invalid words", words: [zero,
                    WordTiming(word: " bad", tokens: [], start: start, end: end, probability: 1)
                ])
            ], sampleCount: 16_000))
        }
        for parent in [
            TranscriptionSegment(start: 0.25, end: 1, text: "word outside parent", words: [zero]),
            TranscriptionSegment(start: 0, end: 0, text: "invalid parent", words: [zero]),
            TranscriptionSegment(start: 0, end: 1, text: "", words: [zero])
        ] {
            XCTAssertThrowsError(try LocalWhisperAdapter.convert([parent], sampleCount: 16_000))
        }
    }

    func testPaddedTailPredictionsDoNotInvalidateRealAudioWords() throws {
        let input = TranscriptionSegment(start: 296.78, end: 308.68,
            text: " We are testing a local meeting recorder. The project is in progress.", words: [
                WordTiming(word: " We are testing a local meeting recorder.", tokens: [], start: 296.78, end: 299.02, probability: 1),
                WordTiming(word: " The", tokens: [], start: 299.38, end: 299.7, probability: 1),
                WordTiming(word: " project", tokens: [], start: 299.7, end: 300, probability: 1),
                WordTiming(word: " is", tokens: [], start: 300, end: 300.2, probability: 1),
                WordTiming(word: " in", tokens: [], start: 300.2, end: 300.4, probability: 1),
                WordTiming(word: " progress.", tokens: [], start: 300.4, end: 308.68, probability: 1)
            ])
        let result = try LocalWhisperAdapter.convert([input], sampleCount: 4_800_000)
        XCTAssertEqual(result.segments.map(\.text).joined(), " We are testing a local meeting recorder. The project")
        XCTAssertEqual(result.segments.last?.endMs, 300_000)
        XCTAssertEqual(result.segmentFallbackCount, 0)
        XCTAssertEqual(result.discardedTailWordCount, 3)
    }

    func testZeroDurationFallbackDoesNotRestorePaddedTailText() throws {
        let input = TranscriptionSegment(start: 0.125, end: 2,
            text: " We agree extra", words: [
                WordTiming(word: " We", tokens: [], start: 0.125, end: 0.125, probability: 1),
                WordTiming(word: " agree", tokens: [], start: 0.125, end: 1, probability: 1),
                WordTiming(word: " extra", tokens: [], start: 1, end: 2, probability: 1)
            ])
        let result = try LocalWhisperAdapter.convert([input], sampleCount: 16_000)
        XCTAssertEqual(result.segments, [.init(startMs: 125, endMs: 1_000, speaker: nil, text: " We agree")])
        XCTAssertEqual(result.segmentFallbackCount, 1)
        XCTAssertEqual(result.discardedTailWordCount, 1)
    }

    func testPaddedTailDoesNotHideMalformedOrUnrelatedOutOfWindowTimes() {
        for (start, end): (Float, Float) in [(.nan, 2), (1, .infinity), (2, 1), (-2, -1), (3, 4)] {
            let input = TranscriptionSegment(start: 0, end: 2, text: "valid parent", words: [
                WordTiming(word: " valid", tokens: [], start: 0, end: 1, probability: 1),
                WordTiming(word: " bad", tokens: [], start: start, end: end, probability: 1)
            ])
            XCTAssertThrowsError(try LocalWhisperAdapter.convert([input], sampleCount: 16_000))
        }
        XCTAssertThrowsError(try LocalWhisperAdapter.convert([
            TranscriptionSegment(start: 2, end: 3, text: "outside", words: [
                WordTiming(word: "outside", tokens: [], start: 2, end: 3, probability: 1)
            ])
        ], sampleCount: 16_000))
    }

    func testInvalidTimingIsNotSilentlyDiscardedOrReplaced() throws {
        for (start, end): (Float, Float) in [(.nan, 1), (0, .infinity), (1, 0), (1, 1), (2, 3), (-2, -1)] {
            XCTAssertThrowsError(try LocalWhisperAdapter.convert([
                TranscriptionSegment(start: start, end: end, text: "bad")
            ], sampleCount: 16000))
            XCTAssertThrowsError(try LocalWhisperAdapter.convert([
                TranscriptionSegment(start: 0, end: 1, text: "valid parent", words: [
                    WordTiming(word: "bad", tokens: [], start: start, end: end, probability: 1)
                ])
            ], sampleCount: 16000))
        }
        let tiny = try LocalWhisperAdapter.convert([
            TranscriptionSegment(start: 0.0001, end: 0.0002, text: "short")
        ], sampleCount: 16000)
        XCTAssertEqual(tiny.segments.first?.startMs, 0)
        XCTAssertEqual(tiny.segments.first?.endMs, 1)
    }

    func testInputBoundsAndCancellation() async throws {
        try LocalWhisperAdapter.validateSamples([])
        try LocalWhisperAdapter.validateSamples(Array(repeating: 0, count: 4_800_000))
        XCTAssertThrowsError(try LocalWhisperAdapter.validateSamples(Array(repeating: 0, count: 4_800_001)))
        XCTAssertThrowsError(try LocalWhisperAdapter.validateSamples([.nan]))
        XCTAssertThrowsError(try LocalWhisperAdapter.validateSamples([.infinity]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalWhisperAdapter(modelDirectory: URL(fileURLWithPath: "/missing"),
                                                 tokenizerDirectory: URL(fileURLWithPath: "/missing"))
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFullLargeV3ShapeContractRejectsTurboAndOtherVariants() throws {
        let melInput = ["audio": [480000]]
        let mel = ["melspectrogram_features": [1, 128, 1, 3000]]
        let encoder = ["encoder_output_embeds": [1, 1280, 1, 1500]]
        let decoderInput = ["input_ids": [1], "cache_length": [1],
            "key_cache": [1, 40960, 1, 448], "value_cache": [1, 40960, 1, 448],
            "kv_cache_update_mask": [1, 448], "decoder_key_padding_mask": [1, 448],
            "encoder_output_embeds": [1, 1280, 1, 1500]]
        let decoderOutput = ["logits": [1, 1, 51866], "key_cache_updates": [1, 40960, 1, 1],
            "value_cache_updates": [1, 40960, 1, 1], "alignment_heads_weights": [1, 1500]]
        func validate(_ input: [String: [Int]], _ output: [String: [Int]], _ features: [String: [Int]]) throws {
            try LocalOnlyWhisperKit.validateShapes(melInputs: melInput, melOutputs: features,
                encoderInputs: mel, encoderOutputs: encoder, decoderInputs: input, decoderOutputs: output)
        }
        try validate(decoderInput, decoderOutput, mel)
        var withoutAlignment = decoderOutput
        withoutAlignment.removeValue(forKey: "alignment_heads_weights")
        try validate(decoderInput, withoutAlignment, mel)
        for key in decoderInput.keys {
            var invalid = decoderInput
            invalid[key] = [1]
            if invalid == decoderInput { invalid.removeValue(forKey: key) }
            XCTAssertThrowsError(try validate(invalid, decoderOutput, mel))
        }
        var turbo = decoderInput
        turbo["key_cache"] = [1, 5120, 1, 448]
        XCTAssertThrowsError(try validate(turbo, decoderOutput, mel))
        XCTAssertThrowsError(try validate(decoderInput, decoderOutput, ["melspectrogram_features": [1, 80, 1, 3000]]))
        for key in decoderOutput.keys {
            var invalid = decoderOutput
            invalid[key] = [1]
            XCTAssertThrowsError(try validate(decoderInput, invalid, mel))
        }
    }
}

#if LOCAL_WHISPER_STANDALONE
@main enum LocalWhisperTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: LocalWhisperAdapterTests.self)
        suite.run()
        guard let run = suite.testRun, run.executionCount == 14, run.hasSucceeded else { exit(1) }
    }
}
#endif
