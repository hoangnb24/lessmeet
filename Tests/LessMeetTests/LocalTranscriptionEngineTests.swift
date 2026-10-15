import XCTest
@testable import LessMeet

final class LocalTranscriptionEngineTests: XCTestCase {
    private func segment(_ start: Int64?, _ end: Int64?, _ text: String, speaker: String? = "Speaker1") -> LocalTranscriptSegment {
        .init(startMs: start, endMs: end, speaker: speaker, text: text)
    }

    func testAbsoluteTimesUseWindowOriginAndRejectInvalidRelativeTimes() throws {
        let window = LocalAudioWindow(index: 1, samples: Array(repeating: 0, count: 16_000))
        let result = try LocalTranscriptionEngine.absolute([segment(0, 400, " Hello")], window: window)
        XCTAssertEqual(result, [segment(295_000, 295_400, " Hello", speaker: nil)])
        for value in [segment(nil, nil, "untimed"), segment(0, 1_001, "outside"), segment(-1, 4, "negative")] {
            XCTAssertThrowsError(try LocalTranscriptionEngine.absolute([value], window: window))
        }
    }

    func testGroupingPreservesSentenceTextAndSpeakerBoundaries() {
        let input = [segment(0, 300, " Xin"), segment(300, 600, " chào"), segment(600, 800, "!"),
                     segment(900, 1200, " Việt"), segment(1200, 1500, " Nam", speaker: "Speaker2"),
                     segment(1500, 1900, " unknown", speaker: nil), segment(1900, 2300, " words", speaker: nil)]
        XCTAssertEqual(LocalTranscriptionEngine.group(input), [segment(0, 800, "Xin chào!"),
            segment(900, 1200, "Việt"), segment(1200, 1500, "Nam", speaker: "Speaker2"),
            segment(1500, 2300, "unknown words", speaker: nil)])
    }

    func testGroupingBoundsGapsDurationAndUntimedEntries() {
        let input = [segment(0, 100, "a"), segment(851, 1000, " b"), segment(1000, 17000, " c"),
                     segment(nil, nil, " untimed "), segment(18000, 19000, " d")]
        XCTAssertEqual(LocalTranscriptionEngine.group(input).map(\.text), ["a", "b", "c", "untimed", "d"])
        XCTAssertTrue(LocalTranscriptionEngine.group([segment(0, 10, "  ")]).isEmpty)
    }
}
