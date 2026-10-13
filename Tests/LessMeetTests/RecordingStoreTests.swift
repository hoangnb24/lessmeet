import XCTest
@testable import LessMeet

final class RecordingStoreTests: XCTestCase {
    func testLegacyMetadataSurvivesRenameAndReopen() throws {
        try roundTripLegacyMetadata(status: "ready")
    }

    func testLegacyMetadataSurvivesInterruptedRecoveryAndReopen() throws {
        try roundTripLegacyMetadata(status: "recording")
    }

    private func roundTripLegacyMetadata(status: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let folder = store.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let literal = #"""
        {
          "id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"Legacy meeting",
          "createdAt":700000000,"duration":12,"status":"ready","failure":"prior note",
          "transcript":"Legacy transcript","messages":[
            {"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","role":"user","text":"Keep my question"}
          ],
          "cloud":{"https://example.invalid|legacy-user":{
            "recordingId":"remote-old","status":"ready","transcript":"Cloud transcript",
            "messages":[{"role":"assistant","text":"Saved answer"}],"error":"prior cloud error"
          }},
          "batches":{"https://example.invalid|legacy-user":{
            "clientBatchId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "manifest":{"version":1,"source":{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "bytes":100,"duration":{"value":12,"timescale":1}},
              "chunks":[{"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","bytes":100}]},
            "chunkPaths":["batch-cccccccc-cccc-4ccc-8ccc-cccccccccccc/chunk-0.m4a"],
            "pending":{"kind":"upload","index":0,"expectedAttempt":1,"expectedFence":2,"requestId":"request-old"},
            "results":{"0:1":{"version":1,"batchId":"batch-old","index":0,"attempt":1,
              "rawText":"{\"version\":1,\"segments\":[]}"}},
            "notice":"Keep pending work",
            "chat":{"confirmedAbsent":true,"request":{"batchId":"batch-old",
              "clientMessageId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
              "expectedContextDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "expectedHistoryRevision":0,"message":"Keep pending question"}}
          }}
        }
        """#
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any])
        original["status"] = status
        let metadata = folder.appendingPathComponent("recording.json")
        try JSONSerialization.data(withJSONObject: original).write(to: metadata)
        let audio = folder.appendingPathComponent("microphone.caf")
        let audioBytes = Data([1, 2, 3, 4])
        try audioBytes.write(to: audio)

        var issues: [String] = []
        var recording = try XCTUnwrap(store.load { issues.append($0) }.first)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(recording.status, status == "recording" ? .interrupted : .ready)
        recording.title = "Renamed local meeting"
        try store.save(recording)
        XCTAssertEqual(try RecordingStore(root: root).load(), [recording])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        for field in ["id", "createdAt", "duration", "transcript", "messages", "cloud", "batches"] {
            let expected = try XCTUnwrap(original[field] as? NSObject)
            let actual = try XCTUnwrap(saved[field] as? NSObject)
            XCTAssertEqual(actual, expected, "Legacy field changed: \(field)")
        }
        XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
    }

    func testIncompleteFolderDoesNotHideHealthyRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var recording = Recording(title: "Healthy")
        recording.status = .ready
        try store.save(recording)
        let incomplete = store.directory(for: UUID())
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        var issues: [String] = []
        XCTAssertEqual(try store.load { issues.append($0) }, [recording])
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
    }

    func testSaveAndReopenPreservesTranscriptAndChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var recording = Recording(title: "Design meeting")
        recording.status = .ready
        recording.duration = 123
        recording.transcript = "# Transcript\nHello"
        recording.messages = [ChatMessage(role: .user, text: "Summary?")]
        try store.save(recording)
        XCTAssertEqual(try RecordingStore(root: root).load(), [recording])
    }

    func testUnfinishedRecordingIsRecoveredWithoutDeletingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Interrupted")
        try store.save(recording)
        let audio = store.audioURL(for: recording.id, name: "microphone.caf")
        try Data([1, 2, 3]).write(to: audio)
        XCTAssertEqual(try store.load().first?.status, .interrupted)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
    }
}
