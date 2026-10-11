import Foundation

/// Segment timestamps are already absolute. Index zero starts at zero.
struct LocalTranscriptWindow {
    let index: Int
    let startMs: Int64
    let endMs: Int64
    let segments: [LocalTranscriptSegment]
}

enum LocalSegmentMergeError: Error, Equatable {
    case invalidTolerance
    case invalidWindow
    case duplicateWindowIndex
    case segmentOutsideWindow
}

enum LocalSegmentMerger {
    // At most 64 contained entries per side of a five-second overlap.
    // Above this limit, preserve the boundary instead of truncating its search.
    private static let maximumOverlapEntries = 64

    /// The 250 ms default is provisional, not evidence of acoustic quality.
    /// Match unique mutual nearest neighbors by total outer endpoint distance.
    /// A sentence may match contiguous words. Keep the original left entries.
    /// Do not reconsider ties after other matches: ambiguity preserves both inputs.
    static func merge(
        _ windows: [LocalTranscriptWindow], toleranceMs: Int64 = 250
    ) throws -> [LocalTranscriptSegment] {
        guard toleranceMs >= 0 else { throw LocalSegmentMergeError.invalidTolerance }
        var indices = Set<Int>()
        for window in windows {
            // Bound the index before multiplication to avoid overflow.
            guard (0...24).contains(window.index),
                  window.startMs == Int64(window.index) * 295_000,
                  window.endMs > window.startMs,
                  window.endMs <= min(window.startMs + 300_000, 7_200_000)
            else { throw LocalSegmentMergeError.invalidWindow }
            guard indices.insert(window.index).inserted else {
                throw LocalSegmentMergeError.duplicateWindowIndex
            }
            for segment in window.segments {
                try segment.validate()
                if let start = segment.startMs, let end = segment.endMs {
                    guard start >= window.startMs, end <= window.endMs else {
                        throw LocalSegmentMergeError.segmentOutsideWindow
                    }
                }
            }
        }

        let ordered = windows.sorted { $0.index < $1.index }
        var removed = Set<Position>()
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            // Missing windows never create a new matching boundary.
            guard right.index == left.index + 1 else { continue }
            let overlapStart = right.startMs
            let overlapEnd = min(left.endMs, right.endMs)
            guard overlapEnd > overlapStart, overlapEnd - overlapStart <= 5_000 else { continue }
            let lhs = candidates(left, start: overlapStart, end: overlapEnd)
            let rhs = candidates(right, start: overlapStart, end: overlapEnd)
            let rightByText = Dictionary(grouping: rhs, by: \.text)
            var leftBest: [Int: Nearest] = [:]
            var rightBest: [Int: Nearest] = [:]
            var matches: [(Candidate, Candidate)] = []
            for a in lhs {
                for b in rightByText[a.text] ?? [] {
                    // Only one-to-one and mixed-granularity matches are needed.
                    guard a.indices.count == 1 || b.indices.count == 1,
                          max(a.start, b.start) < min(a.end, b.end),
                          abs(a.start - b.start) <= toleranceMs,
                          abs(a.end - b.end) <= toleranceMs else { continue }
                    if let x = a.speaker, let y = b.speaker, x != y { continue }
                    let distance = abs(a.start - b.start) + abs(a.end - b.end)
                    let match = matches.count
                    matches.append((a, b))
                    for index in a.indices {
                        record(&leftBest, index: index, other: match, distance: distance)
                    }
                    for index in b.indices {
                        record(&rightBest, index: index, other: match, distance: distance)
                    }
                }
            }
            for (match, pair) in matches.enumerated() {
                // Every constituent must select this same match uniquely.
                // Never retry a tied or competing range after removing another.
                guard pair.0.indices.allSatisfy({ leftBest[$0]?.other == match && leftBest[$0]?.tied == false }),
                      pair.1.indices.allSatisfy({ rightBest[$0]?.other == match && rightBest[$0]?.tied == false })
                else { continue }
                for index in pair.1.indices {
                    removed.insert(Position(window: right.index, segment: index))
                }
            }
        }
        // Timed entries precede untimed entries. Preserve chunk/input order on ties.
        return ordered.flatMap { window in
            window.segments.enumerated().compactMap { index, segment -> Entry? in
                let position = Position(window: window.index, segment: index)
                return removed.contains(position) ? nil : Entry(position: position, segment: segment)
            }
        }.sorted {
            let a = $0.segment.startMs ?? Int64.max
            let b = $1.segment.startMs ?? Int64.max
            if a != b { return a < b }
            if $0.position.window != $1.position.window { return $0.position.window < $1.position.window }
            return $0.position.segment < $1.position.segment
        }.map(\.segment)
    }

    private struct Position: Hashable { let window: Int; let segment: Int }
    private struct Entry { let position: Position; let segment: LocalTranscriptSegment }
    private struct Candidate {
        let indices: ClosedRange<Int>
        let start: Int64
        let end: Int64
        let text: String
        let speaker: String?
    }
    private struct Nearest { let other: Int; let distance: Int64; var tied: Bool }

    private static func candidates(_ window: LocalTranscriptWindow, start: Int64, end: Int64) -> [Candidate] {
        let containedCount = window.segments.lazy.filter {
            guard let s = $0.startMs, let e = $0.endMs else { return false }
            return s >= start && e <= end
        }.prefix(maximumOverlapEntries + 1).count
        guard containedCount <= maximumOverlapEntries else { return [] }
        var result: [Candidate] = []
        for index in window.segments.indices {
            let first = window.segments[index]
            guard let s = first.startMs, let e = first.endMs, s >= start, e <= end else { continue }
            result.append(Candidate(indices: index...index, start: s, end: e,
                                    text: normalized(first.text), speaker: first.speaker))
            guard !normalized(first.text).isEmpty else { continue }
            var text = first.text
            var speaker = first.speaker
            var previousStart = s
            var previousEnd = e
            for last in (index + 1)..<window.segments.count {
                let segment = window.segments[last]
                // Floor(start)/ceil(end) can overlap adjacent words by one ms.
                // Require monotonic endpoints; preserve larger overlaps and reversals.
                guard let nextStart = segment.startMs, let nextEnd = segment.endMs,
                      nextStart >= previousStart, nextEnd >= previousEnd,
                      nextStart >= previousEnd - 1, nextEnd <= end else { break }
                if let known = segment.speaker {
                    if let speaker, speaker != known { break }
                    speaker = known
                }
                // Empty entries must not create alternate ranges for the same text.
                guard !normalized(segment.text).isEmpty else { break }
                text += segment.text
                result.append(Candidate(indices: index...last, start: s, end: nextEnd,
                                        text: normalized(text), speaker: speaker))
                previousStart = nextStart
                previousEnd = nextEnd
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func record(_ map: inout [Int: Nearest], index: Int, other: Int, distance: Int64) {
        if let previous = map[index] {
            if distance < previous.distance {
                map[index] = Nearest(other: other, distance: distance, tied: false)
            } else if distance == previous.distance {
                map[index]?.tied = true
            }
        } else {
            map[index] = Nearest(other: other, distance: distance, tied: false)
        }
    }
}
