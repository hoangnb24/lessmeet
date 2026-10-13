import XCTest
@testable import LessMeet

@MainActor
final class LibraryUICheckTests: XCTestCase {
    func testSeedsTwoIsolatedLibrariesWithFixedTranscriptContent() throws {
        let first = try LibraryUICheckContext()
        let second = try LibraryUICheckContext()
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertEqual(first.store.root.deletingLastPathComponent(), first.root)
        XCTAssertEqual(first.model.recordings.count, 2)
        XCTAssertEqual(first.model.selection, LibraryUICheckContext.longID)
        let long = try XCTUnwrap(first.transcription.loadTranscript(recordingID: LibraryUICheckContext.longID))
        let short = try XCTUnwrap(first.transcription.loadTranscript(recordingID: LibraryUICheckContext.shortID))
        XCTAssertEqual(long.segments.count, 80)
        XCTAssertEqual(long.segments.first?.speaker, "Maya")
        XCTAssertEqual(long.segments.last?.speaker, "Alex")
        XCTAssertEqual(short.segments.count, 1)
        XCTAssertEqual(short.segments[0].text, "Maya: The synthetic planning check is complete. Alex will review the next draft on Friday.")
        XCTAssertEqual(try second.store.loadLocalTranscript(for: LibraryUICheckContext.longID), long)
        first.defaults.set(true, forKey: "fixture-isolation-check")
        XCTAssertFalse(second.defaults.bool(forKey: "fixture-isolation-check"))
        for recording in first.model.recordings {
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.store.audioURL(for: recording.id).path))
        }
    }

    func testCaptureAndModelDownloadsFailClosed() async throws {
        let fixture = try LibraryUICheckContext()
        await fixture.manager.startup()
        XCTAssertEqual(fixture.manager.state, .failed)
        XCTAssertEqual(fixture.manager.fileCount, 0)
        XCTAssertNil(fixture.manager.installed)
        fixture.manager.retry()
        await fixture.manager.start()
        XCTAssertEqual(fixture.manager.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Models").path))
        await fixture.model.startRecording()
        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertEqual(fixture.model.error, LibraryUICheckError.disabled.localizedDescription)
        XCTAssertEqual(fixture.model.recordings.first?.status, .interrupted)
        for recording in fixture.model.recordings {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: recording.id).path))
        }
    }

    func testOfflineChatPersistsPerMeetingAndAuthCannotLaunch() async throws {
        let fixture = try LibraryUICheckContext()
        XCTAssertTrue(fixture.session.canUseChatGPTPlan)
        let token = try await fixture.session.accessToken()
        XCTAssertEqual(token, "synthetic-access-only")
        fixture.chat.select(recordingID: LibraryUICheckContext.shortID)
        await fixture.chat.loadModels()
        XCTAssertEqual(fixture.chat.models.map(\.slug), ["fixture-chat"])
        fixture.chat.selectedModelSlug = "fixture-chat"
        let sent = await fixture.chat.send("Who reviews the draft?")
        XCTAssertTrue(sent)
        XCTAssertEqual(fixture.chat.messages.last?.text, "Synthetic answer: Alex will review the next draft on Friday.")
        fixture.chat.select(recordingID: LibraryUICheckContext.longID)
        XCTAssertTrue(fixture.chat.messages.isEmpty)
        fixture.chat.select(recordingID: LibraryUICheckContext.shortID)
        XCTAssertEqual(fixture.chat.messages.count, 2)
        XCTAssertEqual(fixture.chat.messages.last?.text, "Synthetic answer: Alex will review the next draft on Friday.")
        await fixture.session.signIn()
        XCTAssertNotNil(fixture.session.error)
        XCTAssertFalse(fixture.session.busy)
    }
}
