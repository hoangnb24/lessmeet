import XCTest
#if !LOCAL_MERGE_STANDALONE
@testable import LessMeet
#endif

final class LocalSegmentMergerTests: XCTestCase {
    private func segment(_ start: Int64? = 296_000, _ end: Int64? = 297_000,
                         _ text: String = "Hello", _ speaker: String? = nil) -> LocalTranscriptSegment {
        LocalTranscriptSegment(startMs: start, endMs: end, speaker: speaker, text: text)
    }
    private func window(_ index: Int, _ segments: [LocalTranscriptSegment]) -> LocalTranscriptWindow {
        let start = Int64(index) * 295_000
        return LocalTranscriptWindow(index: index, startMs: start,
                                     endMs: min(start + 300_000, 7_200_000), segments: segments)
    }

    func testDriftBoundaryAndOriginalPreservation() throws {
        for drift: Int64 in [0, 1, 120, 250, 251] {
            let original = segment()
            let shifted = segment(296_000 + drift, 297_000 + drift)
            let inputs = [window(0, [original]), window(1, [shifted])]
            let result = try LocalSegmentMerger.merge(inputs)
            XCTAssertEqual(result, drift <= 250 ? [original] : [original, shifted])
            XCTAssertEqual(inputs[0].segments, [original])
            XCTAssertEqual(inputs[1].segments, [shifted])
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment()]), window(1, [segment(296_001, 297_001)])
        ], toleranceMs: 0).count, 2)
    }

    func testFallbackSentenceAndAlignedWordsBothDirections() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence])]), words)
    }

    func testRoundedWordBoundaryBothDirections() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        for overlap: Int64 in [0, 1, 2, 100] {
            let words = [segment(296_000, 297_000 + overlap, " Hello"),
                         segment(297_000, 298_000, " world.")]
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                if overlap <= 1 { XCTAssertEqual(result, left) }
                else { XCTAssertEqual(result.count, 3) }
            }
        }
        // Rounding permission must not allow backward starts or ends.
        for words in [
            [segment(296_001, 297_001, " Hello"), segment(296_000, 298_000, " world.")],
            [segment(296_000, 298_000, " Hello"), segment(297_999, 297_999 + 1, " world.")],
            [segment(296_000, 298_001, " Hello"), segment(297_999, 298_000, " world.")]
        ] {
            // Equal ends are monotonic; only the middle fixture may match.
            let monotonic = words[0].endMs == words[1].endMs
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                XCTAssertEqual(result.count, monotonic ? left.count : 3)
            }
        }
    }

    func testOverlapEntryLimitPreservesTextBothDirections() throws {
        for count in [64, 65, 256] {
            let words = (0..<count).map { index in
                segment(296_000 + Int64(index) * 10, 296_010 + Int64(index) * 10, " w\(index)")
            }
            let sentence = segment(296_000, 296_000 + Int64(count) * 10, words.map(\.text).joined())
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let inputs = [window(0, left), window(1, right)]
                let expected = count <= 64 ? left : try LocalSegmentMerger.merge([
                    window(0, left + right)
                ])
                XCTAssertEqual(try LocalSegmentMerger.merge(inputs), expected)
                XCTAssertEqual(try LocalSegmentMerger.merge(inputs.reversed()), expected)
            }
        }
        // Do not inspect only the first 64 entries and hide a later tied candidate.
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        let crowded = words + Array(repeating: segment(298_000, 299_000, " other"), count: 62) + [sentence]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, crowded)]).count, 66)
    }

    func testSequenceDriftAndPositiveIntersection() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        for drift: Int64 in [0, 250, 251, -250, -251] {
            let words = [segment(296_000 + drift, 297_000 + drift, " Hello"),
                         segment(297_000 + drift, 298_000 + drift, " world.")]
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                XCTAssertEqual(result.count, abs(drift) <= 250 ? left.count : 3)
                if abs(drift) <= 250 { XCTAssertEqual(result, left) }
            }
        }
        let words = [segment(298_000, 298_100, " Hello"), segment(298_100, 298_200, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, words)
        ], toleranceMs: 3_000).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [segment(296_001, 297_000, " Hello"),
                                           segment(297_000, 298_000, " world.")])
        ], toleranceMs: 0).count, 3)
        for endpoints: (Int64, Int64) in [(296_250, 298_251), (296_251, 298_250)] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [sentence]), window(1, [segment(endpoints.0, 297_000, " Hello"),
                                               segment(297_000, endpoints.1, " world.")])
            ]).count, 3)
        }
    }

    func testSequenceNormalizationPunctuationAndPartialText() throws {
        let sentence = segment(296_000, 298_000, " Café, world.")
        let words = [segment(296_000, 296_500, " Cafe\u{301}"),
                     segment(296_500, 297_000, ","),
                     segment(297_000, 298_000, "\n\tworld.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
        let tail = segment(298_000, 299_000, " More.")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words + [tail])]),
                       [sentence, tail])
        let partial = segment(296_000, 297_000, " Café,")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [partial]), window(1, [sentence])]),
                       [partial, sentence])
        for text in [" Café world.", " café, world.", " Café,world."] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [segment(296_000, 298_000, text)]), window(1, words)
            ]).count, 4)
        }
    }

    func testSequenceSpeakerConflictsAndUnknowns() throws {
        for labels: [String?] in [[nil, nil], ["A", nil], [nil, "A"], ["A", "A"], ["A", "B"], ["B", "B"]] {
            let sentence = segment(296_000, 298_000, " Hello world.", "A")
            let words = [segment(296_000, 297_000, " Hello", labels[0]),
                         segment(297_000, 298_000, " world.", labels[1])]
            let conflict = labels.contains("B")
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]).count,
                           conflict ? 3 : 1)
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence])]).count,
                           conflict ? 3 : 2)
        }
        let unknown = segment(296_000, 298_000, " Hello world.")
        let conflicting = [segment(296_000, 297_000, " Hello", "A"),
                           segment(297_000, 298_000, " world.", "B")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [unknown]), window(1, conflicting)]).count, 3)
    }

    func testSequenceTiesCompetingRangesAndRepeatedPhrases() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence, sentence]), window(1, words)]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence, sentence])]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words + words)]).count, 5)
        // Two equal-distance matches share the middle word. Neither range is safe to remove.
        let repeated = segment(296_000, 296_300, " a a")
        let repeats = [segment(296_000, 296_100, " a"), segment(296_100, 296_200, " a"),
                       segment(296_200, 296_300, " a")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [repeated]), window(1, repeats)]).count, 4)
        // A one-to-one candidate competes with a sequence; ties remain unresolved.
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [sentence] + words)
        ]).count, 4)
        let second = segment(298_000, 300_000, " Hello world.")
        let secondWords = [segment(298_000, 299_000, " Hello"), segment(299_000, 300_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence, second]), window(1, words + secondWords)
        ]), [sentence, second])
    }

    func testSequenceContainmentContiguityMissingWindowsAndDeterminism() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        for middle in [segment(nil, nil, " interruption"), segment(297_000, 297_001, ""),
                       segment(297_000, 297_001, " unmatched")] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [sentence]), window(1, [words[0], middle, words[1]])
            ]).count, 4)
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, words.reversed())
        ]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [segment(296_000, 297_100, " Hello"), words[1]])
        ]).count, 3)
        let crossing = segment(294_900, 298_000, " Hello world.")
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [crossing]), window(1, [segment(295_000, 297_000, " Hello"), words[1]])
        ]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(298_000, 300_000, " Hello world.")]),
            window(1, [segment(298_000, 299_000, " Hello"), segment(299_000, 300_100, " world.")])
        ]).count, 3)
        let later = words.map { segment($0.startMs! + 295_000, $0.endMs! + 295_000, $0.text) }
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(2, later)]).count, 3)
        for _ in 0..<20 {
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
            XCTAssertEqual(try LocalSegmentMerger.merge([window(1, words), window(0, [sentence])]), [sentence])
        }
    }

    func testUnicodeWhitespaceAndCase() throws {
        let original = segment(296_000, 297_000, "  Caf\u{e9}\n world  ")
        let copy = segment(296_120, 297_120, "Cafe\u{301}\u{a0}world")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [original]), window(1, [copy])]), [original])
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment()]), window(1, [segment(296_000, 297_000, "hello")])
        ]).count, 2)
    }

    func testRepetitionNonintersectionAndOverlapContainment() throws {
        let repeats = [segment(296_000, 296_100), segment(296_100, 296_200)]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, repeats)]), repeats)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [repeats[0]]), window(1, [repeats[1]])
        ]).count, 2) // Touching endpoints are not intersection.
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_900, 296_000)]), window(1, [segment(295_000, 296_000)])
        ]).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(299_000, 300_000)]), window(1, [segment(299_120, 300_120)])
        ]).count, 2)
    }

    func testUniqueNearestOneToOneAndTies() throws {
        let a = segment()
        let b = segment(296_100, 297_100)
        let near = segment(296_010, 297_010)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, b]), window(1, [near])]), [a, b])
        let tie = segment(296_050, 297_050)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, b]), window(1, [tie])]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [tie]), window(1, [a, b])]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, a]), window(1, [a, a])]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [a, b]), window(1, [near, segment(296_110, 297_110)])
        ]), [a, b])
    }

    func testSpeakerConflictAndUnknown() throws {
        let a = segment(296_000, 297_000, "Hello", "speaker_1")
        let b = segment(296_120, 297_120, "Hello", "speaker_2")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a]), window(1, [b])]).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a]), window(1, [segment()])]), [a])
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [segment()]), window(1, [a])]), [segment()])
    }

    func testMissingWindowsUntimedStableOrderAndDeterminism() throws {
        let untimed = segment(nil, nil)
        let early = segment(100, 200, "early")
        let late = segment(590_100, 590_200, "late")
        let inputs = [window(2, [untimed, late]), window(0, [untimed, early, untimed])]
        let expected = [early, late, untimed, untimed, untimed]
        for _ in 0..<20 {
            XCTAssertEqual(try LocalSegmentMerger.merge(inputs), expected)
            XCTAssertEqual(try LocalSegmentMerger.merge(inputs.reversed()), expected)
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([]), [])
        let tied = [segment(100, 300, "first"), segment(100, 200, "second")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, tied)]), tied)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(24, [segment(7_199_000, 7_200_000)])]).count, 1)
    }

    func testInvalidGeometryAndTimestamps() throws {
        XCTAssertThrowsError(try LocalSegmentMerger.merge([], toleranceMs: -1))
        XCTAssertThrowsError(try LocalSegmentMerger.merge([window(0, []), window(0, [])]))
        let invalidWindows: [LocalTranscriptWindow] = [
            .init(index: -1, startMs: 0, endMs: 1, segments: []),
            .init(index: Int.max, startMs: 0, endMs: 1, segments: []),
            .init(index: 25, startMs: 7_375_000, endMs: 7_375_001, segments: []),
            .init(index: 1, startMs: 0, endMs: 300_000, segments: []),
            .init(index: 0, startMs: 0, endMs: 0, segments: []),
            .init(index: 0, startMs: 0, endMs: 300_001, segments: []),
            .init(index: 24, startMs: 7_080_000, endMs: 7_200_001, segments: [])
        ]
        for input in invalidWindows { XCTAssertThrowsError(try LocalSegmentMerger.merge([input])) }
        for s in [segment(nil, 1), segment(1, nil), segment(-1, 1), segment(1, 1),
                  segment(2, 1), segment(0, Int64.max), segment(0, 300_001)] {
            XCTAssertThrowsError(try LocalSegmentMerger.merge([window(0, [s])]))
        }
        XCTAssertThrowsError(try LocalSegmentMerger.merge([window(1, [segment(294_999, 296_000)])]))
        XCTAssertEqual(try LocalSegmentMerger.merge([
            .init(index: 0, startMs: 0, endMs: 100, segments: [segment(0, 100)])
        ]).count, 1)
    }
}

#if LOCAL_MERGE_STANDALONE
@main
enum LocalMergeTestRunner {
    static func main() {
        let suite = XCTestSuite(name: "Local overlap and attribution")
        suite.addTest(XCTestSuite(forTestCaseClass: LocalSegmentMergerTests.self))
        suite.addTest(XCTestSuite(forTestCaseClass: SpeakerAttributionTests.self))
        suite.run()
        guard let run = suite.testRun, run.executionCount == 19, run.hasSucceeded else { exit(1) }
    }
}
#endif
