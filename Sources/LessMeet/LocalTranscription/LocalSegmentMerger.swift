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
    /// The 250 ms default is provisional, not evidence of acoustic quality.
    /// Match only unique mutual nearest neighbors by total endpoint distance.
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
            var leftBest: [Int: Nearest] = [:]
            var rightBest: [Int: Nearest] = [:]
            for a in lhs {
                for b in rhs {
                    guard a.text == b.text,
                          max(a.start, b.start) < min(a.end, b.end),
                          abs(a.start - b.start) <= toleranceMs,
                          abs(a.end - b.end) <= toleranceMs else { continue }
                    if let x = a.speaker, let y = b.speaker, x != y { continue }
                    let distance = abs(a.start - b.start) + abs(a.end - b.end)
                    record(&leftBest, index: a.index, other: b.index, distance: distance)
                    record(&rightBest, index: b.index, other: a.index, distance: distance)
                }
            }
            for (index, best) in leftBest where !best.tied {
                guard let reverse = rightBest[best.other], !reverse.tied,
                      reverse.other == index else { continue }
                removed.insert(Position(window: right.index, segment: best.other))
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
        let index: Int
        let start: Int64
        let end: Int64
        let text: String
        let speaker: String?
    }
    private struct Nearest { let other: Int; let distance: Int64; var tied: Bool }

    private static func candidates(_ window: LocalTranscriptWindow, start: Int64, end: Int64) -> [Candidate] {
        window.segments.enumerated().compactMap { index, segment in
            guard let s = segment.startMs, let e = segment.endMs, s >= start, e <= end else { return nil }
            let text = segment.text.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return Candidate(index: index, start: s, end: e, text: text, speaker: segment.speaker)
        }
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
