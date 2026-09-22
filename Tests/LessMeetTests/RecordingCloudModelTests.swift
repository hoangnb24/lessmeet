import XCTest
import AppKit
import SwiftUI
@testable import LessMeet

private final class WorkflowProtocol: URLProtocol {
    static var respond: ((URLRequest) -> Data)?
    static var beforeDelivery: (() async -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = Self.respond?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let status = request.httpMethod == "POST" && request.url?.path == "/recordings" ? 202 : 200
        Task {
            await Self.beforeDelivery?()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

final class RecordingCloudModelTests: XCTestCase {
    @MainActor
    private func wait(_ model: RecordingCloudModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture request did not finish")
    }

    @MainActor
    func testUploadTranscriptChatAndReopenAreAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.respond = nil }
        let store = try RecordingStore(root: root)
        var local = Recording(title: "Fixture")
        local.status = .ready
        try store.save(local)
        try Data("synthetic fixture, never sent externally".utf8).write(to: store.audioURL(for: local.id))
        let app = AppModel(store: store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkflowProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        WorkflowProtocol.respond = { request in
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/recordings"): return Data(#"{"recordingId":"remote"}"#.utf8)
            case ("GET", "/recordings"): return Data(##"{"recordingId":"remote","status":"ready","transcript":"# Meeting","messages":[]}"##.utf8)
            case ("POST", "/chat"): return Data(#"{"text":"The decision."}"#.utf8)
            default: XCTFail("Unexpected fixture request"); return Data()
            }
        }
        var account: CloudIdentity? = CloudIdentity(owner: "alice", session: "session-a")
        let cloud = RecordingCloudModel(app: app, client: CloudClient(baseURL: URL(string: "https://fixture.convex.site")!, session: session),
                                        identity: { account }, token: { "fixture-token" }, pollDelay: .zero)
        cloud.transcribe()
        try await wait(cloud)
        XCTAssertNil(cloud.error)
        XCTAssertEqual(cloud.cached(app.selected!)?.transcript, "# Meeting")
        cloud.send("What was decided?")
        try await wait(cloud)
        XCTAssertNil(cloud.error)
        let reopened = try XCTUnwrap(store.load().first)
        XCTAssertEqual(reopened.cloud?["alice"]?.messages.map(\.text), ["What was decided?", "The decision."])
        XCTAssertEqual(reopened.cloud?["alice"]?.recordingId, "remote")
        if let output = ProcessInfo.processInfo.environment["LESSMEET_UI_SNAPSHOT"] {
            let accountPanel = AccountSession(configuration: try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil))
            let view = NSHostingView(rootView: LibraryView(model: app, accountSession: accountPanel, cloud: cloud)
                .environment(\.colorScheme, .light).background(Color.white))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 1180, height: 860)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        account = CloudIdentity(owner: "bob", session: "session-b")
        cloud.contextChanged()
        XCTAssertNil(cloud.cached(reopened))
        account = nil
        XCTAssertNil(cloud.cached(reopened))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: local.id).path))
    }

    @MainActor
    func testAccountChangedDuringTokenFetchDoesNotSendOrPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.respond = nil }
        let store = try RecordingStore(root: root)
        var local = Recording(title: "Fixture")
        local.status = .ready
        try store.save(local)
        try Data("fixture".utf8).write(to: store.audioURL(for: local.id))
        let app = AppModel(store: store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkflowProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        WorkflowProtocol.respond = { _ in XCTFail("Account changed: no request may be sent"); return Data() }
        var account = CloudIdentity(owner: "alice", session: "a")
        let cloud = RecordingCloudModel(app: app, client: CloudClient(baseURL: URL(string: "https://fixture.convex.site")!, session: session),
                                        identity: { account }, token: {
            account = CloudIdentity(owner: "bob", session: "b")
            return "old-token"
        })
        cloud.transcribe()
        try await wait(cloud)
        XCTAssertNil(app.selected?.cloud)
        XCTAssertNil(try store.load().first?.cloud)
    }

    func testLegacyMetadataWithoutCloudStillDecodes() throws {
        let old = #"{"id":"9197886F-53C0-4D14-BDBE-898D93C4A0C0","title":"Old","createdAt":0,"duration":10,"status":"ready","messages":[]}"#
        let recording = try JSONDecoder().decode(Recording.self, from: Data(old.utf8))
        XCTAssertNil(recording.cloud)
        XCTAssertEqual(recording.title, "Old")
    }

    @MainActor
    func testLateResponseCannotPublishAfterAccountOrSelectionChange() async throws {
        for changeAccount in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: root)
                WorkflowProtocol.respond = nil; WorkflowProtocol.beforeDelivery = nil
            }
            let store = try RecordingStore(root: root)
            var local = Recording(title: "Waiting")
            local.status = .ready
            local.cloud = ["alice": CloudRecording(recordingId: "remote", status: "processing", transcript: nil, messages: [], error: nil)]
            try store.save(local)
            let app = AppModel(store: store)
            var account = CloudIdentity(owner: "alice", session: "a")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [WorkflowProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            WorkflowProtocol.respond = { _ in Data(#"{"recordingId":"remote","status":"ready","transcript":"Private response","messages":[]}"#.utf8) }
            WorkflowProtocol.beforeDelivery = {
                await MainActor.run {
                    if changeAccount { account = CloudIdentity(owner: "bob", session: "b") }
                    else { app.selection = nil }
                }
            }
            let cloud = RecordingCloudModel(app: app, client: CloudClient(baseURL: URL(string: "https://fixture.convex.site")!, session: session),
                                            identity: { account }, token: { "fixture-token" })
            cloud.refresh()
            try await wait(cloud)
            XCTAssertNil(try store.load().first?.cloud?["alice"]?.transcript)
            XCTAssertEqual(app.recordings.first?.cloud?["alice"]?.status, "processing")
            XCTAssertNil(cloud.error)
        }
    }
}
