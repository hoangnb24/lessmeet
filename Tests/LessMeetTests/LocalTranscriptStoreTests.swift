import XCTest
@testable import LessMeet

final class LocalTranscriptStoreTests: XCTestCase {
    private var root: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try RecordingStore(root: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private let untimed = #"{"startMs":null,"endMs":null,"speaker":null,"text":"x"}"#

    private func wrap(_ segment: String) -> String {
        "{\"version\":1,\"segments\":[\(segment)]}"
    }

    private func write(_ json: String, for id: UUID) throws {
        try FileManager.default.createDirectory(at: store.directory(for: id), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url(id))
    }

    private func url(_ id: UUID) -> URL {
        store.directory(for: id).appendingPathComponent("transcript.json")
    }

    private func sample(_ text: String = " \tTiếng Việt 👩‍💻 e\u{301}\n\u{0}") -> LocalTranscript {
        LocalTranscript(segments: [
            .init(startMs: 300_000, endMs: 301_250, speaker: "speaker-1", text: text),
            .init(startMs: nil, endMs: nil, speaker: nil, text: ""),
            .init(startMs: 0, endMs: 1, speaker: nil, text: "unknown speaker")
        ])
    }

    func testLiteralSchemaAndExplicitNullEncoding() throws {
        let id = UUID()
        try write(wrap(untimed), for: id)
        let transcript = try XCTUnwrap(store.loadLocalTranscript(for: id))
        XCTAssertEqual(transcript, LocalTranscript(segments: [.init(startMs: nil, endMs: nil, speaker: nil, text: "x")]))
        try store.saveLocalTranscript(transcript, for: id)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url(id)), as: UTF8.self),
                       #"{"segments":[{"endMs":null,"speaker":null,"startMs":null,"text":"x"}],"version":1}"#)
    }

    func testTimedUntimedRoundTripIsolationAndReopen() throws {
        let first = UUID(), second = UUID()
        let transcript = sample()
        try store.saveLocalTranscript(transcript, for: first)
        try store.saveLocalTranscript(sample("second recording"), for: second)
        let reopened = try RecordingStore(root: root)
        XCTAssertEqual(try reopened.loadLocalTranscript(for: first), transcript)
        XCTAssertEqual(try reopened.loadLocalTranscript(for: second), sample("second recording"))
        let loaded = try XCTUnwrap(reopened.loadLocalTranscript(for: first))
        XCTAssertEqual(Array(loaded.segments[0].text.utf8), Array(transcript.segments[0].text.utf8))
    }

    func testMissingReturnsNilWithoutCloudFallbackOrMetadataChanges() throws {
        XCTAssertNil(try store.loadLocalTranscript(for: UUID()))
        var recording = Recording(title: "Synthetic recording")
        recording.status = .ready
        recording.transcript = "Existing legacy transcript must not be used"
        recording.messages = [.init(role: .user, text: "Existing message")]
        try store.save(recording)
        let metadata = store.directory(for: recording.id).appendingPathComponent("recording.json")
        let before = try Data(contentsOf: metadata)
        XCTAssertNil(try store.loadLocalTranscript(for: recording.id))
        try store.saveLocalTranscript(sample(), for: recording.id)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(try store.load(), [recording])
        try write("not JSON", for: recording.id)
        XCTAssertThrowsError(try store.loadLocalTranscript(for: recording.id))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
    }

    func testMalformedStrictKeysAndDuplicateKeys() throws {
        let id = UUID()
        let bad = [
            "", "null", "[]", "not JSON",
            #"{"version":1,"segments":[],}"#,
            #"{"version":1,"segments":[,]}"#,
            #"{"version":1,"segments":[]} trailing"#,
            #"{"version":1,"segments":[],"extra":0}"#,
            #"{"segments":[]}"#,
            #"{"version":1}"#,
            #"{"version":true,"segments":[]}"#,
            #"{"version":1,"segments":null}"#,
            #"{"version":1,"version":1,"segments":[]}"#,
            #"{"version":1,"\u0076ersion":1,"segments":[]}"#,
            wrap(untimed.replacingOccurrences(of: #""startMs":null,"#, with: "")),
            wrap(untimed.replacingOccurrences(of: #""endMs":null,"#, with: "")),
            wrap(untimed.replacingOccurrences(of: #""speaker":null,"#, with: "")),
            wrap(#"{"startMs":null,"endMs":null,"speaker":null}"#),
            wrap(untimed.replacingOccurrences(of: #""text":"x""#, with: #""text":"x","extra":0"#)),
            wrap(untimed.replacingOccurrences(of: #""text":"x""#, with: #""text":"x","\u0074ext":"x""#)),
            wrap(untimed.replacingOccurrences(of: #""text":"x""#, with: #""text":"\ud800""#)),
            wrap(untimed.replacingOccurrences(of: #""text":"x""#, with: #""text":null"#)),
            wrap(untimed.replacingOccurrences(of: #""speaker":null"#, with: #""speaker":1"#)),
            wrap(untimed.replacingOccurrences(of: #""startMs":null,"endMs":null"#, with: #""startMs":true,"endMs":1"#)),
            wrap(untimed.replacingOccurrences(of: #""startMs":null,"endMs":null"#, with: #""startMs":0.5,"endMs":1"#)),
            wrap(untimed.replacingOccurrences(of: #""startMs":null,"endMs":null"#, with: #""startMs":0,"endMs":9223372036854775808"#))
        ]
        for json in bad {
            try write(json, for: id)
            XCTAssertThrowsError(try store.loadLocalTranscript(for: id), json)
        }
    }

    func testUnsupportedVersionAndInvalidTimestampPairsOnDecodeAndSave() throws {
        let id = UUID()
        try write(#"{"version":2,"segments":[]}"#, for: id)
        XCTAssertThrowsError(try store.loadLocalTranscript(for: id)) {
            XCTAssertEqual($0 as? LocalTranscriptError, .unsupportedVersion(2))
        }
        for (start, end): (Int64?, Int64?) in [(nil, 1), (0, nil), (-1, 1), (0, 0), (2, 1)] {
            let segment = LocalTranscriptSegment(startMs: start, endMs: end, speaker: nil, text: "x")
            XCTAssertThrowsError(try store.saveLocalTranscript(.init(segments: [segment]), for: id))
            let startJSON = start.map(String.init) ?? "null"
            let endJSON = end.map(String.init) ?? "null"
            try write(wrap("{\"startMs\":\(startJSON),\"endMs\":\(endJSON),\"speaker\":null,\"text\":\"x\"}"), for: id)
            XCTAssertThrowsError(try store.loadLocalTranscript(for: id))
        }
        try store.saveLocalTranscript(.init(segments: [.init(startMs: 0, endMs: Int64.max, speaker: nil, text: "x")]), for: id)
        XCTAssertEqual(try store.loadLocalTranscript(for: id)?.segments.first?.endMs, Int64.max)
    }

    func testFailedValidationAndOversizeSavePreservePreviousBytes() throws {
        let id = UUID()
        try store.saveLocalTranscript(sample(), for: id)
        let before = try Data(contentsOf: url(id))
        let invalid = [
            LocalTranscript(version: 2, segments: []),
            LocalTranscript(segments: [.init(startMs: 1, endMs: 0, speaker: nil, text: "x")]),
            LocalTranscript(segments: [.init(startMs: nil, endMs: nil, speaker: nil,
                text: String(repeating: "x", count: RecordingStore.localTranscriptMaximumBytes))])
        ]
        for transcript in invalid {
            XCTAssertThrowsError(try store.saveLocalTranscript(transcript, for: id))
            XCTAssertEqual(try Data(contentsOf: url(id)), before)
            XCTAssertEqual(try store.loadLocalTranscript(for: id), sample())
        }
    }

    func testWholeRecordingByteLimitWithoutTruncation() throws {
        let id = UUID()
        let transcript = sample(String(repeating: "é", count: 256 * 1024))
        try store.saveLocalTranscript(transcript, for: id)
        XCTAssertGreaterThan(try Data(contentsOf: url(id)).count, 384 * 1024)
        XCTAssertEqual(try store.loadLocalTranscript(for: id), transcript)
        let empty = #"{"version":1,"segments":[]}"#
        let boundary = empty + String(repeating: " ", count: RecordingStore.localTranscriptMaximumBytes - empty.utf8.count)
        try write(boundary, for: id)
        XCTAssertEqual(try store.loadLocalTranscript(for: id), LocalTranscript(segments: []))
        try write(boundary + " ", for: id)
        XCTAssertThrowsError(try store.loadLocalTranscript(for: id)) {
            XCTAssertEqual($0 as? LocalTranscriptError, .tooLarge)
        }
    }

    func testReadErrorsAreNotReportedAsMissing() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: url(id), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.loadLocalTranscript(for: id))
    }
}
