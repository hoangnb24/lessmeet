import AVFoundation

/// Sequential, single-consumer decoding. Keep the source immutable while reading.
/// `read` returns at most 16,384 samples, even when the caller requests more.
/// Accumulate these blocks in the engine when building a 300-second window.
final class LocalPCMReader {
    static let sampleRate: Int = 16_000
    let duration: TimeInterval

    enum Failure: LocalizedError {
        case invalidSource(String)
        case invalidSampleCount
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .invalidSource(let reason): return "Cannot read local audio: \(reason)"
            case .invalidSampleCount: return "maxSamples must be greater than zero."
            case .decoding(let reason): return "Cannot decode local audio: \(reason)"
            }
        }
    }

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let expectedSamples: Int64
    private var convertedSamples: Int64 = 0
    private var pending: [Float] = []
    private var pendingIndex = 0
    private var ended = false
    private var failure: Error?

    init(url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.invalidSource("A local file URL is required.") }
        guard ["wav", "caf", "m4a"].contains(url.pathExtension.lowercased()) else {
            throw Failure.invalidSource("Only WAV, CAF and M4A files are supported.")
        }
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.invalidSource("AVFoundation could not open the file (\(error.localizedDescription)).")
        }
        let format = source.processingFormat
        let codec = source.fileFormat.streamDescription.pointee.mFormatID
        guard [kAudioFormatLinearPCM, kAudioFormatMPEG4AAC].contains(codec),
              (1...2).contains(format.channelCount),
              format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw Failure.invalidSource("PCM or AAC audio with one or two channels and a valid sample rate is required.")
        }
        // AVAudioFile exposes valid decoded frames, excluding AAC priming and padding.
        let seconds = Double(source.length) / format.sampleRate
        guard source.length > 0, seconds.isFinite, seconds > 0, seconds <= 7_200 else {
            throw Failure.invalidSource("Duration must be finite, greater than zero and at most 7,200 seconds.")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false),
              let resampler = AVAudioConverter(from: format, to: target),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
              let targetBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) else {
            throw Failure.invalidSource("AVFoundation cannot convert this audio format.")
        }
        file = source
        // Without this flag AVAudioConverter selects only the first stereo channel.
        resampler.downmix = true
        converter = resampler
        input = sourceBuffer
        output = targetBuffer
        duration = seconds
        // Fractional final output frames may round either way in AVAudioConverter.
        // Drain the converter instead of truncating its tail to this estimate.
        // A source shorter than one output frame can produce zero output frames.
        expectedSamples = Int64((seconds * Double(Self.sampleRate)).rounded())
    }

    /// Empty means EOF only. Cancellation or decoding failure makes this reader unusable.
    /// Create a new reader to retry. Invalid maxSamples does not advance the file.
    func read(maxSamples: Int) throws -> [Float] {
        guard maxSamples > 0 else { throw Failure.invalidSampleCount }
        if let failure { throw failure }
        do {
            try Task.checkCancellation()
            let limit = min(maxSamples, 16_384)
            var result: [Float] = []
            result.reserveCapacity(limit)
            while result.count < limit {
                try Task.checkCancellation()
                if pendingIndex < pending.count {
                    let count = min(limit - result.count, pending.count - pendingIndex)
                    result.append(contentsOf: pending[pendingIndex..<(pendingIndex + count)])
                    pendingIndex += count
                } else if ended {
                    break
                } else {
                    try convertNextBlock()
                }
            }
            return result
        } catch {
            failure = error
            throw error
        }
    }

    private func convertNextBlock() throws {
        pending.removeAll(keepingCapacity: true)
        pendingIndex = 0
        output.frameLength = 0
        var inputError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, state in
            do {
                try Task.checkCancellation()
                let remaining = file.length - file.framePosition
                guard remaining > 0 else {
                    state.pointee = .endOfStream
                    return nil
                }
                let count = min(requested, input.frameCapacity, AVAudioFrameCount(min(remaining, 4_096)))
                guard count > 0 else { throw Failure.decoding("The converter requested no input frames.") }
                try file.read(into: input, frameCount: count)
                guard input.frameLength > 0 else { throw Failure.decoding("The source ended before its declared frame count.") }
                guard let channels = input.floatChannelData else { throw Failure.decoding("Float PCM input is unavailable.") }
                for channel in 0..<Int(input.format.channelCount) {
                    for index in 0..<Int(input.frameLength) where !channels[channel][index].isFinite {
                        throw Failure.decoding("The source contains a nonfinite sample.")
                    }
                }
                state.pointee = .haveData
                return input
            } catch {
                inputError = error
                state.pointee = .endOfStream
                return nil
            }
        }
        if let inputError { throw inputError }
        guard status != .error, conversionError == nil else {
            throw Failure.decoding(conversionError?.localizedDescription ?? "AVAudioConverter failed.")
        }
        if output.frameLength > 0 {
            guard let samples = output.floatChannelData?[0] else { throw Failure.decoding("Float PCM output is unavailable.") }
            let block = UnsafeBufferPointer(start: samples, count: Int(output.frameLength))
            guard block.allSatisfy(\.isFinite) else { throw Failure.decoding("The converter produced a nonfinite sample.") }
            pending.append(contentsOf: block)
            convertedSamples += Int64(block.count)
        }
        if status == .endOfStream {
            ended = true
            guard abs(convertedSamples - expectedSamples) <= 1 else {
                throw Failure.decoding("Decoded \(convertedSamples) samples; expected \(expectedSamples) (one-sample rounding tolerance).")
            }
        } else if output.frameLength == 0 {
            // This file-backed input never reports temporary starvation.
            throw Failure.decoding("The converter made no progress before EOF.")
        }
    }
}
