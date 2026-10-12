import AVFoundation
import XCTest
#if !LOCAL_PCM_STANDALONE
@testable import LessMeet
#endif

final class LocalPCMReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPCMReader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeAudio(rate: Double, channels: AVAudioChannelCount, frames: Int,
                           ext: String = "caf", nonfinite: Float? = nil) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: channels == 1 ? kAudioChannelLayoutTag_Mono :
            channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   interleaved: false, channelLayout: layout)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        if frames > 0 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(channels) {
                for index in 0..<frames {
                    // The end stays nonzero to expose a lost converter tail.
                    buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.071)) * 0.25
                        + Float(channel + 1) * 0.125
                }
                buffer.floatChannelData![channel][frames - 1] = nonfinite ?? 0.75
            }
            try writer.write(from: buffer)
        }
        return url
    }

    private func collect(_ reader: LocalPCMReader, sizes: [Int]) throws -> [Float] {
        var result: [Float] = []
        var call = 0
        while true {
            let size = sizes[call % sizes.count]
            let block = try reader.read(maxSamples: size)
            XCTAssertLessThanOrEqual(block.count, min(size, 16_384))
            XCTAssertTrue(block.allSatisfy(\.isFinite))
            if block.isEmpty { break }
            result.append(contentsOf: block)
            call += 1
        }
        XCTAssertTrue(try reader.read(maxSamples: 1).isEmpty)
        return result
    }

    /// Independent, whole-fixture output buffer. Production never allocates this way.
    private func reference(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        converter.downmix = true
        let capacity = AVAudioFrameCount(ceil(Double(file.length) / file.processingFormat.sampleRate * 16_000)) + 8_192
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var result: [Float] = []
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                do {
                    if file.framePosition == file.length {
                        state.pointee = .endOfStream
                        return nil
                    }
                    let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: requested))
                    try file.read(into: input, frameCount: requested)
                    state.pointee = .haveData
                    return input
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            XCTAssertNotEqual(status, .error)
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { break }
            XCTAssertGreaterThan(output.frameLength, 0)
        }
        return result
    }

    func testSyntheticFormatsMatchReferenceAcrossReadBoundaries() throws {
        for ext in ["wav", "caf"] {
            for rate in [16_000.0, 48_000.0] {
                for channels: AVAudioChannelCount in [1, 2] {
                    let url = try makeAudio(rate: rate, channels: channels, frames: Int(rate) + 17, ext: ext)
                    let original = try Data(contentsOf: url)
                    let reader = try LocalPCMReader(url: url)
                    XCTAssertEqual(reader.duration, Double(Int(rate) + 17) / rate, accuracy: 1e-12)
                    let actual = try collect(reader, sizes: [1, 7, 4_093, 19, 16_384, 113])
                    let expected = try reference(url)
                    XCTAssertEqual(actual.count, expected.count, "\(ext) \(rate) \(channels)")
                    XCTAssertLessThanOrEqual(abs(actual.count - Int((reader.duration * 16_000).rounded())), 1)
                    XCTAssertEqual(actual, expected, "\(ext) \(rate) \(channels)")
                    XCTAssertEqual(try collect(LocalPCMReader(url: url), sizes: [Int.max]), actual)
                    XCTAssertEqual(try Data(contentsOf: url), original)
                }
            }
        }
    }

    func testShortAndFractionalTails() throws {
        for rate in [16_000.0, 48_000.0] {
            for frames in [1, 2, 3, 4, 17, 4_095, 4_096, 4_097, 48_001, 48_002] {
                let url = try makeAudio(rate: rate, channels: 1, frames: frames)
                let actual = try collect(LocalPCMReader(url: url), sizes: [1, 3, 211])
                let expected = try reference(url)
                XCTAssertEqual(actual, expected, "\(rate) \(frames)")
                XCTAssertLessThanOrEqual(abs(actual.count - Int((Double(frames) / rate * 16_000).rounded())), 1)
                if frames >= 3 { XCTAssertTrue(actual.contains { abs($0) > 0.001 }) }
            }
        }
    }

    func testOtherSourceRatesIncludeUpsampling() throws {
        for rate in [8_000.0, 11_025, 12_000, 22_050, 24_000, 32_000, 44_100, 96_000] {
            let url = try makeAudio(rate: rate, channels: 2, frames: 4_097)
            let actual = try collect(LocalPCMReader(url: url), sizes: [1, 131, 4_097])
            let expected = try reference(url)
            XCTAssertEqual(actual.count, expected.count, "\(rate)")
            let maxDifference = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxDifference, 1e-6, "\(rate)")
        }
    }

    func testInvalidParametersDoNotAdvanceReader() throws {
        let url = try makeAudio(rate: 16_000, channels: 1, frames: 17)
        let reader = try LocalPCMReader(url: url)
        for count in [0, -1, Int.min] {
            XCTAssertThrowsError(try reader.read(maxSamples: count)) {
                XCTAssertTrue($0.localizedDescription.contains("maxSamples"))
            }
        }
        XCTAssertEqual(try collect(reader, sizes: [1]), try reference(url))
    }

    func testRejectsInvalidSourcesAndNonfiniteSamples() throws {
        XCTAssertThrowsError(try LocalPCMReader(url: URL(string: "https://invalid.test/audio.wav")!))
        XCTAssertThrowsError(try LocalPCMReader(url: root.appendingPathComponent("missing.wav")))
        XCTAssertThrowsError(try LocalPCMReader(url: root.appendingPathComponent("audio.mp3")))
        let malformed = root.appendingPathComponent("malformed.wav")
        try Data("not audio".utf8).write(to: malformed)
        XCTAssertThrowsError(try LocalPCMReader(url: malformed))
        XCTAssertThrowsError(try LocalPCMReader(url: makeAudio(rate: 16_000, channels: 1, frames: 0)))
        XCTAssertThrowsError(try LocalPCMReader(url: makeAudio(rate: 16_000, channels: 4, frames: 17)))
        for value: Float in [.nan, .infinity, -.infinity] {
            let reader = try LocalPCMReader(url: makeAudio(rate: 48_000, channels: 2, frames: 100, nonfinite: value))
            XCTAssertThrowsError(try reader.read(maxSamples: 100)) {
                XCTAssertTrue($0.localizedDescription.contains("nonfinite"))
            }
            XCTAssertThrowsError(try reader.read(maxSamples: 100))
        }
    }

    func testCancellationBetweenReads() throws {
        let url = try makeAudio(rate: 48_000, channels: 2, frames: 48_017)
        let finished = expectation(description: "Canceled read")
        Task {
            do {
                let reader = try LocalPCMReader(url: url)
                _ = try reader.read(maxSamples: 1)
                withUnsafeCurrentTask { $0?.cancel() }
                XCTAssertThrowsError(try reader.read(maxSamples: 1)) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertThrowsError(try LocalPCMReader(url: url)) { XCTAssertTrue($0 is CancellationError) }
            } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testPublicM4AFixturePresentationTrim() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("Tests/fixtures/batch-native/combined.m4a")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Public M4A fixture is absent.") }
        let reader = try LocalPCMReader(url: url)
        let samples = try collect(reader, sizes: [1, 701, 16_384])
        let expected = try reference(url)
        XCTAssertEqual(samples.count, expected.count)
        let maxDifference = zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
        print("M4A reference maximum sample difference=\(maxDifference)")
        XCTAssertLessThanOrEqual(maxDifference, 1e-6)
        XCTAssertLessThanOrEqual(abs(samples.count - Int((reader.duration * 16_000).rounded())), 1)
        // This public capture-export fixture has 132301 valid frames at 44100 Hz.
        XCTAssertEqual(reader.duration, 132_301.0 / 44_100, accuracy: 1.0 / 44_100)
        print("M4A valid duration=\(reader.duration), output samples=\(samples.count)")
    }

    func testDurationBoundaryAndBoundedLargeRequest() throws {
        // Sparse PCM16 WAV files test the duration guard without allocating audio.
        for seconds in [7_200, 7_201] {
            let url = root.appendingPathComponent("sparse-\(seconds).wav")
            let dataBytes = UInt32(seconds * 16_000 * 2)
            var header = Data()
            func text(_ value: String) { header.append(contentsOf: value.utf8) }
            func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
            text("RIFF"); u32(dataBytes + 36); text("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
            text("data"); u32(dataBytes)
            try header.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(dataBytes) + 44)
            try handle.close()
            if seconds == 7_200 {
                let reader = try LocalPCMReader(url: url)
                XCTAssertEqual(reader.duration, 7_200)
                XCTAssertEqual(try reader.read(maxSamples: Int.max).count, 16_384)
            } else {
                XCTAssertThrowsError(try LocalPCMReader(url: url)) {
                    XCTAssertTrue($0.localizedDescription.contains("7,200"))
                }
            }
        }
    }

    func testStereoMixIncludesBothChannels() throws {
        let url = try makeAudio(rate: 16_000, channels: 2, frames: 32)
        let samples = try collect(LocalPCMReader(url: url), sizes: [5])
        XCTAssertEqual(samples[0], (0.125 + 0.25) / 2, accuracy: 1e-6)
    }

    func testContinuousConversionPast300Seconds() throws {
        let url = root.appendingPathComponent("301-seconds.caf")
        let sourceFrames = 301 * 48_000 + 7
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 2, interleaved: false))
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let writer = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            var offset = 0
            while offset < sourceFrames {
                let count = min(4_096, sourceFrames - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<2 {
                    for index in 0..<count {
                        buffer.floatChannelData![channel][index] = Float(sin(Double(offset + index) * 0.071)) * 0.25
                            + Float(channel + 1) * 0.125
                    }
                }
                try writer.write(from: buffer)
                offset += count
            }
        }
        let reader = try LocalPCMReader(url: url)
        let expected = try reference(url)
        var offset = 0
        let sizes = [4_093, 16_384, 7, 311]
        var call = 0
        var maxDifference: Float = 0
        while true {
            let block = try reader.read(maxSamples: sizes[call % sizes.count])
            if block.isEmpty { break }
            guard offset + block.count <= expected.count else { return XCTFail("Unexpected extra output") }
            for index in block.indices {
                maxDifference = max(maxDifference, abs(block[index] - expected[offset + index]))
            }
            offset += block.count
            call += 1
        }
        XCTAssertEqual(offset, expected.count)
        XCTAssertLessThanOrEqual(abs(offset - Int((Double(sourceFrames) / 3).rounded())), 1)
        XCTAssertEqual(maxDifference, 0)
        print("301-second stereo count=\(offset), maximum reference difference=\(maxDifference)")
    }
}

#if LOCAL_PCM_STANDALONE
@main
enum LocalPCMReaderTestRunner {
    static func main() {
        let suite = LocalPCMReaderTests.defaultTestSuite
        suite.run()
        guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
        exit(run.hasSucceeded ? 0 : 1)
    }
}
#endif
