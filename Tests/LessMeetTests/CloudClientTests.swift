import XCTest
@testable import LessMeet

final class CloudClientTests: XCTestCase {
    private var session: URLSession!
    private var directory: URL!
    private var client: CloudClient { CloudClient(baseURL: URL(string: "https://fixture.convex.site")!, session: session) }

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudFixtureProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CloudFixtureProtocol.handler = { _ in throw URLError(.unsupportedURL) }
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
        CloudFixtureProtocol.handler = nil
    }

    func testRawFileUploadWithFreshBearerAndAcceptedID() async throws {
        let audio = Data("synthetic audio bytes".utf8)
        let file = directory.appendingPathComponent("combined.m4a")
        try audio.write(to: file)
        CloudFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://fixture.convex.site/recordings")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer upload-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/m4a")
            XCTAssertEqual(try Self.body(request), audio)
            return (202, Data(#"{"recordingId":"record-1"}"#.utf8))
        }
        let id = try await client.upload(fileURL: file, token: "upload-token")
        XCTAssertEqual(id, "record-1")
        XCTAssertEqual(try Data(contentsOf: file), audio)
    }

    func testEncodedQueryAndRecordingWarning() async throws {
        let id = "record &?=+#/é"
        CloudFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer read-token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "id", value: id)])
            return (200, try JSONEncoder().encode(CloudRecording(recordingId: id, status: "ready", transcript: "# Notes", messages: [CloudMessage(role: "user", text: "Question")], error: "Cleanup warning")))
        }
        let recording = try await client.recording(id: id, token: "read-token")
        XCTAssertEqual(recording.transcript, "# Notes")
        XCTAssertEqual(recording.messages.count, 1)
        XCTAssertEqual(recording.error, "Cleanup warning")
    }

    func testChatJSONAndNoHistoryOrTokenInBody() async throws {
        let message = "Quote: \"hello\"\nTiếng Việt"
        CloudFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chat-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String], ["recordingId": "r", "message": message])
            return (200, Data(#"{"text":"A reply"}"#.utf8))
        }
        let text = try await client.chat(id: "r", message: message, token: "chat-token")
        XCTAssertEqual(text, "A reply")
    }

    func testBillingStatusAndSyncUseOnlyBearerIdentity() async throws {
        for sync in [false, true] {
            CloudFixtureProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, sync ? "/billing/sync" : "/billing")
                XCTAssertEqual(request.httpMethod, sync ? "POST" : "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer billing-token")
                XCTAssertTrue(try Self.body(request).isEmpty)
                return (200, Data(#"{"userId":"alice","enforcement":true,"plan":"free","periodEndsAt":null,"transcriptionSeconds":{"limit":7200,"used":60,"reserved":120},"questions":{"limit":20,"used":1,"reserved":0}}"#.utf8))
            }
            let result = try await client.subscription(token: "billing-token", synchronize: sync)
            XCTAssertEqual(result.transcriptionSeconds.remaining, 7020)
            XCTAssertEqual(result.questions.remaining, 19)
        }
    }

    func testInvalidBillingCountsAndModeAreRejected() async throws {
        for plan in ["unknown", "development", "free"] {
            CloudFixtureProtocol.handler = { _ in
                (200, Data("""
                {"userId":"alice","enforcement":true,"plan":"\(plan)","periodEndsAt":null,
                 "transcriptionSeconds":{"limit":7200,"used":-1,"reserved":0},
                 "questions":{"limit":20,"used":0,"reserved":0}}
                """.utf8))
            }
            do { _ = try await client.subscription(token: "billing-token"); XCTFail("Invalid status accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unexpected response")) }
        }
    }

    func testDeletionUsesFreshBearerAndExplicitConfirmationWithoutOwnerInput() async throws {
        for submit in [false, true] {
            CloudFixtureProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/account/deletion")
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.httpMethod, submit ? "POST" : "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-deletion-token")
                if submit {
                    XCTAssertEqual(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String], ["confirm": "delete-account"])
                } else { XCTAssertTrue(try Self.body(request).isEmpty) }
                return (submit ? 202 : 200, Data(#"{"userId":"alice","requested":true,"localComplete":false,"providersComplete":false,"requestedAt":1234}"#.utf8))
            }
            let result = try await client.deletion(token: "fresh-deletion-token", requestDeletion: submit)
            XCTAssertTrue(result.requested); XCTAssertFalse(result.providersComplete)
        }
    }

    func testDeletionFailureDoesNotRetryOrMistakeAcceptanceForCompletion() async throws {
        var calls = 0
        CloudFixtureProtocol.handler = { _ in calls += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await client.deletion(token: "token", requestDeletion: true); XCTFail("Expected ambiguity") }
        catch { XCTAssertTrue(error.localizedDescription.contains("may already have been processed")) }
        XCTAssertEqual(calls, 1)
        CloudFixtureProtocol.handler = { _ in
            (200, Data(#"{"userId":"alice","requested":true,"localComplete":false,"providersComplete":true,"requestedAt":1234}"#.utf8))
        }
        do { _ = try await client.deletion(token: "token"); XCTFail("Impossible completion") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unexpected response")) }
    }

    func testRefreshDiagnosticsDistinguishHTTPDecodeAndValidationWithoutPrivateData() async {
        for scenario in ["ok", "http", "decode", "invalid", "network", "cancel"] {
            var lines: [String] = []
            let log = RefreshDiagnostics(expires: Date().addingTimeInterval(60), sink: { lines.append($0) })
            CloudFixtureProtocol.handler = { request in
                XCTAssertFalse(request.allHTTPHeaderFields!.keys.contains { $0.lowercased().contains("correlation") })
                if scenario == "network" { throw URLError(.networkConnectionLost) }
                if scenario == "cancel" { throw URLError(.cancelled) }
                if scenario == "http" { return (401, Data(#"{"error":"private-error"}"#.utf8)) }
                if scenario == "decode" { return (200, Data("private-body".utf8)) }
                let body = scenario == "invalid"
                    ? #"{"userId":"private-owner","requested":false,"localComplete":true,"providersComplete":false,"requestedAt":null}"#
                    : #"{"userId":"private-owner","requested":false,"localComplete":false,"providersComplete":false,"requestedAt":null}"#
                return (200, Data(body.utf8))
            }
            await RefreshDiagnostics.$current.withValue(log.trace(origin: .manual)) {
                do { _ = try await client.deletion(token: "private-token"); XCTAssertEqual(scenario, "ok") }
                catch { XCTAssertNotEqual(scenario, "ok") }
            }
            let expected = ["ok": "decoded", "http": "httpRejected", "decode": "decodeFailed",
                            "invalid": "invalidStatus", "network": "transportError", "cancel": "transportCancelled"][scenario]!
            XCTAssertTrue(lines.last!.contains("phase=\(expected)"))
            XCTAssertEqual(lines.contains { $0.contains("phase=httpSucceeded") }, ["ok", "decode", "invalid"].contains(scenario))
            XCTAssertFalse(lines.joined().contains("private-"))
        }
    }

    func testHTTPStatusSafeErrorAndMalformedMutationResponse() async throws {
        for status in [401, 404, 409, 413, 415, 502, 503] {
            CloudFixtureProtocol.handler = { _ in (status, Data(#"{"error":"Service temporarily paused."}"#.utf8)) }
            do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Expected HTTP error") }
            catch let error as CloudClientError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertTrue(error.localizedDescription.contains("Service temporarily paused."))
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
            }
        }
        CloudFixtureProtocol.handler = { _ in (200, Data("<html>private diagnostic</html>".utf8)) }
        do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Expected decoding error") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Refresh before retrying"))
            XCTAssertFalse(error.localizedDescription.contains("private diagnostic"))
        }
        CloudFixtureProtocol.handler = { _ in (503, Data(#"{"error":"fixture-token"}"#.utf8)) }
        do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Expected HTTP error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-token")) }
        CloudFixtureProtocol.handler = { _ in (202, Data(#"{"text":"Unexpected success status"}"#.utf8)) }
        do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Unexpected status accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Refresh before retrying")) }
    }

    func testUploadAndEndpointGuardsNeverReachTransport() async throws {
        CloudFixtureProtocol.handler = { _ in XCTFail("Guard must reject before networking"); throw URLError(.unsupportedURL) }
        let file = directory.appendingPathComponent("combined.m4a")
        try Data().write(to: file)
        do { _ = try await client.upload(fileURL: file, token: "fixture-token"); XCTFail("Empty file accepted") } catch {}
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(18 * 1024 * 1024 + 1))
        try handle.close()
        do { _ = try await client.upload(fileURL: file, token: "fixture-token"); XCTFail("Oversize file accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("18 MiB")) }
        for endpoint in ["http://fixture.convex.site", "https://fixture.convex.site.evil.test", "https://fixture.convex.cloud", "https://user@fixture.convex.site", "https://fixture.convex.site:443", "https://fixture.convex.site/path", "https://fixture.convex.site?q=x"] {
            let invalid = CloudClient(baseURL: URL(string: endpoint)!, session: session)
            do { _ = try await invalid.recording(id: "r", token: "fixture-token"); XCTFail("Unsafe endpoint accepted") } catch {}
        }
        do { _ = try await client.recording(id: "r", token: "bad\r\ntoken"); XCTFail("Invalid token accepted") } catch {}
    }

    func testNetworkFailureAndCancellationDoNotRetryMutations() async throws {
        for code in [URLError.Code.networkConnectionLost, .cancelled] {
            var calls = 0
            CloudFixtureProtocol.handler = { _ in calls += 1; throw URLError(code) }
            do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Expected transport error") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Refresh before retrying")) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testRedirectResponseIsRejected() async throws {
        CloudFixtureProtocol.handler = { _ in (307, Data()) }
        do { _ = try await client.chat(id: "r", message: "Question", token: "fixture-token"); XCTFail("Redirect accepted") }
        catch let error as CloudClientError {
            XCTAssertEqual(error.statusCode, 307)
            XCTAssertTrue(error.localizedDescription.contains("redirect rejected"))
        }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class CloudFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.host == "fixture.convex.site", let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            if status == 307 {
                var redirected = request
                redirected.url = URL(string: "https://elsewhere.invalid/stolen")!
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
