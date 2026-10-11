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
    // At most 64 eligible entries per side of a five-second overlap.
    // Above this limit, preserve the boundary instead of truncating its search.
    private static let maximumOverlapEntries = 64
    private static let edgeAllowanceMs: Int64 = 250
    private static let anchoredToleranceMs: Int64 = 750

    /// The 250 ms default is provisional, not evidence of acoustic quality.
    /// Match unique mutual nearest neighbors by total outer endpoint distance.
    /// A sentence may match contiguous words. Keep the original left entries.
    /// Three consecutive normal one-to-one matches can anchor drift recovery.
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
                          compatible(a, b, toleranceMs: toleranceMs) else { continue }
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
            var accepted: [(Candidate, Candidate)] = []
            for (match, pair) in matches.enumerated() {
                // Every constituent must select this same match uniquely.
                // Never retry a tied or competing range after removing another.
                guard pair.0.indices.allSatisfy({ leftBest[$0]?.other == match && leftBest[$0]?.tied == false }),
                      pair.1.indices.allSatisfy({ rightBest[$0]?.other == match && rightBest[$0]?.tied == false })
                else { continue }
                accepted.append(pair)
                for index in pair.1.indices {
                    removed.insert(Position(window: right.index, segment: index))
                }
            }
            // Non-default tolerance values retain their original endpoint limit.
            if toleranceMs == 250 {
                for index in anchoredExtensions(lhs, rhs, accepted: accepted,
                                                leftSegments: left.segments, rightSegments: right.segments,
                                                normalLeft: Set(leftBest.keys), normalRight: Set(rightBest.keys)) {
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

    private static func compatible(_ a: Candidate, _ b: Candidate, toleranceMs: Int64) -> Bool {
        a.text == b.text && max(a.start, b.start) < min(a.end, b.end)
            && abs(a.start - b.start) <= toleranceMs && abs(a.end - b.end) <= toleranceMs
            && (a.speaker == nil || b.speaker == nil || a.speaker == b.speaker)
    }

    private static func follows(_ earlier: Candidate, _ later: Candidate) -> Bool {
        later.start >= earlier.start && later.end >= earlier.end && later.start >= earlier.end - 1
    }

    private static func anchoredExtensions(
        _ lhs: [Candidate], _ rhs: [Candidate], accepted: [(Candidate, Candidate)],
        leftSegments: [LocalTranscriptSegment], rightSegments: [LocalTranscriptSegment],
        normalLeft: Set<Int>, normalRight: Set<Int>
    ) -> Set<Int> {
        let leftSingles = Dictionary(uniqueKeysWithValues: lhs.filter { $0.indices.count == 1 }
            .map { ($0.indices.lowerBound, $0) })
        let rightSingles = Dictionary(uniqueKeysWithValues: rhs.filter { $0.indices.count == 1 }
            .map { ($0.indices.lowerBound, $0) })
        let usedLeft = Set(accepted.flatMap { Array($0.0.indices) })
        let usedRight = Set(accepted.flatMap { Array($0.1.indices) })
        let seeds = accepted.filter { $0.0.indices.count == 1 && $0.1.indices.count == 1 && !$0.0.text.isEmpty }
            .sorted { $0.0.indices.lowerBound < $1.0.indices.lowerBound }
        var runs: [[(Candidate, Candidate)]] = []
        for pair in seeds {
            if let previous = runs.last?.last,
               pair.0.indices.lowerBound == previous.0.indices.lowerBound + 1,
               pair.1.indices.lowerBound == previous.1.indices.lowerBound + 1,
               follows(previous.0, pair.0), follows(previous.1, pair.1) {
                runs[runs.count - 1].append(pair)
            } else {
                runs.append([pair])
            }
        }
        var result = Set<Int>()
        for run in runs where run.count >= 3 {
            for direction in [-1, 1] {
                var current = direction == -1 ? run[0] : run[run.count - 1]
                while true {
                    let i = current.0.indices.lowerBound + direction
                    let j = current.1.indices.lowerBound + direction
                    // Rejected normal candidates (including ties) remain rejected.
                    guard !normalLeft.contains(i), !normalRight.contains(j),
                          let a = leftSingles[i], let b = rightSingles[j], !a.text.isEmpty,
                          compatible(a, b, toleranceMs: anchoredToleranceMs) else { break }
                    let ordered = direction == -1
                        ? follows(a, current.0) && follows(b, current.1)
                        : follows(current.0, a) && follows(current.1, b)
                    guard ordered else { break }
                    // Freeze the normal-match masks. Do not resolve ambiguity by
                    // deleting another extension. Include competitors outside the edge band.
                    guard uniqueCounterpart(a, in: rightSegments, excluding: usedRight) == j,
                          uniqueCounterpart(b, in: leftSegments, excluding: usedLeft) == i else { break }
                    result.insert(j)
                    current = (a, b)
                }
            }
        }
        return result
    }

    private static func uniqueCounterpart(
        _ candidate: Candidate, in segments: [LocalTranscriptSegment], excluding used: Set<Int>
    ) -> Int? {
        var found: Int?
        for (index, segment) in segments.enumerated() where !used.contains(index) {
            guard let start = segment.startMs, let end = segment.endMs,
                  abs(start - candidate.start) <= anchoredToleranceMs,
                  abs(end - candidate.end) <= anchoredToleranceMs else { continue }
            let other = Candidate(indices: index...index, start: start, end: end,
                                  text: normalized(segment.text), speaker: segment.speaker)
            if compatible(candidate, other, toleranceMs: anchoredToleranceMs) {
                // Any second counterpart is ambiguous, even if farther away.
                guard found == nil else { return nil }
                found = index
            }
        }
        return found
    }

    private static func nearOverlap(_ segment: LocalTranscriptSegment, start: Int64, end: Int64) -> Bool {
        guard let s = segment.startMs, let e = segment.endMs else { return false }
        // Match full observed segments, never cropped text or words wholly outside.
        return s < end && e > start && s >= start - edgeAllowanceMs && e <= end + edgeAllowanceMs
    }

    private static func candidates(_ window: LocalTranscriptWindow, start: Int64, end: Int64) -> [Candidate] {
        let eligibleCount = window.segments.lazy.filter {
            nearOverlap($0, start: start, end: end)
        }.prefix(maximumOverlapEntries + 1).count
        guard eligibleCount <= maximumOverlapEntries else { return [] }
        var result: [Candidate] = []
        for index in window.segments.indices {
            let first = window.segments[index]
            guard nearOverlap(first, start: start, end: end),
                  let s = first.startMs, let e = first.endMs else { continue }
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
                guard nearOverlap(segment, start: start, end: end),
                      let nextStart = segment.startMs, let nextEnd = segment.endMs,
                      nextStart >= previousStart, nextEnd >= previousEnd,
                      nextStart >= previousEnd - 1 else { break }
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
