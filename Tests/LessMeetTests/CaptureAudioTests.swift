import AVFoundation
import XCTest
@testable import LessMeet

final class CaptureAudioTests: XCTestCase {
    func testRealCAFAndM4AExportPreservesSharedOffsetsGapsAndDuration() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        // Later PTS arrives first. The two devices also have different sample rates.
        try recorder.append(Self.tone(start: 1000.5, duration: 0.125, rate: 24_000, frequency: 440), source: .microphone)
        try recorder.append(Self.tone(start: 1000, duration: 0.25, frequency: 880), source: .system)
        try recorder.append(Self.tone(start: 1000.625, duration: 0.125, rate: 24_000, frequency: 440), source: .microphone)
        try recorder.append(Self.tone(start: 1001, duration: 0.25, frequency: 880), source: .system)
        let closed = try recorder.close()
        let result = try await closed.exportCombined()
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.duration, 1.25, accuracy: 0.0001)

        let system = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        let microphone = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(system.length, 60_000)
        XCTAssertEqual(microphone.length, 6_000)
        system.close()
        microphone.close()
        let url = directory.appendingPathComponent("combined.m4a")
        // Optional cross-runtime billing fixture: synthetic tones only, never user audio.
        if let output = ProcessInfo.processInfo.environment["LESSMEET_SYNTHETIC_M4A_OUTPUT"] {
            try Data(contentsOf: url).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(duration.seconds, 1.25, accuracy: 0.025)
        let audio = try read(url)
        XCTAssertGreaterThan(rms(audio, from: 0.05, to: 0.2), 0.15)
        XCTAssertLessThan(rms(audio, from: 0.3, to: 0.45), 0.005)
        XCTAssertGreaterThan(rms(audio, from: 0.55, to: 0.7), 0.15)
        XCTAssertLessThan(rms(audio, from: 0.8, to: 0.95), 0.005)
        XCTAssertGreaterThan(rms(audio, from: 1.05, to: 1.2), 0.15)
        let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("capture-timeline.json"))) as! [[String: Any]]
        XCTAssertEqual(timeline.first { $0["source"] as? String == "microphone" }?["offset"] as? Double, 0.5)
        XCTAssertThrowsError(try recorder.append(Self.tone(start: 1002, duration: 0.1), source: .system))
    }

    func testMissingSourceExportsUsableAudioWithWarning() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        try recorder.append(Self.tone(start: 500, duration: 0.25), source: .microphone)
        let result = try await recorder.close().exportCombined()
        XCTAssertTrue(result.warning?.contains("No system audio") == true)
        XCTAssertEqual(result.duration, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(try rms(read(directory.appendingPathComponent("combined.m4a")), from: 0.05, to: 0.2), 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.caf").path))
    }

    func testEmptyCaptureFailsWithoutPublishingCombinedFile() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        XCTAssertThrowsError(try recorder.close()) { XCTAssertTrue($0.localizedDescription.contains("No audio was captured")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("combined.m4a").path))
    }

    func testOverlappingPTSAndFormatChangeFailWithoutLosingOriginal() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        try recorder.append(Self.tone(start: 100, duration: 0.25), source: .microphone)
        XCTAssertThrowsError(try recorder.append(Self.tone(start: 100.1, duration: 0.1), source: .microphone))
        XCTAssertThrowsError(try recorder.append(Self.tone(start: 100.25, duration: 0.1, rate: 24_000), source: .microphone))
        _ = try recorder.close(warning: "Interrupted")
        let original = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(original.length, 12_000)
        original.close()
    }

    func testLongSystemSilenceIsPreservedRatherThanTreatedAsDeviceFailure() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        try recorder.append(Self.tone(start: 100, duration: 0.25), source: .system)
        try recorder.append(Self.tone(start: 110, duration: 0.25), source: .system)
        let result = try await recorder.close().exportCombined()
        XCTAssertEqual(result.duration, 10.25, accuracy: 0.0001)
        let decoded = try read(directory.appendingPathComponent("combined.m4a"))
        XCTAssertLessThan(rms(decoded, from: 1, to: 9), 0.005)
        XCTAssertGreaterThan(rms(decoded, from: 10.05, to: 10.2), 0.3)
    }

    func testOutputQueueDrainsBeforeClosingAndReportsFailureOnlyOnce() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = expectation(description: "failure delivered once")
        failure.assertForOverFulfill = true
        let output = try CaptureOutput(directory: directory) { message in
            XCTAssertTrue(message.contains("overlap"))
            failure.fulfill()
        }
        output.queue.async {
            do {
                let first = try Self.tone(start: 100, duration: 0.25)
                let second = try Self.tone(start: 100.25, duration: 0.25)
                let overlapping = try Self.tone(start: 100.3, duration: 0.25)
                output.receive(first, source: .microphone)
                output.receive(second, source: .microphone)
                output.receive(overlapping, source: .microphone)
                output.receive(overlapping, source: .microphone)
            } catch { XCTFail(error.localizedDescription) }
        }
        let closed = try await output.close()
        await fulfillment(of: [failure], timeout: 2)
        let result = try await closed.exportCombined()
        XCTAssertEqual(result.duration, 0.5, accuracy: 0.0001)
        XCTAssertTrue(result.warning?.contains("overlap") == true)
        let original = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(original.length, 24_000)
        original.close()
    }

    func testStartupFailureThrowsAtProductionStartupBarrier() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try CaptureOutput(directory: directory) { _ in }
        output.interrupt("Synthetic startup failure")
        do {
            try await output.checkStartup()
            XCTFail("An already-failed stream must not complete startup successfully")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Synthetic startup failure")
        }
        do { _ = try await output.close(); XCTFail("Empty startup failure must not produce a recording") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No audio was captured")) }
    }

    func testClockValidationAllowsSourceSilenceButRejectsCorruptTimestamp() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = expectation(description: "invalid timestamp")
        let output = try CaptureOutput(directory: directory) { message in
            XCTAssertTrue(message.contains("stream clock"))
            failure.fulfill()
        }
        output.queue.async {
            do {
                let first = try Self.tone(start: 100, duration: 0.25)
                let afterSilence = try Self.tone(start: 110, duration: 0.25)
                let corrupt = try Self.tone(start: 1_000_000_000, duration: 0.25)
                output.receive(first, source: .system, clockTime: CMTime(seconds: 100.25, preferredTimescale: 48_000))
                output.receive(afterSilence, source: .system, clockTime: CMTime(seconds: 110.25, preferredTimescale: 48_000))
                output.receive(corrupt, source: .system, clockTime: CMTime(seconds: 110.5, preferredTimescale: 48_000))
            } catch { XCTFail(error.localizedDescription) }
        }
        let audio = try await output.close()
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertEqual(audio.duration.seconds, 10.25, accuracy: 0.0001)
        let original = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        XCTAssertEqual(original.length, 492_000)
        original.close()
    }

    func testFailedExportPreservesOriginalsAndDoesNotOverwriteExistingCombined() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try CaptureAudioRecorder(directory: directory)
        try recorder.append(Self.tone(start: 1, duration: 0.25), source: .system)
        let audio = try recorder.close()
        let combined = directory.appendingPathComponent("combined.m4a")
        let existing = Data("existing user file".utf8)
        try existing.write(to: combined)
        do {
            _ = try await audio.exportCombined()
            XCTFail("Export must not replace an existing file")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preserved"))
        }
        XCTAssertEqual(try Data(contentsOf: combined), existing)
        let original = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        XCTAssertEqual(original.length, 12_000)
        original.close()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("partial") })
        XCTAssertThrowsError(try CaptureAudioRecorder(directory: directory))
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LessMeet-CaptureTests-\(UUID().uuidString)")
    }

    private static func tone(start: Double, duration: Double, rate: Double = 48_000, frequency: Double = 440) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = Int((duration * rate).rounded())
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            pcm.floatChannelData![0][frame] = Float(0.6 * sin(2 * .pi * frequency * Double(frame) / rate))
        }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                                                     layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                     extensions: nil, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                       presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                                           sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                                                                     blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                     flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }

    private func read(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    private func rms(_ audio: (samples: [Float], rate: Double), from: Double, to: Double) -> Double {
        let start = Int(from * audio.rate)
        let end = min(Int(to * audio.rate), audio.samples.count)
        guard start < end else { return 0 }
        return sqrt(audio.samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start))
    }
}
