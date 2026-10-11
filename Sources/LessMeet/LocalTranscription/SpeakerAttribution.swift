import Foundation

struct LocalSpeakerInterval {
    let startMs: Int64
    let endMs: Int64
    let speaker: String
}

enum SpeakerAttribution {
    /// Require >= 80% union coverage by one global label, with no other label
    /// intersecting the segment. This is temporal coverage, not confidence.
    /// Invalid evidence makes the whole assignment unknown (fail closed).
    /// Existing segment labels are replaced, never used as independent evidence.
    static func assign(
        _ segments: [LocalTranscriptSegment], intervals: [LocalSpeakerInterval]
    ) -> [LocalTranscriptSegment] {
        let valid = intervals.allSatisfy {
            $0.startMs >= 0 && $0.startMs < $0.endMs && $0.endMs <= 7_200_000
                && !$0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return segments.map { segment in
            var result = segment
            result.speaker = nil
            guard valid, let start = segment.startMs, let end = segment.endMs,
                  start >= 0, start < end, end <= 7_200_000 else { return result }
            let hits = intervals.filter { $0.startMs < end && $0.endMs > start }
            guard let label = hits.first?.speaker,
                  hits.allSatisfy({ $0.speaker == label }) else { return result }
            let clipped: [(Int64, Int64)] = hits.map { hit in
                (max(start, hit.startMs), min(end, hit.endMs))
            }
            let ranges = clipped.sorted { a, b in
                if a.0 != b.0 { return a.0 < b.0 }
                return a.1 < b.1
            }
            var coverage: Int64 = 0
            var coveredEnd = start
            for (lower, upper) in ranges {
                coverage += max(0, upper - max(lower, coveredEnd))
                coveredEnd = max(coveredEnd, upper)
            }
            // Integer arithmetic gives an exact inclusive 80% threshold.
            if coverage * 5 >= (end - start) * 4 { result.speaker = label }
            return result
        }
    }
}
