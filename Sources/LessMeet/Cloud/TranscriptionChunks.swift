import AVFoundation
import CryptoKit

/// Local preparation only. This manifest is not trusted server-side admission evidence.
enum TranscriptionChunks {
    static let maximumBytes = 18 * 1024 * 1024
    struct Time: Codable, Equatable {
        let value: Int64
        let timescale: Int32
        init(_ time: CMTime) { value = time.value; timescale = time.timescale }
        var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    }
    struct Window: Codable, Equatable {
        let index: Int
        let start: Time
        let duration: Time
        var range: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
    }
    struct Identity: Codable, Equatable {
        let name: String
        let bytes: Int
        let sha256: String
    }
    struct Chunk: Codable {
        let window: Window
        let file: Identity
        let presentationDuration: Time
        let decodedFrames: Int64
        let sampleRate: Double
        let channels: UInt32
    }
    struct Manifest: Codable {
        let version: Int
        let source: Identity
        let sourceDuration: Time
        let chunks: [Chunk]
    }
    enum Failure: Error, Equatable {
        case invalidDuration, unsupportedFormat, exportUnavailable, oversized, sourceChanged, destinationExists
        case presentationMismatch, decodedLengthMismatch
    }

    // Matches the existing media-admission sample-rate policy, not a resampling request.
    static let acceptedSampleRates: Set<Double> = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    /// Half-open ranges in presentation time; no floating point boundary decisions.
    static func windows(duration: CMTime) throws -> [Window] {
        guard duration.isNumeric, duration.epoch == 0, duration > .zero,
              duration <= CMTime(value: 7200, timescale: 1) else { throw Failure.invalidDuration }
        var result: [Window] = []
        var start = CMTime.zero
        while start < duration {
            let length = CMTimeMinimum(CMTimeSubtract(duration, start), CMTime(value: 300, timescale: 1))
            result.append(Window(index: result.count, start: Time(start), duration: Time(length)))
            if CMTimeAdd(start, length) == duration { break }
            start = CMTimeAdd(start, CMTime(value: 295, timescale: 1))
        }
        return result
    }

    /// Destination must not exist. Caller must keep the closed source immutable during preparation.
    /// Only our unique staging directory is removed on failure/cancellation; originals are never written.
    static func prepare(source: URL, destination: URL) async throws -> Manifest {
        try await prepare(source: source, destination: destination, afterExport: nil)
    }

    // Narrow fault-injection seam: called before all output checks; never bypasses admission.
    // Production callers use the two-argument entry point above.
    static func prepare(source: URL, destination: URL, afterExport: ((URL) throws -> Void)?) async throws -> Manifest {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        let original = try identity(source)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, try await asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.unsupportedFormat }
        let track = tracks[0]
        let timeRange = try await track.load(.timeRange)
        let duration = try await asset.load(.duration)
        guard timeRange.start == .zero, timeRange.duration == duration else { throw Failure.unsupportedFormat }
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0]),
              [kAudioFormatLinearPCM, kAudioFormatMPEG4AAC].contains(basic.pointee.mFormatID),
              basic.pointee.mChannelsPerFrame > 0, basic.pointee.mChannelsPerFrame <= 2,
              basic.pointee.mSampleRate > 0, basic.pointee.mSampleRate.isFinite else { throw Failure.unsupportedFormat }
        let windows = try windows(duration: duration)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".chunks-\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var chunks: [Chunk] = []
        for window in windows {
            try Task.checkCancellation()
            // Composition forces an independent derivative rather than packet passthrough.
            let composition = AVMutableComposition()
            guard let outputTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.exportUnavailable }
            try outputTrack.insertTimeRange(window.range, of: track, at: .zero)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.exportUnavailable }
            let output = staging.appendingPathComponent(String(format: "chunk-%02d.m4a", window.index))
            try await exporter.export(to: output, as: .m4a)
            try Task.checkCancellation()
            try afterExport?(output)
            let file = try identity(output)
            try validateByteLength(file.bytes)
            chunks.append(try await validateOutput(output, window: window, file: file))
        }
        guard try identity(source) == original else { throw Failure.sourceChanged }
        let manifest = Manifest(version: 1, source: original, sourceDuration: Time(duration), chunks: chunks)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try Task.checkCancellation()
        // moveItem fails if the destination exists, including a concurrent preparer's output.
        try fm.moveItem(at: staging, to: destination)
        return manifest
    }

    /// Exact presentation policy: no packet tolerance, sample rounding, or trimming.
    /// AVAudioFile exposes presentation PCM after decoder priming/remainder handling,
    /// not the raw AAC packet sample count. Read every such frame in bounded buffers.
    static func validateOutput(_ url: URL, window: Window, file: Identity) async throws -> Chunk {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, try await asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.unsupportedFormat }
        let range = try await tracks[0].load(.timeRange)
        let actual = try await asset.load(.duration)
        guard actual.isNumeric, actual.epoch == 0, actual > .zero,
              actual <= CMTime(value: 300, timescale: 1), range.start == .zero,
              range.duration == actual, actual == window.range.duration else { throw Failure.presentationMismatch }
        let descriptions = try await tracks[0].load(.formatDescriptions)
        guard descriptions.count == 1,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0]),
              basic.pointee.mFormatID == kAudioFormatMPEG4AAC,
              (1...2).contains(basic.pointee.mChannelsPerFrame),
              acceptedSampleRates.contains(basic.pointee.mSampleRate) else { throw Failure.unsupportedFormat }
        let rate = basic.pointee.mSampleRate
        let channels = basic.pointee.mChannelsPerFrame
        let frameTime = CMTimeConvertScale(actual, timescale: Int32(rate), method: .default)
        // Reject endpoints not exactly representable at the actual output sample rate.
        guard frameTime == actual, frameTime.value > 0 else { throw Failure.presentationMismatch }
        let decoded = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { decoded.close() }
        guard decoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              decoded.fileFormat.sampleRate == rate, decoded.processingFormat.sampleRate == rate,
              decoded.fileFormat.channelCount == channels, decoded.processingFormat.channelCount == channels,
              decoded.length == frameTime.value else { throw Failure.decodedLengthMismatch }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 8192) else { throw Failure.exportUnavailable }
        let frames = try countDecodedFrames(expected: frameTime.value) { requested in
            try decoded.read(into: buffer, frameCount: requested)
            return buffer.frameLength
        }
        guard decoded.framePosition == frames, decoded.length == frames else { throw Failure.decodedLengthMismatch }
        return Chunk(window: window, file: file, presentationDuration: Time(actual),
                     decodedFrames: frames, sampleRate: rate, channels: channels)
    }

    /// Separate only to exercise decoder error/short-read/cancellation paths deterministically.
    static func countDecodedFrames(expected: Int64, read: (AVAudioFrameCount) throws -> AVAudioFrameCount) throws -> Int64 {
        guard expected > 0 else { throw Failure.decodedLengthMismatch }
        var frames: Int64 = 0
        while frames < expected {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(8192, expected - frames))
            let count = try read(requested)
            guard count > 0, count <= requested else { throw Failure.decodedLengthMismatch }
            frames += Int64(count)
        }
        try Task.checkCancellation()
        return frames
    }

    static func identity(_ url: URL) throws -> Identity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), bytes = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            bytes += data.count
            hash.update(data: data)
        }
        return Identity(name: url.lastPathComponent, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func validateByteLength(_ bytes: Int) throws {
        guard bytes > 0, bytes <= maximumBytes else { throw Failure.oversized }
    }
}
