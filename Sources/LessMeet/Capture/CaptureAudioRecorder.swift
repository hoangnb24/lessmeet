import AVFoundation

struct CaptureResult {
    let duration: TimeInterval
    let warning: String?
}

enum CaptureSource: String, CaseIterable, Codable {
    case microphone, system
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Confined to the stream's serial output queue. No audio is retained between writes.
final class CaptureAudioRecorder {
    private let directory: URL
    private var tracks: [CaptureSource: PCMTrack] = [:]
    private var closed = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["microphone.caf", "system.caf", "combined.m4a", "capture-timeline.json"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw CaptureError(message: "This recording folder already contains audio. Start a new recording to avoid overwriting it.")
            }
        }
    }

    func append(_ sample: CMSampleBuffer, source: CaptureSource) throws {
        guard !closed else { throw CaptureError(message: "The recording is already closed.") }
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = sample.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic),
              basic.pointee.mFormatID == kAudioFormatLinearPCM,
              format.commonFormat != .otherFormat,
              format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 32 else {
            throw CaptureError(message: "The \(source.rawValue) supplied an unsupported audio format. Check the selected audio device and start a new recording.")
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return }
        // A malformed buffer must not cause an unbounded allocation.
        guard count <= 262_144 else { throw CaptureError(message: "An audio buffer was unexpectedly large. Start a new recording.") }
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, pts >= .zero else {
            throw CaptureError(message: "The \(source.rawValue) supplied an invalid audio timestamp. Start a new recording.")
        }
        if tracks[source] == nil {
            tracks[source] = try PCMTrack(url: directory.appendingPathComponent("\(source.rawValue).caf"), format: format, start: pts)
        }
        try tracks[source]!.append(sample, format: format, count: count)
    }

    /// Close both originals before any export, including when one source failed.
    func close(warning: String? = nil) throws -> CapturedAudio {
        guard !closed else { throw CaptureError(message: "The recording is already closed.") }
        closed = true
        var sources: [CapturedAudio.Track] = []
        for source in CaptureSource.allCases {
            guard let track = tracks[source] else { continue }
            track.file.close()
            if track.frames > 0 {
                sources.append(.init(source: source, url: track.file.url, start: track.start,
                                     duration: CMTime(seconds: Double(track.frames) / track.format.sampleRate, preferredTimescale: 1_000_000_000)))
            }
        }
        tracks.removeAll()
        guard !sources.isEmpty else {
            throw CaptureError(message: [warning, "No audio was captured. Check Microphone and Screen & System Audio Recording permissions, then start a new recording."].compactMap { $0 }.joined(separator: " "))
        }
        let missing = CaptureSource.allCases.filter { source in !sources.contains { $0.source == source } }
        let warnings = [warning] + missing.map { "No \($0.rawValue) audio was received; this recording contains only the other source." }
        let result = CapturedAudio(directory: directory, tracks: sources, warning: warnings.compactMap { $0 }.joined(separator: " "))
        try result.saveTimeline()
        return result
    }
}

private final class PCMTrack {
    let file: AVAudioFile
    let format: AVAudioFormat
    let start: CMTime
    var frames: Int64 = 0

    init(url: URL, format: AVAudioFormat, start: CMTime) throws {
        self.format = format
        self.start = start
        // CAF avoids WAV's 4 GB limit. Preserve native rate/channels; export resamples.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func append(_ sample: CMSampleBuffer, format incomingFormat: AVAudioFormat, count: Int) throws {
        guard format.isEqual(incomingFormat) else {
            throw CaptureError(message: "An audio device changed format. The original recording is preserved; select a stable device and start a new recording.")
        }
        let position = CMTimeSubtract(sample.presentationTimeStamp, start).seconds * format.sampleRate
        guard position.isFinite, position >= 0, position < Double(Int64.max) else {
            throw CaptureError(message: "Audio timestamps moved backwards. Start a new recording.")
        }
        let gap = Int64(position.rounded()) - frames
        // Only tolerate single-frame timestamp rounding, never callback-arrival jitter.
        guard gap >= -1 else { throw CaptureError(message: "Audio timestamps overlap. The recording was interrupted; start a new recording.") }
        if gap > 1 { try writeSilence(frames: gap) }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw CaptureError(message: "Could not allocate the audio buffer.")
        }
        pcm.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw CaptureError(message: "Could not read captured audio (\(status)).") }
        try file.write(from: pcm)
        frames += Int64(count)
    }

    private func writeSilence(frames count: Int64) throws {
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw CaptureError(message: "Could not allocate the silence buffer.")
        }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var remaining = count
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, 4096))
            try file.write(from: silence)
            frames += Int64(silence.frameLength)
            remaining -= Int64(silence.frameLength)
        }
    }
}

struct CapturedAudio {
    struct Track {
        let source: CaptureSource
        let url: URL
        let start: CMTime
        let duration: CMTime
    }
    let directory: URL
    let tracks: [Track]
    let warning: String

    var origin: CMTime { tracks.map(\.start).min()! }
    var duration: CMTime { tracks.map { CMTimeAdd(CMTimeSubtract($0.start, origin), $0.duration) }.max()! }

    func saveTimeline() throws {
        struct Entry: Encodable { let source: CaptureSource; let file: String; let offset: Double; let duration: Double }
        let entries = tracks.map { Entry(source: $0.source, file: $0.url.lastPathComponent,
                                         offset: CMTimeSubtract($0.start, origin).seconds, duration: $0.duration.seconds) }
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("capture-timeline.json"), options: .atomic)
    }

    func exportCombined() async throws -> CaptureResult {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for source in tracks {
            let asset = AVURLAsset(url: source.url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CaptureError(message: "Could not open \(source.source.rawValue) audio. The original files are preserved.")
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration), of: audio,
                                      at: CMTimeSubtract(source.start, origin))
            let volume = AVMutableAudioMixInputParameters(track: track)
            volume.setVolume(tracks.count == 2 ? 0.5 : 1, at: .zero)
            parameters.append(volume)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError(message: "M4A export is unavailable. The separate audio files are preserved.")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        exporter.audioMix = mix
        let temporary = directory.appendingPathComponent("combined-\(UUID().uuidString).partial.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await exporter.export(to: temporary, as: .m4a)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent("combined.m4a"))
        } catch {
            throw CaptureError(message: "Could not create combined.m4a: \(error.localizedDescription) The separate audio files and capture-timeline.json are preserved.")
        }
        return CaptureResult(duration: duration.seconds, warning: warning.isEmpty ? nil : warning)
    }
}
