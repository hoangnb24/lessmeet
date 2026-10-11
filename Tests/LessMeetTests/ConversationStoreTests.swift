import Darwin
import XCTest
@testable import LessMeet

final class ConversationStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var recordings: RecordingStore!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        recordings = try RecordingStore(root: temporaryRoot.appendingPathComponent("recordings"))
        store = ConversationStore(recordingStore: recordings)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    private func conversation(_ id: UUID = UUID(), answer: String = "Fixture answer") -> LocalConversation {
        LocalConversation(recordingID: id, messages: [
            ChatMessage(role: .user, text: "Fixture question"),
            ChatMessage(role: .assistant, text: answer)
        ])
    }

    private func path(_ id: UUID) -> URL {
        recordings.directory(for: id).appendingPathComponent("chat.json")
    }

    private func writeFixture(_ data: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: recordings.directory(for: id), withIntermediateDirectories: true)
        try data.write(to: path(id))
    }

    func testSaveReopenAndReplace() throws {
        var original = conversation()
        try store.save(original)
        let reopened = ConversationStore(recordingStore: try RecordingStore(root: recordings.root))
        XCTAssertEqual(try reopened.load(for: original.recordingID), original)
        original.messages += conversation().messages
        try reopened.save(original)
        XCTAssertEqual(try store.load(for: original.recordingID), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recordings.directory(for: original.recordingID).path), ["chat.json"])
    }

    func testTwoRecordingIsolation() throws {
        let first = conversation(answer: "First fixture")
        let second = conversation(answer: "Second fixture")
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(try store.load(for: first.recordingID), first)
        XCTAssertEqual(try store.load(for: second.recordingID), second)
    }

    func testAbsenceReturnsEmptyWithoutCreatingFilesOrMigratingLegacyMessages() throws {
        let absent = UUID()
        XCTAssertEqual(try store.load(for: absent), LocalConversation(recordingID: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.directory(for: absent).path))
        var legacy = Recording(title: "Fixture")
        legacy.messages = conversation().messages
        try recordings.save(legacy)
        XCTAssertEqual(try store.load(for: legacy.id), LocalConversation(recordingID: legacy.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(legacy.id).path))
    }

    func testMalformedVersionAndIDRejectionPreservesBytes() throws {
        let id = UUID()
        var unsupported = conversation(id)
        unsupported.version = 2
        let fixtures = [
            Data("not JSON".utf8),
            try JSONEncoder().encode(unsupported),
            try JSONEncoder().encode(conversation()),
            Data("{\"recordingID\":\"\(id.uuidString)\",\"messages\":[]}".utf8)
        ]
        for bytes in fixtures {
            try writeFixture(bytes, id: id)
            XCTAssertThrowsError(try store.load(for: id))
            XCTAssertThrowsError(try store.save(conversation(id)))
            XCTAssertEqual(try Data(contentsOf: path(id)), bytes)
        }
    }

    func testRejectsIncompleteAndMisorderedPairsOnLoadAndSave() throws {
        let id = UUID()
        let user = ChatMessage(role: .user, text: "Fixture question")
        let assistant = ChatMessage(role: .assistant, text: "Fixture answer")
        for messages in [[user], [assistant], [assistant, user], [user, user], [assistant, assistant], [user, assistant, user]] {
            let invalid = LocalConversation(recordingID: id, messages: messages)
            XCTAssertThrowsError(try store.save(invalid))
            let bytes = try JSONEncoder().encode(invalid)
            try writeFixture(bytes, id: id)
            XCTAssertThrowsError(try store.load(for: id))
            XCTAssertEqual(try Data(contentsOf: path(id)), bytes)
        }
    }

    func testEmptyConversationIsValid() throws {
        let empty = LocalConversation(recordingID: UUID())
        try store.save(empty)
        XCTAssertEqual(try store.load(for: empty.recordingID), empty)
    }

    func testRecordingAndTranscriptBytesRemainUnchanged() throws {
        let value = conversation()
        let folder = recordings.directory(for: value.recordingID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinels = ["recording.json", "transcript.json"]
        for name in sentinels { try Data("fixture-\(name)".utf8).write(to: folder.appendingPathComponent(name)) }
        try store.save(value)
        _ = try store.load(for: value.recordingID)
        for name in sentinels {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data("fixture-\(name)".utf8))
        }
    }

    func testSaveFailurePreservesGoodBytes() throws {
        let value = conversation()
        try store.save(value)
        let bytes = try Data(contentsOf: path(value.recordingID))
        var invalid = value
        invalid.messages.removeLast()
        XCTAssertThrowsError(try store.save(invalid))
        invalid = value
        invalid.version = 3
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: path(value.recordingID)), bytes)
        let folder = recordings.directory(for: value.recordingID)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        guard geteuid() != 0 else { throw XCTSkip("Directory permission failures require a non-root test user") }
        XCTAssertThrowsError(try store.save(conversation(value.recordingID, answer: "Replacement fixture")))
        XCTAssertEqual(try Data(contentsOf: path(value.recordingID)), bytes)
    }

    func testOwnerOnlyPermissionsAfterCreationAndReplacement() throws {
        let value = conversation()
        try store.save(value)
        for _ in 0..<2 {
            let attributes = try FileManager.default.attributesOfItem(atPath: path(value.recordingID).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try store.save(value)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: recordings.directory(for: value.recordingID).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRecordingFolderSymlinkIsRejected() throws {
        let value = conversation()
        let outside = temporaryRoot.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: recordings.directory(for: value.recordingID), withDestinationURL: outside)
        XCTAssertThrowsError(try store.load(for: value.recordingID))
        XCTAssertThrowsError(try store.save(value))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSidecarSymlinkAndDanglingSymlinkAreRejected() throws {
        for targetExists in [false, true] {
            let value = conversation()
            let outside = temporaryRoot.appendingPathComponent(UUID().uuidString)
            let bytes = try JSONEncoder().encode(value)
            if targetExists { try bytes.write(to: outside) }
            try FileManager.default.createDirectory(at: recordings.directory(for: value.recordingID), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: path(value.recordingID), withDestinationURL: outside)
            XCTAssertThrowsError(try store.load(for: value.recordingID))
            XCTAssertThrowsError(try store.save(value))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path(value.recordingID).path), outside.path)
            if targetExists { XCTAssertEqual(try Data(contentsOf: outside), bytes) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path)) }
        }
    }

    func testHardLinkedSidecarIsRejectedAndPreserved() throws {
        let value = conversation()
        try store.save(value)
        let outside = temporaryRoot.appendingPathComponent("hardlink.json")
        let bytes = try Data(contentsOf: path(value.recordingID))
        try FileManager.default.linkItem(at: path(value.recordingID), to: outside)
        XCTAssertThrowsError(try store.load(for: value.recordingID))
        XCTAssertThrowsError(try store.save(value))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(try Data(contentsOf: path(value.recordingID)), bytes)
    }

    func testDirectoryAtSidecarPathIsRejected() throws {
        let value = conversation()
        try FileManager.default.createDirectory(at: path(value.recordingID), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.load(for: value.recordingID))
        XCTAssertThrowsError(try store.save(value))
    }

    func testRootSymlinkIsRejected() throws {
        let value = conversation()
        let alias = temporaryRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: recordings.root)
        let aliasedStore = ConversationStore(recordingStore: try RecordingStore(root: alias))
        XCTAssertThrowsError(try aliasedStore.load(for: value.recordingID))
        XCTAssertThrowsError(try aliasedStore.save(value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(value.recordingID).path))
    }

    func testSymlinkToAnotherRecordingCannotCopyHistory() throws {
        let original = conversation()
        try store.save(original)
        let otherID = UUID()
        try FileManager.default.createSymbolicLink(at: recordings.directory(for: otherID),
                                                  withDestinationURL: recordings.directory(for: original.recordingID))
        XCTAssertThrowsError(try store.load(for: otherID))
        XCTAssertThrowsError(try store.save(conversation(otherID)))
        XCTAssertEqual(try store.load(for: original.recordingID), original)
    }

    func testFIFOIsRejectedWithoutBlocking() throws {
        let value = conversation()
        try FileManager.default.createDirectory(at: recordings.directory(for: value.recordingID), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(path(value.recordingID).path, 0o600), 0)
        XCTAssertThrowsError(try store.load(for: value.recordingID))
        XCTAssertThrowsError(try store.save(value))
    }
}
