import XCTest
#if !LOCAL_MERGE_STANDALONE
@testable import LessMeet
#endif

final class SpeakerAttributionTests: XCTestCase {
    private func segment(_ start: Int64? = 0, _ end: Int64? = 1_000) -> LocalTranscriptSegment {
        .init(startMs: start, endMs: end, speaker: "old", text: "unchanged")
    }
    private func interval(_ start: Int64, _ end: Int64, _ label: String = "A") -> LocalSpeakerInterval {
        .init(startMs: start, endMs: end, speaker: label)
    }

    func testCoverageThresholdAndUnion() {
        for coverage: Int64 in [0, 799, 800, 801, 1_000] {
            let evidence = coverage == 0 ? [] : [interval(0, coverage)]
            XCTAssertEqual(SpeakerAttribution.assign([segment()], intervals: evidence)[0].speaker,
                           coverage >= 800 ? "A" : nil)
        }
        XCTAssertNil(SpeakerAttribution.assign([segment()], intervals: [interval(0, 500), interval(0, 500)])[0].speaker)
        XCTAssertEqual(SpeakerAttribution.assign([segment()], intervals: [interval(0, 400), interval(600, 1_000)])[0].speaker, "A")
        XCTAssertEqual(SpeakerAttribution.assign([segment()], intervals: [interval(0, 600), interval(400, 800)])[0].speaker, "A")
    }

    func testConflictIncludesBriefAndSequentialOtherSpeaker() {
        for conflicting in [interval(999, 1_001, "B"), interval(800, 1_000, "B"), interval(1, 2, "B")] {
            XCTAssertNil(SpeakerAttribution.assign([segment()], intervals: [interval(0, 800), conflicting])[0].speaker)
        }
        XCTAssertEqual(SpeakerAttribution.assign([segment()], intervals: [interval(0, 1_000), interval(1_000, 2_000, "B")])[0].speaker, "A")
    }

    func testUntimedNoEvidenceInvalidEvidenceAndSegments() {
        XCTAssertNil(SpeakerAttribution.assign([segment()], intervals: [])[0].speaker)
        for value in [segment(nil, nil), segment(nil, 100), segment(-1, 100), segment(100, 100), segment(0, Int64.max)] {
            XCTAssertNil(SpeakerAttribution.assign([value], intervals: [interval(0, 1_000)])[0].speaker)
        }
        for invalid in [interval(-1, 10), interval(10, 10), interval(11, 10), interval(0, Int64.max), interval(0, 100, " \n")] {
            XCTAssertNil(SpeakerAttribution.assign([segment()], intervals: [interval(0, 1_000), invalid])[0].speaker)
        }
    }

    func testEightGlobalLabelsDeterminismAndNoMutation() {
        var segments: [LocalTranscriptSegment] = []
        var intervals: [LocalSpeakerInterval] = []
        for index in 0..<8 {
            let start = Int64(index) * 1_000
            let end = start + 1_000
            segments.append(segment(start, end))
            intervals.append(interval(start, end, "speaker_\(index)"))
        }
        let result = SpeakerAttribution.assign(segments, intervals: intervals)
        XCTAssertEqual(result.map(\.speaker), (0..<8).map { "speaker_\($0)" })
        XCTAssertEqual(result, SpeakerAttribution.assign(segments, intervals: intervals.reversed()))
        XCTAssertEqual(segments.map(\.speaker), Array(repeating: "old", count: 8))
        XCTAssertEqual(intervals.map(\.speaker), (0..<8).map { "speaker_\($0)" })
        for (before, after) in zip(segments, result) {
            XCTAssertEqual(before.startMs, after.startMs)
            XCTAssertEqual(before.endMs, after.endMs)
            XCTAssertEqual(before.text, after.text)
        }
    }

}
