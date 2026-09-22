import XCTest
@testable import LessMeet

final class RecordingStoreTests: XCTestCase {
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
