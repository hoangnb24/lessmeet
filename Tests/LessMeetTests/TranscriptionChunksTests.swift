import AVFoundation
import Darwin
import XCTest
@testable import LessMeet

final class TranscriptionChunksTests: XCTestCase {
    func testStereoFractionalPresentationPrecision() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for rate in [44_100, 48_000] {
            for frames in [3 * rate - 1, 3 * rate + 1, 300 * rate - 1, 300 * rate + 1] {
                let source = root.appendingPathComponent("stereo-\(rate)-\(frames).caf")
                try stereoFixture(source, rate: rate, frames: frames)
                let manifest = try await TranscriptionChunks.prepare(source: source,
                    destination: root.appendingPathComponent("chunks-\(rate)-\(frames)"))
                XCTAssertEqual(manifest.sourceDuration.cmTime, CMTime(value: Int64(frames), timescale: Int32(rate)))
                for chunk in manifest.chunks {
                    print("CHUNKS precision rate=\(rate) sourceFrames=\(frames) requested=\(chunk.window.duration.value)/\(chunk.window.duration.timescale) actual=\(chunk.presentationDuration.value)/\(chunk.presentationDuration.timescale) actualDecodedFrames=\(chunk.decodedFrames) outputRate=\(chunk.sampleRate)")
                    XCTAssertEqual(chunk.channels, 2)
                    XCTAssertEqual(chunk.sampleRate, Double(rate))
                    XCTAssertEqual(chunk.presentationDuration.cmTime, chunk.window.range.duration)
                    XCTAssertEqual(CMTime(value: chunk.decodedFrames, timescale: Int32(rate)), chunk.window.range.duration)
                }
            }
        }
    }

    func testDecodeReadFailuresAndCancellation() async throws {
        XCTAssertThrowsError(try TranscriptionChunks.countDecodedFrames(expected: 0) { $0 })
        XCTAssertThrowsError(try TranscriptionChunks.countDecodedFrames(expected: 9000) { _ in 0 }) {
            XCTAssertEqual($0 as? TranscriptionChunks.Failure, .decodedLengthMismatch)
        }
        XCTAssertThrowsError(try TranscriptionChunks.countDecodedFrames(expected: 9000) { $0 + 1 })
        enum ReadError: Error { case corrupt }
        XCTAssertThrowsError(try TranscriptionChunks.countDecodedFrames(expected: 9000) { _ in throw ReadError.corrupt }) {
            XCTAssertTrue($0 is ReadError)
        }
        var calls = 0
        XCTAssertThrowsError(try TranscriptionChunks.countDecodedFrames(expected: 9000) { count in
            calls += 1
            return calls == 1 ? count : 0
        })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try TranscriptionChunks.countDecodedFrames(expected: 9000) { min($0, 1000) }, 9000)
        let task = Task {
            var reads = 0
            do {
                _ = try TranscriptionChunks.countDecodedFrames(expected: 9000) { requested in
                    reads += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return requested
                }
                XCTFail("Cancellation must be checked between reads")
            } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
            return reads
        }
        let reads = await task.value
        XCTAssertEqual(reads, 1)
    }

    func testSourceChangeAndCorruptOutputCleanOwnedStaging() async throws {
        for mode in ["source-change", "corrupt-output", "oversize-seam"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.caf")
            try fixture(source, seconds: 3)
            let before = try TranscriptionChunks.identity(source)
            var changed: TranscriptionChunks.Identity?
            let sentinel = root.appendingPathComponent("keep")
            try Data([7]).write(to: sentinel)
            do {
                _ = try await TranscriptionChunks.prepare(source: source, destination: root.appendingPathComponent("chunks"), afterExport: { output in
                    if mode == "source-change" {
                        let handle = try FileHandle(forWritingTo: source)
                        defer { try? handle.close() }
                        try handle.seekToEnd(); try handle.write(contentsOf: Data([9]))
                        changed = try TranscriptionChunks.identity(source)
                    } else {
                        let handle = try FileHandle(forWritingTo: output)
                        defer { try? handle.close() }
                        try handle.truncate(atOffset: mode == "oversize-seam" ? UInt64(TranscriptionChunks.maximumBytes + 1) : 128)
                    }
                })
                XCTFail("Injected \(mode) must reject")
            } catch {
                if mode == "source-change" { XCTAssertEqual(error as? TranscriptionChunks.Failure, .sourceChanged) }
                if mode == "oversize-seam" { XCTAssertEqual(error as? TranscriptionChunks.Failure, .oversized) }
            }
            XCTAssertEqual(try TranscriptionChunks.identity(source), changed ?? before)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.caf", "keep"])
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([7]))
        }
    }

    func testRealDenseStereoPreviouslyOversizeSucceedsWith300SecondWindows() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("dense.caf")
        try stereoFixture(source, rate: 48_000, frames: 600 * 48_000 - 1, dense: true)
        let before = try TranscriptionChunks.identity(source)
        // Retain the exact dense fixture and reproduce the old single-window result.
        let captured = CapturedAudio(directory: root, tracks: [.init(source: .system, url: source, start: .zero,
            duration: CMTime(value: 600 * 48_000 - 1, timescale: 48_000))], warning: "")
        _ = try await captured.exportCombined()
        let oldOutput = try TranscriptionChunks.identity(root.appendingPathComponent("combined.m4a"))
        XCTAssertGreaterThan(oldOutput.bytes, TranscriptionChunks.maximumBytes)
        let destination = root.appendingPathComponent("chunks")
        let manifest = try await TranscriptionChunks.prepare(source: source, destination: destination)
        XCTAssertEqual(manifest.chunks.count, 3)
        for chunk in manifest.chunks {
            XCTAssertLessThanOrEqual(chunk.file.bytes, TranscriptionChunks.maximumBytes)
            XCTAssertLessThanOrEqual(chunk.presentationDuration.cmTime, CMTime(value: 300, timescale: 1))
            XCTAssertEqual(chunk.channels, 2)
            XCTAssertEqual(chunk.sampleRate, 48_000)
            let file = try AVAudioFile(forReading: destination.appendingPathComponent(chunk.file.name))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
            var frames: Int64 = 0
            while frames < file.length {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - frames)))
                if buffer.frameLength == 0 { break }
                frames += Int64(buffer.frameLength)
            }
            file.close()
            XCTAssertEqual(frames, chunk.decodedFrames)
            XCTAssertEqual(CMTime(value: frames, timescale: 48_000), chunk.window.range.duration)
        }
        XCTAssertEqual(try TranscriptionChunks.identity(source), before)
        XCTAssertEqual(try TranscriptionChunks.identity(root.appendingPathComponent("combined.m4a")), oldOutput)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["dense.caf", "combined.m4a", "chunks"])
        print("CHUNKS dense oldSingleWindowBytes=\(oldOutput.bytes) sourceSHA=\(before.sha256) sourcePreserved=true newBytes=\(manifest.chunks.map { $0.file.bytes }) actualFrames=\(manifest.chunks.map(\.decodedFrames))")
    }

    func testOutputDurationMismatchAndSubsampleRequestReject() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try stereoFixture(source, rate: 44_100, frames: 3 * 44_100 + 1)
        let destination = root.appendingPathComponent("chunks")
        let manifest = try await TranscriptionChunks.prepare(source: source, destination: destination)
        let chunk = manifest.chunks[0]
        let output = destination.appendingPathComponent(chunk.file.name)
        for wrong in [CMTime(value: 3, timescale: 1), CMTime(value: 264603, timescale: 88200)] {
            let window = TranscriptionChunks.Window(index: 0, start: .init(.zero), duration: .init(wrong))
            do {
                _ = try await TranscriptionChunks.validateOutput(output, window: window, file: chunk.file)
                XCTFail("No one-frame or half-frame tolerance is permitted")
            } catch TranscriptionChunks.Failure.presentationMismatch {}
        }
        // A PCM CAF cannot masquerade as a generated AAC-LC derivative.
        do {
            _ = try await TranscriptionChunks.validateOutput(source, window: chunk.window, file: try TranscriptionChunks.identity(source))
            XCTFail("PCM output must reject")
        } catch TranscriptionChunks.Failure.unsupportedFormat {}
    }

    private func stereoFixture(_ url: URL, rate: Int, frames: Int, dense: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        for channel in 0..<2 {
            for frame in 0..<8192 {
                buffer.floatChannelData![channel][frame] = Float(0.4 * sin(2 * .pi * Double(440 + channel * 440) * Double(frame) / Double(rate)))
            }
        }
        var remaining = frames
        while remaining > 0 {
            if !dense && frames > 10 * rate && frames - remaining > rate {
                for channel in 0..<2 {
                    buffer.floatChannelData![channel].initialize(repeating: 0, count: 8192)
                }
            }
            buffer.frameLength = AVAudioFrameCount(min(8192, remaining))
            try file.write(from: buffer)
            remaining -= Int(buffer.frameLength)
        }
    }

    func testExactBoundaries() throws {
        XCTAssertNoThrow(try TranscriptionChunks.validateByteLength(18 * 1024 * 1024))
        XCTAssertThrowsError(try TranscriptionChunks.validateByteLength(18 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try TranscriptionChunks.validateByteLength(0))
        for rate: Int32 in [24_000, 44_100, 48_000] {
            for seconds: Int64 in [295, 300, 590, 595, 7200] {
                for delta: Int64 in [-1, 0, 1] {
                    let duration = CMTime(value: seconds * Int64(rate) + delta, timescale: rate)
                    if duration > CMTime(value: 7200, timescale: 1) {
                        XCTAssertThrowsError(try TranscriptionChunks.windows(duration: duration)); continue
                    }
                    let windows = try TranscriptionChunks.windows(duration: duration)
                    XCTAssertLessThanOrEqual(windows.count, 25)
                    XCTAssertEqual(windows.first!.range.start, .zero)
                    XCTAssertEqual(windows.last!.range.end, duration)
                    for (index, window) in windows.enumerated() {
                        XCTAssertEqual(window.index, index)
                        XCTAssertGreaterThan(window.range.duration, .zero)
                        XCTAssertLessThanOrEqual(window.range.duration, CMTime(value: 300, timescale: 1))
                        if index > 0 {
                            XCTAssertEqual(CMTimeSubtract(windows[index - 1].range.end, window.range.start), CMTime(value: 5, timescale: 1))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(try TranscriptionChunks.windows(duration: CMTime(value: 300, timescale: 1)).count, 1)
        XCTAssertEqual(try TranscriptionChunks.windows(duration: CMTime(value: 595, timescale: 1)).count, 2)
        XCTAssertEqual(try TranscriptionChunks.windows(duration: CMTime(value: 7200, timescale: 1)).count, 25)
        let full = try TranscriptionChunks.windows(duration: CMTime(value: 7200, timescale: 1))
        XCTAssertEqual(full.last!.range.duration, CMTime(value: 120, timescale: 1))
        XCTAssertEqual(full.reduce(CMTime.zero) { CMTimeAdd($0, $1.range.duration) }, CMTime(value: 7320, timescale: 1))
        for time in [CMTime.zero, .invalid, .indefinite, CMTime(value: -1, timescale: 1), CMTime(value: 72004993, timescale: 10000)] {
            XCTAssertThrowsError(try TranscriptionChunks.windows(duration: time))
        }
    }

    func testBoundaryTonesPreservationAndNoOverwrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("system.caf")
        try fixture(source, seconds: 301)
        let timeline = root.appendingPathComponent("capture-timeline.json")
        try Data("synthetic timeline sentinel".utf8).write(to: timeline)
        // Exercise the actual combined AAC input as well as CAF input, with unchanged capture exporter.
        let captured = CapturedAudio(directory: root, tracks: [.init(source: .system, url: source, start: .zero,
            duration: CMTime(value: 301, timescale: 1))], warning: "")
        _ = try await captured.exportCombined()
        let combined = root.appendingPathComponent("combined.m4a")
        let originals = [source, timeline, combined]
        let before = try originals.map(TranscriptionChunks.identity)
        let overlongWindow = TranscriptionChunks.Window(index: 0, start: .init(.zero), duration: .init(CMTime(value: 301, timescale: 1)))
        do {
            _ = try await TranscriptionChunks.validateOutput(combined, window: overlongWindow, file: before[2])
            XCTFail("Actual 301-second media must reject even when the requested duration agrees")
        } catch TranscriptionChunks.Failure.presentationMismatch {}
        let destination = root.appendingPathComponent("chunks")
        let manifest = try await TranscriptionChunks.prepare(source: combined, destination: destination)
        XCTAssertEqual(manifest.chunks.count, 2)
        XCTAssertEqual(manifest.source, before[2])
        for chunk in manifest.chunks {
            let url = destination.appendingPathComponent(chunk.file.name)
            XCTAssertEqual(try TranscriptionChunks.identity(url), chunk.file)
            XCTAssertLessThanOrEqual(chunk.file.bytes, TranscriptionChunks.maximumBytes)
            XCTAssertEqual(chunk.channels, 1)
            XCTAssertEqual(CMTime(value: chunk.decodedFrames, timescale: Int32(chunk.sampleRate)), chunk.window.range.duration)
        }
        // Tone at source [295,296), silence [296,297), tone [299,300), silence [300,301).
        let second = destination.appendingPathComponent(manifest.chunks[1].file.name)
        XCTAssertGreaterThan(try rms(second, start: 0.1), 0.1)
        XCTAssertLessThan(try rms(second, start: 1.1), 0.005)
        XCTAssertGreaterThan(try rms(second, start: 4.1), 0.1)
        XCTAssertLessThan(try rms(second, start: 5.1), 0.005)
        // Report the lossy threshold crossing; do not turn it into an admission tolerance.
        let transition = try lastLoudFrame(second, from: 0.9, to: 1.1)
        do { _ = try await TranscriptionChunks.prepare(source: combined, destination: destination); XCTFail("overwrite") }
        catch TranscriptionChunks.Failure.destinationExists {}
        XCTAssertEqual(try originals.map(TranscriptionChunks.identity), before)
        print("CHUNKS short source=\(manifest.source.sha256) chunks=\(manifest.chunks.count) transitionFrame=\(transition) metadata=\(String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!)")
    }

    func testCancellationCleansOnlyOwnedOutputs() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try fixture(source, seconds: 601)
        let before = try TranscriptionChunks.identity(source)
        let sentinel = root.appendingPathComponent("unrelated.partial")
        try Data([1, 2, 3]).write(to: sentinel)
        let destination = root.appendingPathComponent("chunks")
        let task = Task { try await TranscriptionChunks.prepare(source: source, destination: destination) }
        var sawStaging = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".chunks-") }) {
                sawStaging = true; break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel must fail") } catch {}
        XCTAssertTrue(sawStaging, "Cancellation must exercise active preparation")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.caf", "unrelated.partial"])
        XCTAssertEqual(try TranscriptionChunks.identity(source), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 2, 3]))
    }

    func testOptInExact120Minutes() async throws {
        guard ProcessInfo.processInfo.environment["LESSMEET_EXACT_CHUNKS_120"] == "1" else { throw XCTSkip("Opt-in bounded exact 120-minute fixture") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        print("CHUNKS long scratch=\(root.path)")
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 295)
        watchdog.setEventHandler { _exit(124) }; watchdog.resume()
        defer { watchdog.cancel() }
        let disk = DispatchSource.makeTimerSource(queue: .global())
        disk.schedule(deadline: .now(), repeating: .milliseconds(100))
        disk.setEventHandler {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            var bytes = 0
            while let url = files?.nextObject() as? URL { bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            if bytes > 2_500_000_000 { _exit(125) }
        }
        disk.resume(); defer { disk.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let source = root.appendingPathComponent("exact7200.caf")
        try fixture(source, seconds: 7200)
        let before = try TranscriptionChunks.identity(source)
        let manifest = try await TranscriptionChunks.prepare(source: source, destination: root.appendingPathComponent("chunks"))
        XCTAssertEqual(manifest.sourceDuration.cmTime, CMTime(value: 7200, timescale: 1))
        XCTAssertEqual(manifest.chunks.count, 25)
        XCTAssertEqual(manifest.chunks.last!.window.range.duration, CMTime(value: 120, timescale: 1))
        XCTAssertEqual(manifest.chunks.reduce(CMTime.zero) { CMTimeAdd($0, $1.window.range.duration) }, CMTime(value: 7320, timescale: 1))
        XCTAssertEqual(try TranscriptionChunks.identity(source), before)
        XCTAssertTrue(manifest.chunks.allSatisfy { $0.file.bytes <= TranscriptionChunks.maximumBytes })
        for chunk in manifest.chunks {
            let file = try AVAudioFile(forReading: root.appendingPathComponent("chunks").appendingPathComponent(chunk.file.name))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
            var frames: Int64 = 0
            while frames < file.length {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - frames)))
                if buffer.frameLength == 0 { break }
                frames += Int64(buffer.frameLength)
            }
            file.close()
            XCTAssertEqual(frames, chunk.decodedFrames)
            XCTAssertEqual(CMTime(value: frames, timescale: Int32(chunk.sampleRate)), chunk.window.range.duration)
        }
        print("CHUNKS exact7200 elapsed=\(ProcessInfo.processInfo.systemUptime - start) sourceBytes=\(before.bytes) sourceSHA=\(before.sha256) outputBytes=\(manifest.chunks.reduce(0) { $0 + $1.file.bytes }) metadata=\(String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!)")
        // Same watchdog/disk budget also covers the actual combined AAC source route.
        let captured = CapturedAudio(directory: root, tracks: [.init(source: .system, url: source, start: .zero,
            duration: CMTime(value: 7200, timescale: 1))], warning: "")
        _ = try await captured.exportCombined()
        let combined = root.appendingPathComponent("combined.m4a")
        let combinedBefore = try TranscriptionChunks.identity(combined)
        let aac = try await TranscriptionChunks.prepare(source: combined, destination: root.appendingPathComponent("aac-chunks"))
        XCTAssertEqual(aac.sourceDuration.cmTime, CMTime(value: 7200, timescale: 1))
        XCTAssertEqual(aac.chunks.count, 25)
        XCTAssertEqual(aac.chunks.last!.window.range.duration, CMTime(value: 120, timescale: 1))
        XCTAssertEqual(aac.chunks.reduce(CMTime.zero) { CMTimeAdd($0, $1.window.range.duration) }, CMTime(value: 7320, timescale: 1))
        XCTAssertEqual(try TranscriptionChunks.identity(combined), combinedBefore)
        XCTAssertEqual(try TranscriptionChunks.identity(source), before)
        print("CHUNKS exact7200 AAC totalElapsed=\(ProcessInfo.processInfo.systemUptime - start) sourceBytes=\(combinedBefore.bytes) sourceSHA=\(combinedBefore.sha256) outputBytes=\(aac.chunks.reduce(0) { $0 + $1.file.bytes }) actualFrames=\(aac.chunks.map(\.decodedFrames))")
    }

    func testPublishFailurePreservesConcurrentDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try fixture(source, seconds: 601)
        let before = try TranscriptionChunks.identity(source)
        let destination = root.appendingPathComponent("chunks")
        let task = Task { try await TranscriptionChunks.prepare(source: source, destination: destination) }
        var sawStaging = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".chunks-") }) {
                sawStaging = true; break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep")
        try Data([4, 5, 6]).write(to: sentinel)
        do { _ = try await task.value; XCTFail("Concurrent destination must not be overwritten") } catch {}
        XCTAssertTrue(sawStaging)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([4, 5, 6]))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.caf", "chunks"])
        XCTAssertEqual(try TranscriptionChunks.identity(source), before)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LessMeet-Chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func fixture(_ url: URL, seconds: Int) throws {
        let available = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard available > seconds * 48_000 + 200_000_000 else { throw XCTSkip("Insufficient bounded scratch space") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        silence.frameLength = 24_000
        for frame in 0..<24_000 {
            buffer.floatChannelData![0][frame] = Float(0.5 * sin(2 * .pi * 440 * Double(frame) / 24_000))
            silence.floatChannelData![0][frame] = 0
        }
        for second in 0..<seconds {
            let tone = [295, 299].contains(second) || (second % 10 == 0 && second != 300)
            try file.write(from: tone ? buffer : silence)
        }
    }
    private func rms(_ url: URL, start: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url); defer { file.close() }
        file.framePosition = Int64(start * file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2400)!
        try file.read(into: buffer)
        return sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) } / Double(buffer.frameLength))
    }
    private func lastLoudFrame(_ url: URL, from: Double, to: Double) throws -> Int64 {
        let file = try AVAudioFile(forReading: url); defer { file.close() }
        let start = Int64(from * file.processingFormat.sampleRate)
        file.framePosition = start
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount((to - from) * file.processingFormat.sampleRate))!
        try file.read(into: buffer)
        return start + Int64((0..<Int(buffer.frameLength)).last { abs(buffer.floatChannelData![0][$0]) > 0.05 } ?? 0)
    }
}
