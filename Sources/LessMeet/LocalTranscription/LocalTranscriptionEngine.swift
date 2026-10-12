import Foundation

struct LocalTranscriptionProgress: Sendable, Equatable {
    let fraction: Double
    let message: String
}

protocol LocalTranscriptionProcessing: Sendable {
    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript
}

actor LocalTranscriptionEngine: LocalTranscriptionProcessing {
    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript {
        try Task.checkCancellation()
        let reader = try LocalPCMReader(url: audioURL)
        progress(.init(fraction: 0, message: "Loading Whisper large-v3…"))
        // Keep model lifetimes within one job. No recording-wide PCM array is retained.
        let windows = try await transcribeWindows(reader: reader, models: models, progress: progress)
        try Task.checkCancellation()
        progress(.init(fraction: 0.75, message: "Identifying speakers across the recording…"))
        let diarizer = try LocalDiarizationAdapter(modelDirectory: models.diarizerDirectory)
        let intervals = try await diarizer.diarize(audioURL: audioURL) { fraction in
            progress(.init(fraction: 0.75 + 0.2 * fraction, message: "Identifying speakers across the recording…"))
        }
        try Task.checkCancellation()
        progress(.init(fraction: 0.98, message: "Assembling local transcript…"))
        let segments = try LocalSegmentMerger.merge(windows)
        let assigned = SpeakerAttribution.assign(segments, intervals: intervals)
        let transcript = LocalTranscript(segments: Self.group(assigned))
        try transcript.validate()
        try Task.checkCancellation()
        return transcript
    }

    private func transcribeWindows(reader: LocalPCMReader, models: InstalledLocalModels,
                                   progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws
        -> [LocalTranscriptWindow] {
        let whisper = try await LocalWhisperAdapter(modelDirectory: models.whisperDirectory,
                                                    tokenizerDirectory: models.tokenizerDirectory)
        let audio = LocalAudioWindows(reader: reader)
        var windows: [LocalTranscriptWindow] = []
        while let window = try audio.next() {
            try Task.checkCancellation()
            progress(.init(fraction: 0.05 + 0.7 * Double(window.startMs) / (reader.duration * 1000),
                           message: "Transcribing window \(window.index + 1)…"))
            let relative = try await whisper.transcribe(samples: window.samples)
            let absolute = try Self.absolute(relative, window: window)
            windows.append(LocalTranscriptWindow(index: window.index, startMs: window.startMs,
                                                  endMs: window.endMs, segments: absolute))
        }
        return windows
    }

    static func absolute(_ segments: [LocalTranscriptSegment], window: LocalAudioWindow) throws
        -> [LocalTranscriptSegment] {
        try segments.map { segment in
            try segment.validate()
            guard let start = segment.startMs, let end = segment.endMs,
                  end <= window.endMs - window.startMs else {
                throw LocalWhisperError.invalidTiming
            }
            return LocalTranscriptSegment(startMs: start + window.startMs, endMs: end + window.startMs,
                                          speaker: nil, text: segment.text)
        }
    }

    /// Group after overlap matching and word-level speaker assignment. Preserve token spacing.
    static func group(_ segments: [LocalTranscriptSegment]) -> [LocalTranscriptSegment] {
        var grouped: [LocalTranscriptSegment] = []
        for segment in segments {
            if var last = grouped.last, let first = last.startMs, let end = last.endMs,
               let start = segment.startMs, let nextEnd = segment.endMs,
               last.speaker == segment.speaker, start >= first, start - end <= 750,
               max(end, nextEnd) - first <= 15_000, last.text.count + segment.text.count <= 800,
               !last.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffixSentenceEnd {
                last.endMs = max(end, nextEnd)
                last.text += segment.text
                grouped[grouped.count - 1] = last
            } else { grouped.append(segment) }
        }
        return grouped.map { segment in
            var result = segment
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }.filter { !$0.text.isEmpty }
    }
}

private extension String {
    var hasSuffixSentenceEnd: Bool { last.map { ".?!。！？".contains($0) } ?? false }
}
