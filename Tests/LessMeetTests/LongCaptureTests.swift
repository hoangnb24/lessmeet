import AVFoundation
import CryptoKit
import Darwin
import XCTest
@testable import LessMeet

/// Offline, opt-in only. Run one case per process for meaningful process high-water RSS.
final class LongCaptureTests: XCTestCase {
    func testSyntheticStreamingCapture() async throws {
        guard let value = ProcessInfo.processInfo.environment["LESSMEET_LONG_CAPTURE_SECONDS"] else {
            throw XCTSkip("Set LESSMEET_LONG_CAPTURE_SECONDS to 10, 1800, 3600 or 7200")
        }
        let seconds = try XCTUnwrap(Int(value))
        guard [10, 1800, 3600, 7200].contains(seconds) else {
            XCTFail("Only bounded cases 10/1800/3600/7200 are allowed")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LessMeet-LongCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Hard wall-clock fail-safe also covers a stuck asynchronous exporter. On forced
        // exit the printed directory is left for explicit cleanup; no user audio exists.
        print("LONG_CAPTURE temporaryDirectory=\(directory.path)")
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + 295)
        watchdog.setEventHandler {
            fputs("LONG_CAPTURE exceeded 295s; synthetic directory requires cleanup\n", stderr)
            _exit(124)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let initialRSS = Self.peakRSS()
        let recorder = try CaptureAudioRecorder(directory: directory)
        // Maximum originals: 7200 * (48000 + 24000) * 2 = 1,036,800,000
        // bytes. Reserve another 1 GiB for export, well below the 3 GiB case cap.
        let reserve: Int64 = 1_073_741_824
        let expectedPCM = Int64(seconds) * 144_000
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard Int64(available.volumeAvailableCapacity ?? 0) > expectedPCM + reserve else {
            throw XCTSkip("Insufficient free space for bounded synthetic capture")
        }
        let systemTone = try Self.pcm(rate: 48_000, frequency: 880)
        let micTone = try Self.pcm(rate: 24_000, frequency: 440)
        let systemSilence = try Self.pcm(rate: 48_000, frequency: 0)
        let micSilence = try Self.pcm(rate: 24_000, frequency: 0)
        for second in 0..<seconds {
            try autoreleasepool {
                // Later source arrives first. Alternate 5s tone/5s explicit silence.
                let tone = second % 10 < 5
                try recorder.append(Self.sample(tone ? micTone : micSilence, start: Double(second) + 1000.5), source: .microphone)
                try recorder.append(Self.sample(tone ? systemTone : systemSilence, start: Double(second) + 1000), source: .system)
            }
            if second % 60 == 0 { try Self.checkBounds(directory, start: start) }
        }
        let closed = try recorder.close()
        let captureTime = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(closed.tracks.count, 2)
        XCTAssertEqual(closed.duration.seconds, Double(seconds) + 0.5, accuracy: 0.00001)
        let originals = closed.tracks.map(\.url) + [directory.appendingPathComponent("capture-timeline.json")]
        let hashes = try originals.map { try Self.digest($0) }
        let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: originals.last!)) as! [[String: Any]]
        XCTAssertEqual(timeline.first { $0["source"] as? String == "microphone" }?["offset"] as? Double, 0.5)
        XCTAssertEqual(timeline.first { $0["source"] as? String == "system" }?["offset"] as? Double, 0)
        let exportStart = ProcessInfo.processInfo.systemUptime
        // Monitor export growth with ample headroom below the hard 3 GiB cap.
        let diskGuard = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        diskGuard.schedule(deadline: .now(), repeating: .milliseconds(100))
        diskGuard.setEventHandler {
            if (try? Self.bytes(directory)) ?? Int64.max > 2_500_000_000 {
                fputs("LONG_CAPTURE disk guard exceeded; synthetic directory requires cleanup\n", stderr)
                _exit(125)
            }
        }
        diskGuard.resume()
        defer { diskGuard.cancel() }
        let result = try await closed.exportCombined()
        let exportTime = ProcessInfo.processInfo.systemUptime - exportStart
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.duration, Double(seconds) + 0.5, accuracy: 0.00001)
        XCTAssertEqual(try originals.map { try Self.digest($0) }, hashes, "Export must preserve original bytes and timeline")
        for track in closed.tracks {
            let decoded = try Self.decode(track.url, directory: directory, start: start)
            let rate = track.source == .system ? 48_000.0 : 24_000.0
            XCTAssertEqual(decoded.frames, Int64(Double(seconds) * rate))
            XCTAssertEqual(decoded.rate, rate)
        }
        let combined = directory.appendingPathComponent("combined.m4a")
        let decoded = try Self.decode(combined, directory: directory, start: start)
        let expectedFrames = Int64(((Double(seconds) + 0.5) * decoded.rate).rounded())
        // Allow one AAC packet of encoder padding; report exact decoded count.
        XCTAssertLessThanOrEqual(abs(decoded.frames - expectedFrames), 1024)
        XCTAssertGreaterThan(decoded.toneRMS, 0.1)
        XCTAssertLessThan(decoded.silenceRMS, 0.005)
        let size = try combined.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let total = try Self.bytes(directory)
        try Self.checkBounds(directory, start: start)
        print("LONG_CAPTURE seconds=\(seconds) captureSeconds=\(captureTime) exportSeconds=\(exportTime) totalSeconds=\(ProcessInfo.processInfo.systemUptime - start) m4aBytes=\(size) admission18MiB=\(size <= 18 * 1024 * 1024) temporaryBytes=\(total) decodedFrames=\(decoded.frames) decodedRate=\(decoded.rate) decodedSeconds=\(Double(decoded.frames) / decoded.rate) originalsSHA256Preserved=true toneRMS=\(decoded.toneRMS) silenceRMS=\(decoded.silenceRMS) initialProcessPeakRSSBytes=\(initialRSS) finalProcessPeakRSSBytes=\(Self.peakRSS())")
    }

    private static func pcm(rate: Double, frequency: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        pcm.frameLength = pcm.frameCapacity
        for frame in 0..<Int(pcm.frameLength) {
            pcm.floatChannelData![0][frame] = Float(0.6 * sin(2 * .pi * frequency * Double(frame) / rate))
        }
        return pcm
    }

    private static func sample(_ pcm: AVAudioPCMBuffer, start: Double) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr else { throw Failure.audio }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr else { throw Failure.audio }
        let result = try XCTUnwrap(sample)
        guard CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
            CMSampleBufferSetDataReady(result) == noErr else { throw Failure.audio }
        return result
    }

    private static func decode(_ url: URL, directory: URL, start: Double) throws -> (frames: Int64, rate: Double, toneRMS: Double, silenceRMS: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        var frames: Int64 = 0
        var toneSum = 0.0, silenceSum = 0.0
        var toneCount = 0, silenceCount = 0
        let rate = file.processingFormat.sampleRate
        while frames < file.length {
            let count = AVAudioFrameCount(min(8192, file.length - frames))
            try autoreleasepool { try file.read(into: buffer, frameCount: count) }
            if buffer.frameLength == 0 { break }
            // Inspect a bounded first-cycle window; count every decoded frame to EOF.
            if frames < Int64(9 * rate) {
                let data = try XCTUnwrap(buffer.floatChannelData)[0]
                for frame in 0..<Int(buffer.frameLength) {
                    let time = Double(frames + Int64(frame)) / rate
                    let squared = Double(data[frame]) * Double(data[frame])
                    if time >= 1 && time < 4 { toneSum += squared; toneCount += 1 }
                    if time >= 6 && time < 9 { silenceSum += squared; silenceCount += 1 }
                }
            }
            frames += Int64(buffer.frameLength)
            if frames % (8192 * 256) == 0 { try checkBounds(directory, start: start) }
        }
        XCTAssertEqual(frames, file.length, "Decoded frame count must match the complete file")
        return (frames, rate, sqrt(toneSum / Double(max(toneCount, 1))), sqrt(silenceSum / Double(max(silenceCount, 1))))
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ directory: URL) throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    private static func checkBounds(_ directory: URL, start: Double) throws {
        guard ProcessInfo.processInfo.systemUptime - start < 290,
              try bytes(directory) < 2_500_000_000 else { throw Failure.bound }
    }

    private static func peakRSS() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss) // Darwin reports bytes; process lifetime, not a delta.
    }

    private enum Failure: Error { case audio, bound }
}
