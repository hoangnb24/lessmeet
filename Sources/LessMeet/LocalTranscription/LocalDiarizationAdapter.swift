import Foundation
import SpeechVAD

/// The recording-scoped boundary. Intermediate results must never supply labels.
protocol LocalDiarizationSession: AnyObject {
    func push(audio: [Float]) throws -> DiarizationResult
    func finish() throws -> DiarizationResult
}

extension Nemotron3StreamingSession: LocalDiarizationSession {}

actor LocalDiarizationAdapter {
    enum Failure: LocalizedError {
        case invalidModelDirectory
        case invalidResult

        var errorDescription: String? {
            switch self {
            case .invalidModelDirectory: return "A local Nemotron model directory is required."
            case .invalidResult: return "Nemotron returned invalid speaker intervals."
            }
        }
    }

    private let makeSession: (Int, Int) throws -> any LocalDiarizationSession

    /// Validate the path here. Load Core ML inside the actor, not on the caller's thread.
    /// The caller must keep its verified model directory immutable during inference.
    init(modelDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard modelDirectory.isFileURL,
              FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Failure.invalidModelDirectory }
        makeSession = { coreFrames, rightFrames in
            let model = try Nemotron3Diarizer.fromCoreMLDirectory(modelDirectory)
            return try model.makeStreamingSession(
                coreEncoderFrames: coreFrames, rightContextEncoderFrames: rightFrames)
        }
    }

    init(makeSession: @escaping (Int, Int) throws -> any LocalDiarizationSession) {
        self.makeSession = makeSession
    }

    /// One uninterrupted stream per recording. Progress is submitted audio, not model confidence.
    /// There are no suspension points: synchronous inference stays on this actor's executor.
    func diarize(audioURL: URL, progress: @Sendable (Double) -> Void) async throws -> [LocalSpeakerInterval] {
        try Task.checkCancellation()
        let reader = try LocalPCMReader(url: audioURL)
        let session = try makeSession(340, 40)
        try Task.checkCancellation()
        progress(0)
        var pushedSamples = 0
        while true {
            try Task.checkCancellation()
            let block = try reader.read(maxSamples: 16_384)
            if block.isEmpty { break }
            // push() compacts IDs on each snapshot. Only finish() defines global labels.
            _ = try session.push(audio: block)
            try Task.checkCancellation()
            pushedSamples += block.count
            progress(min(1, Double(pushedSamples) / Double(LocalPCMReader.sampleRate) / reader.duration))
        }
        try Task.checkCancellation()
        let result = try session.finish()
        try Task.checkCancellation()
        let intervals = try Self.intervals(from: result, duration: reader.duration)
        try Task.checkCancellation()
        progress(1)
        try Task.checkCancellation()
        return intervals
    }

    private static func intervals(from result: DiarizationResult, duration: Double) throws -> [LocalSpeakerInterval] {
        guard (0...8).contains(result.numSpeakers),
              Set(result.segments.map(\.speakerId)).count == result.numSpeakers else {
            throw Failure.invalidResult
        }
        let durationMs = Int64((duration * 1_000).rounded(.down))
        return try result.segments.compactMap { segment in
            let start = Double(segment.startTime)
            let end = Double(segment.endTime)
            guard start.isFinite, end.isFinite, start >= 0, start < end, end <= 7_200,
                  (0..<8).contains(segment.speakerId) else { throw Failure.invalidResult }
            let startMs = min(durationMs, Int64((min(start, duration) * 1_000).rounded()))
            let endMs = min(durationMs, Int64((min(end, duration) * 1_000).rounded()))
            guard startMs < endMs else { return nil }
            return LocalSpeakerInterval(startMs: startMs, endMs: endMs,
                                        speaker: "Speaker\(segment.speakerId + 1)")
        }
    }
}
