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
        guard let run = suite.testRun, run.executionCount == 11, run.hasSucceeded else { exit(1) }
    }
}
#endif
