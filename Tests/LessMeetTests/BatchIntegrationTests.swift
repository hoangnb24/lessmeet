import AVFoundation
import CryptoKit
import SwiftUI
import XCTest
@testable import LessMeet

private final class BatchProtocol: URLProtocol, @unchecked Sendable {
    static var reply: (@MainActor (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            do {
                let (status, data) = try Self.reply!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class BatchHarness {
    let root: URL
    let store: RecordingStore
    let app: AppModel
    let session: URLSession
    var identity = CloudIdentity(owner: "alice", session: "a")
    var model: RecordingCloudModel!
    var remote: LocalBatch?
    var slots: [String] = []
    var attempts: [Int] = []
    var revision: Int64 = 0
    var state = "uploading"
    var aggregateState = "complete"
    var calls: [String] = []
    var disabled = false
    var loseCreate = false
    var loseUpload = false
    var loseSeal = false
    var loseRetry = false
    var unknownRetry = false
    var missingRaw = false
    var oversizedRaw = false
    var wrongDigest = false
    var aggregateOverride: BatchAggregateResponse?
    var sealStates: [String]?
    var beforeReply: (() -> Void)?
    var nonces: [String] = []
    var failSave: (Recording) -> Bool = { _ in false }
    let raw = #"{"version":1,"segments":[{"startMs":0,"endMs":1000,"speaker":"A","text":"Decision: keep originals."}]}"#

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LessMeet-BatchIntegration-\(UUID())")
        var saveHook: ((Recording) throws -> Void)?
        store = try RecordingStore(root: root, beforeSave: { try saveHook?($0) })
        var recording = Recording(title: "Synthetic batch"); recording.status = .ready
        recording.cloud = ["alice": .init(recordingId: "legacy", status: "ready", transcript: "Legacy text", messages: [], error: nil)]
        try store.save(recording)
        app = AppModel(store: store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchProtocol.self]
        session = URLSession(configuration: configuration)
        saveHook = { [weak self] recording in if self?.failSave(recording) == true { throw CocoaError(.fileWriteOutOfSpace) } }
        model = makeModel()
        BatchProtocol.reply = { [weak self] request in try self!.respond(request) }
    }
    func makeModel(app replacement: AppModel? = nil, backend: String = "https://fixture.convex.site") -> RecordingCloudModel {
        RecordingCloudModel(app: replacement ?? app, client: CloudClient(baseURL: URL(string: backend)!, session: session), identity: { [weak self] in self?.identity }, token: { "fixture-token" }, pollDelay: .zero)
    }
    func close() { session.invalidateAndCancel(); BatchProtocol.reply = nil; try? FileManager.default.removeItem(at: root) }
    func audio(seconds: Int = 3) async throws {
        let folder = store.directory(for: app.selected!.id)
        let source = folder.appendingPathComponent("system.caf")
        try BatchIntegrationTests.writePCM(source, frames: seconds * 24_000, rate: 24_000)
        _ = try await CapturedAudio(directory: folder, tracks: [.init(source: .system, url: source, start: .zero, duration: CMTime(value: Int64(seconds), timescale: 1))], warning: "").exportCombined()
    }
    func wait(_ chosen: RecordingCloudModel? = nil) async throws {
        let model = chosen ?? model!
        for _ in 0..<2000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Batch fixture did not complete")
    }
    func saved() throws -> LocalBatch { try XCTUnwrap(store.load().first?.batches?.values.first) }
    func status() throws -> Data {
        let local = try XCTUnwrap(remote)
        let value = BatchStatus(version: 1, batchId: "batch-remote", clientBatchId: local.clientBatchId, manifestDigest: wrongDigest ? String(repeating: "0", count: 64) : try local.manifest.digest, revision: revision, state: state, quotaSeconds: (local.manifest.source.duration.value + Int64(local.manifest.source.duration.timescale) - 1) / Int64(local.manifest.source.duration.timescale),
            chunks: slots.enumerated().map { i, s in .init(index: i, state: s, attempt: attempts[i], fence: Int64(attempts[i]), retryAllowed: s == "failed" && attempts[i] == 1, resultAvailable: s == "succeeded", error: nil) },
            aggregate: .init(state: aggregateState, available: aggregateState == "complete" || aggregateState == "partial"), cleanupPending: false)
        return try JSONEncoder().encode(value)
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        calls.append("\(request.httpMethod!) \(path)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let local = try saved() // Every real request must already have durable identity/manifest/paths.
        XCTAssertEqual(local.chunkPaths.count, local.manifest.chunks.count)
        XCTAssertTrue(BatchValidation.uuid(local.clientBatchId))
        beforeReply?()
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        if path.hasSuffix("/transcription-batches") {
            if request.httpMethod == "POST" {
                XCTAssertEqual(local.pending?.kind, "create")
                let body = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Any]
                XCTAssertEqual(Set(body.keys), ["clientBatchId", "manifest"])
                XCTAssertEqual(body["clientBatchId"] as? String, local.clientBatchId)
                let wire = try JSONDecoder().decode(BatchManifest.self, from: json(body["manifest"]!))
                XCTAssertEqual(try wire.digest, try local.manifest.digest)
                if disabled { return (503, try json(["version": 1, "error": ["code": "unavailable", "message": "disabled"]])) }
                remote = local; slots = Array(repeating: "missing", count: local.manifest.chunks.count); attempts = Array(repeating: 0, count: slots.count)
                if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
                return (201, try status())
            }
            XCTAssertEqual(q("clientBatchId"), local.clientBatchId)
            XCTAssertEqual(query.count, 1)
            if remote == nil { return (404, try json(["version": 1, "error": ["code": "absent", "message": "absent"]])) }
            return (200, try status())
        }
        if path.hasSuffix("/chunk") {
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(local.pending?.kind, "upload")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/m4a")
            XCTAssertEqual(q("batchId"), "batch-remote")
            let i = Int(q("index")!)!
            let audio = bodyData(request)
            XCTAssertEqual(Int64(audio.count), local.manifest.chunks[i].bytes)
            XCTAssertEqual(SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(), local.manifest.chunks[i].sha256)
            slots[i] = "uploaded"; revision += 1
            if loseUpload { loseUpload = false; throw URLError(.networkConnectionLost) }
            return (200, try status())
        }
        if path.hasSuffix("/seal") {
            XCTAssertEqual(local.pending?.kind, "seal")
            let body = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Any]
            XCTAssertEqual(Set(body.keys), ["batchId", "manifestDigest"])
            XCTAssertEqual(body["manifestDigest"] as? String, try local.manifest.digest)
            state = sealStates == nil ? "complete" : "partial"; slots = sealStates ?? slots.map { _ in "succeeded" }; attempts = attempts.map { _ in 1 }; revision += 1
            if loseSeal { loseSeal = false; throw URLError(.networkConnectionLost) }
            return (202, try status())
        }
        if path.hasSuffix("/retry") {
            let pending = try XCTUnwrap(local.pending)
            XCTAssertEqual(pending.kind, "retry")
            let body = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Any]
            XCTAssertEqual(Set(body.keys), ["batchId", "index", "expectedAttempt", "expectedFence", "requestId", "confirm"])
            XCTAssertEqual(body["confirm"] as? String, "retry-failed-chunk")
            XCTAssertEqual(body["requestId"] as? String, pending.requestId)
            nonces.append(pending.requestId!)
            if loseRetry {
                loseRetry = false
                if unknownRetry { attempts[0] = 2; slots[0] = "unknown"; state = "attention"; revision += 1 }
                throw URLError(.networkConnectionLost)
            }
            attempts[0] = 2; slots[0] = "succeeded"; state = "complete"; revision += 1
            return (202, try status())
        }
        if path.hasSuffix("/result") {
            if missingRaw { return (404, try json(["version": 1, "error": ["code": "absent", "message": "absent"]])) }
            return (200, try JSONEncoder().encode(BatchRawResult(version: 1, batchId: "batch-remote", index: Int(q("index")!)!, attempt: Int(q("attempt")!)!, rawText: oversizedRaw ? String(repeating: "x", count: 384 * 1024 + 1) : raw)))
        }
        if path.hasSuffix("/aggregate") {
            if let aggregateOverride { return (200, try JSONEncoder().encode(aggregateOverride)) }
            let missing = slots.indices.filter { slots[$0] != "succeeded" }
            let source = BatchAggregate.Source(chunkIndex: 0, segmentIndex: 0, speaker: .init(chunkIndex: 0, localLabel: "A"))
            let actualState = state == "uploading" ? "pending" : (aggregateState == "partial" && missing.isEmpty ? "complete" : aggregateState)
            let aggregate = ["complete", "partial"].contains(actualState) ? BatchAggregate(version: 1, durationMs: try local.manifest.source.duration.enclosingMilliseconds, missingChunks: missing, timed: slots.first == "succeeded" ? [.init(startMs: 0, endMs: 1000, text: "Decision: keep originals.", sources: [source], overlaps: false)] : [], untimed: []) : nil
            return (200, try JSONEncoder().encode(BatchAggregateResponse(version: 1, batchId: "batch-remote", revision: revision, status: actualState, missingChunks: missing, aggregate: aggregate)))
        }
        XCTFail("Unexpected batch route \(path)"); throw URLError(.unsupportedURL)
    }
    private func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

final class BatchIntegrationTests: XCTestCase {
    private func validationManifest() throws -> BatchManifest {
        let json: [String: Any] = ["version": 1, "source": ["sha256": String(repeating: "a", count: 64), "bytes": 1, "duration": ["value": 301, "timescale": 1]], "chunks": (0..<2).map { _ in ["sha256": String(repeating: "b", count: 64), "bytes": 1] }]
        return try JSONDecoder().decode(BatchManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testStrictRawRegressionMissingNullableFields() throws {
        let raw = BatchRawResult(version: 1, batchId: "b", index: 0, attempt: 1, rawText: #"{"version":1,"segments":[{"text":"x"}]}"#)
        XCTAssertThrowsError(try raw.validate(manifest: validationManifest()))
    }
    func testStrictRawSchemaUnicodeAndByteBoundaries() throws {
        let manifest = try validationManifest()
        func check(_ raw: String) throws {
            let result = BatchRawResult(version: 1, batchId: "b", index: 0, attempt: 1, rawText: raw)
            try result.validate(manifest: manifest)
            XCTAssertEqual(Array(result.rawText.utf8), Array(raw.utf8))
        }
        let valid = #"{"startMs":null,"endMs":null,"speaker":null,"text":"x"}"#
        func wrap(_ segment: String) -> String { "{\"version\":1,\"segments\":[\(segment)]}" }
        let bad = [
            #"{"version":1,"segments":[],}"#,
            #"{"version":1,"segments":[,]}"#,
            #"{"version":1,"segments":[]} trailing"#,
            #"{"version":1,"segments":[],"extra":0}"#,
            #"{"version":1,"version":1,"segments":[]}"#,
            #"{"version":1,"\u0076ersion":1,"segments":[]}"#,
            #"{"version":true,"segments":[]}"#,
            wrap(valid.replacingOccurrences(of: #""startMs":null,"#, with: "")),
            wrap(valid.replacingOccurrences(of: #""endMs":null,"#, with: "")),
            wrap(valid.replacingOccurrences(of: #""speaker":null,"#, with: "")),
            wrap(valid.replacingOccurrences(of: #""text":"x""#, with: #""text":"x","extra":0"#)),
            wrap(valid.replacingOccurrences(of: #""text":"x""#, with: #""text":"x","\u0074ext":"x""#)),
            wrap(valid.replacingOccurrences(of: #""text":"x""#, with: #""text":"\ud800""#)),
            wrap(valid.replacingOccurrences(of: #""text":"x""#, with: #""text":"\udc00""#)),
            wrap(valid.replacingOccurrences(of: #""startMs":null,"endMs":null"#, with: #""startMs":true,"endMs":1"#)),
            wrap(valid.replacingOccurrences(of: #""startMs":null,"endMs":null"#, with: #""startMs":0.5,"endMs":1"#)),
            wrap(valid.replacingOccurrences(of: #""startMs":null"#, with: #""startMs":0"#))
        ]
        for raw in bad { XCTAssertThrowsError(try check(raw), raw) }
        func textRaw(_ text: String, speaker: Any = NSNull()) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "segments": [["startMs": NSNull(), "endMs": NSNull(), "speaker": speaker, "text": text]]]), as: UTF8.self)
        }
        for value in ["", " \t\r\n", "\u{200b}\u{200d}", "x\u{0}", "x\u{8}", "x\u{b}", "x\u{c}", "x\u{1f}", "x\u{7f}", "x\u{85}", "x\u{9f}", "x\u{61c}", "x\u{200e}", "x\u{202e}", "x\u{2069}"] {
            XCTAssertThrowsError(try check(textRaw(value)), value.debugDescription)
            XCTAssertThrowsError(try check(textRaw("x", speaker: value)), value.debugDescription)
        }
        for value in [" A\t\r\n", "Tiếng Việt 👩‍💻", "e\u{301}", "x\u{200d}", "x\u{feff}"] { XCTAssertNoThrow(try check(textRaw(value, speaker: value))) }
        XCTAssertNoThrow(try check(textRaw(String(repeating: "é", count: 4096), speaker: String(repeating: "é", count: 64))))
        XCTAssertThrowsError(try check(textRaw(String(repeating: "é", count: 4096) + "x")))
        XCTAssertThrowsError(try check(textRaw("x", speaker: String(repeating: "é", count: 64) + "x")))
        XCTAssertNoThrow(try check("{\"version\":1,\"segments\":[" + Array(repeating: valid, count: 2048).joined(separator: ",") + "]}"))
        XCTAssertThrowsError(try check("{\"version\":1,\"segments\":[" + Array(repeating: valid, count: 2049).joined(separator: ",") + "]}"))
        let empty = #"{"version":1,"segments":[]}"#
        XCTAssertNoThrow(try check(empty + String(repeating: " ", count: 384 * 1024 - empty.utf8.count)))
        XCTAssertThrowsError(try check(empty + String(repeating: " ", count: 384 * 1024 - empty.utf8.count + 1)))
        XCTAssertNoThrow(try check(#" {"version":1.0,"segments":[{"startMs":0e0,"endMs":3e5,"speaker":null,"text":"\ud83d\udc69"}]} "#))
    }
    func testAggregateStateAndMissingStructure() throws {
        let m = try validationManifest()
        func response(_ status: String, _ missing: [Int], _ inner: [Int]?) -> BatchAggregateResponse {
            .init(version: 1, batchId: "b", revision: 1, status: status, missingChunks: missing, aggregate: inner.map { .init(version: 1, durationMs: 301000, missingChunks: $0, timed: [], untimed: []) })
        }
        for value in [response("complete", [1], [1]), response("partial", [], []), response("partial", [1], []), response("partial", [1, 1], [1, 1]), response("partial", [2], [2]), response("partial", [1, 0], [1, 0]), response("partial", [1], nil), response("complete", [], nil), response("pending", [], []), response("too_large", [], []), response("invented", [], nil)] { XCTAssertThrowsError(try value.validate(manifest: m)) }
        for value in [response("partial", [1], [1]), response("complete", [], []), response("pending", [1], nil), response("too_large", [], nil)] { XCTAssertNoThrow(try value.validate(manifest: m)) }
    }
    private func missingProvenance(untimed: Bool = false) -> BatchAggregateResponse {
        let source = BatchAggregate.Source(chunkIndex: 1, segmentIndex: 0, speaker: nil)
        return .init(version: 1, batchId: "batch-remote", revision: 100, status: "partial", missingChunks: [1], aggregate: .init(version: 1, durationMs: 301000, missingChunks: [1], timed: untimed ? [] : [.init(startMs: 295000, endMs: 296000, text: "forged", sources: [source], overlaps: false)], untimed: untimed ? [.init(chunkIndex: 1, segments: [.init(text: "forged", source: source)])] : []))
    }
    func testMissingProvenanceRegression() throws {
        for untimed in [false, true] { XCTAssertThrowsError(try missingProvenance(untimed: untimed).validate(manifest: validationManifest())) }
    }
    @MainActor func testMissingProvenanceRegressionPreservesPublishedAndReopenedPartial() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(seconds: 301)
        h.sealStates = ["succeeded", "failed"]; h.aggregateState = "partial"
        h.model.transcribe(); try await h.wait(); XCTAssertNil(h.model.error)
        let previous = try h.saved()
        let validAggregate = try XCTUnwrap(previous.aggregate?.aggregate)
        let inconsistent = BatchAggregateResponse(version: 1, batchId: "batch-remote", revision: 100, status: "complete", missingChunks: [1], aggregate: validAggregate)
        for invalid in [missingProvenance(), missingProvenance(untimed: true), inconsistent] {
            h.aggregateOverride = invalid
            h.model.refresh(); try await h.wait()
            XCTAssertNotNil(h.model.error)
            XCTAssertEqual(try h.saved().aggregate, previous.aggregate)
            XCTAssertEqual(try h.saved().lastReadableAggregate, previous.lastReadableAggregate)
            XCTAssertEqual(h.model.batch(h.app.selected!)?.aggregate, previous.aggregate)
            let reopened = AppModel(store: h.store)
            XCTAssertEqual(h.makeModel(app: reopened).batch(reopened.selected!)?.aggregate, previous.aggregate)
        }
    }
    static func writePCM(_ url: URL, frames: Int, rate: Int) throws {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        defer { file.close() }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var position = 0
        while position < frames {
            buffer.frameLength = AVAudioFrameCount(min(4096, frames - position))
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 440 * Double(position + i) / Double(rate))) }
            try file.write(from: buffer); position += Int(buffer.frameLength)
        }
    }
    func testCrossLanguageDigestVectorsAndReduction() throws {
        let vectors: [(Int64, Int32, Int, String)] = [
            (3, 1, 1, "d588f41153cbecfb16bc094d8bcf54bad2481d9ff03e9256b95ad2ce11671ddd"),
            (132301, 44100, 1, "a9fd2a1b6fbefd0e4151c53053812921c8915f60542278f65b694ca47de9b929"),
            (1, 48000, 1, "b55b49a81f021647dfb25106e3c3a3b134b204d98639babfe98c657279338bf9"),
            (7200, 1, 25, "aca0e3708e454c11a197db4e0f19919fe52f87363450273312f8e20b8f273f03"),
            (13230001, 44100, 2, "9b20ac0fc809d2f30ddb7ad4c8cd7be0ded2966f497e9b5e850d9102744c3c76")]
        for (value, scale, count, expected) in vectors {
            let json: [String: Any] = ["version": 1, "source": ["sha256": String(repeating: "a", count: 64), "bytes": 1234, "duration": ["value": value, "timescale": scale]], "chunks": (0..<count).map { ["sha256": String(repeating: "b", count: 64), "bytes": 99 + $0] }]
            let manifest = try JSONDecoder().decode(BatchManifest.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(try manifest.digest, expected)
        }
        XCTAssertEqual(try BatchManifest.Rational(value: 144000, timescale: 48000), try BatchManifest.Rational(value: 3, timescale: 1))
        XCTAssertEqual(try BatchManifest.Rational(value: 1, timescale: 48000).enclosingMilliseconds, 1)
        XCTAssertThrowsError(try BatchManifest.Rational(value: Int64.max, timescale: 1))
        XCTAssertThrowsError(try BatchValidation.multiply(Int64.max, 1000))
        XCTAssertThrowsError(try BatchManifest.Rational(value: 7200 * 48000 + 1, timescale: 48000))
    }
    @MainActor func testActualWorkflowSaveReopenRawProvenanceAndLegacyIsolation() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio()
        let original = try TranscriptionChunks.identity(h.store.audioURL(for: h.app.selected!.id))
        h.model.transcribe(); try await h.wait()
        XCTAssertNil(h.model.error)
        let saved = try h.saved()
        XCTAssertEqual(saved.status?.state, "complete")
        XCTAssertNil(saved.pending)
        XCTAssertEqual(saved.results["0:1"]?.rawText, h.raw)
        XCTAssertEqual(saved.aggregate?.aggregate?.timed.first?.sources.first?.speaker?.localLabel, "A")
        let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
        XCTAssertEqual(model.batch(reopened.selected!), saved)
        XCTAssertEqual(model.cached(reopened.selected!)?.transcript, "Legacy text")
        XCTAssertNil(h.makeModel(app: reopened, backend: "https://other.convex.site").batch(reopened.selected!))
        h.identity = .init(owner: "bob", session: "b")
        XCTAssertNil(model.batch(reopened.selected!))
        XCTAssertEqual(try TranscriptionChunks.identity(h.store.audioURL(for: h.app.selected!.id)), original)
    }
    @MainActor func testLostCreateAndUploadRecoverByKeyWithoutAutomaticRepeat() async throws {
        for operation in ["create", "upload"] {
            let h = try BatchHarness(); defer { h.close() }; try await h.audio()
            h.loseCreate = operation == "create"; h.loseUpload = operation == "upload"
            h.model.transcribe(); try await h.wait()
            XCTAssertNotNil(h.model.error)
            let saved = try h.saved(); XCTAssertEqual(saved.pending?.kind, operation)
            let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
            model.refresh(); try await h.wait(model)
            XCTAssertNil(try h.saved().pending)
            XCTAssertEqual(try h.saved().clientBatchId, saved.clientBatchId)
            XCTAssertEqual(h.calls.filter { $0 == "POST /v1/transcription-batches" }.count, 1)
            model.continueBatch(); try await h.wait(model)
            XCTAssertNil(model.error)
            XCTAssertEqual(try h.saved().status?.state, "complete")
            XCTAssertEqual(h.calls.filter { $0.hasPrefix("PUT") }.count, 1)
        }
    }
    @MainActor func testDefaultOffKeepsPreparationAndExplicitContinueUsesSameIdentity() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(); h.disabled = true
        h.model.transcribe(); try await h.wait()
        XCTAssertTrue(h.model.error?.contains("disabled") == true)
        let saved = try h.saved(); XCTAssertEqual(saved.pending?.kind, "create")
        h.disabled = false
        h.model.continueBatch(); try await h.wait()
        XCTAssertNil(h.model.error)
        XCTAssertEqual(try h.saved().clientBatchId, saved.clientBatchId)
        XCTAssertEqual(try h.saved().chunkPaths, saved.chunkPaths)
    }
    @MainActor func testDiskFailureBeforeRequestAndBeforePublishingResponse() async throws {
        for afterRequest in [false, true] {
            let h = try BatchHarness(); defer { h.close() }; try await h.audio()
            if afterRequest { h.beforeReply = { h.failSave = { _ in true } } }
            else { h.failSave = { $0.batches != nil } }
            h.model.transcribe(); try await h.wait()
            XCTAssertNotNil(h.model.error)
            if afterRequest {
                XCTAssertEqual(h.calls.count, 1)
                XCTAssertNil(h.model.batch(h.app.selected!)?.status)
                XCTAssertEqual(try h.saved().pending?.kind, "create")
            } else { XCTAssertTrue(h.calls.isEmpty); XCTAssertNil(h.app.selected?.batches) }
        }
    }
    @MainActor func testAccountSwitchBeforeResponseCannotPublish() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio()
        h.beforeReply = { h.identity = .init(owner: "bob", session: "b") }
        h.model.transcribe(); try await h.wait()
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertNil(try h.saved().status)
        XCTAssertNil(h.model.batch(h.app.selected!))
    }
    @MainActor func testResultDiskFailureDoesNotPublishAndRecoversWithoutMutation() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio()
        h.failSave = { $0.batches?.values.first?.aggregate != nil }
        h.model.transcribe(); try await h.wait()
        XCTAssertNotNil(h.model.error)
        XCTAssertEqual(try h.saved().status?.state, "complete")
        XCTAssertNil(h.model.batch(h.app.selected!)?.aggregate)
        let mutations = h.calls.filter { !$0.hasPrefix("GET") }
        h.failSave = { _ in false }
        h.model.refresh(); try await h.wait()
        XCTAssertNil(h.model.error)
        XCTAssertEqual(try h.saved().results["0:1"]?.rawText, h.raw)
        XCTAssertEqual(h.calls.filter { !$0.hasPrefix("GET") }, mutations)
    }
    @MainActor func testWrongManifestBindingAndOversizeRawRejectBeforePublication() async throws {
        for oversized in [false, true] {
            let h = try BatchHarness(); defer { h.close() }; try await h.audio()
            h.wrongDigest = !oversized; h.oversizedRaw = oversized
            h.model.transcribe(); try await h.wait()
            XCTAssertNotNil(h.model.error)
            XCTAssertTrue(try h.saved().results.isEmpty)
            if !oversized { XCTAssertNil(try h.saved().status); XCTAssertEqual(try h.saved().pending?.kind, "create") }
        }
    }
    @MainActor func testLostSealReconcilesAndUnknownRetryCannotRerun() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(); h.loseSeal = true
        h.model.transcribe(); try await h.wait()
        XCTAssertEqual(try h.saved().pending?.kind, "seal")
        h.model.refresh(); try await h.wait()
        XCTAssertEqual(try h.saved().status?.state, "complete")
        XCTAssertNil(try h.saved().pending)
        XCTAssertEqual(h.calls.filter { $0.hasSuffix("/seal") }.count, 1)
        h.slots[0] = "failed"; h.state = "failed"; h.revision += 1; h.aggregateState = "partial"
        h.loseRetry = true; h.unknownRetry = true
        h.model.retryBatch(index: 0); try await h.wait()
        h.model.retryBatch(index: 0); try await h.wait()
        XCTAssertEqual(h.nonces.count, 1)
        XCTAssertEqual(try h.saved().status?.chunks[0].state, "unknown")
        XCTAssertNotNil(h.model.error)
    }
    @MainActor func testSavedPartialSurvivesUnknownAndUnavailableAggregate() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(seconds: 301)
        h.sealStates = ["succeeded", "failed"]; h.aggregateState = "partial"
        h.model.transcribe(); try await h.wait()
        XCTAssertNil(h.model.error)
        let partial = try XCTUnwrap(h.saved().aggregate)
        XCTAssertEqual(partial.missingChunks, [1])
        XCTAssertEqual(partial.aggregate?.timed.first?.text, "Decision: keep originals.")
        h.slots[1] = "unknown"; h.state = "attention"; h.aggregateState = "pending"; h.revision += 1
        h.model.refresh(); try await h.wait()
        XCTAssertNil(h.model.error)
        let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
        XCTAssertEqual(model.batch(reopened.selected!)?.lastReadableAggregate, partial)
        XCTAssertEqual(model.batch(reopened.selected!)?.aggregate?.status, "pending")
        XCTAssertEqual(model.batch(reopened.selected!)?.results["0:1"]?.rawText, h.raw)
    }
    @MainActor func testSavedPartialViewRenders() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(seconds: 301)
        h.sealStates = ["succeeded", "failed"]; h.aggregateState = "partial"
        h.model.transcribe(); try await h.wait()
        let local = try h.saved()
        let view = NSHostingView(rootView: ScrollView { BatchTranscriptView(batch: local, cloud: h.model, enabled: true).padding(24) }.background(Color.white).environment(\.colorScheme, .light))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        if ProcessInfo.processInfo.environment["LESSMEET_BATCH_UI_SNAPSHOT"] == "1" {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try png.write(to: project.appendingPathComponent("Tests/fixtures/batch-native/ui-saved-partial.png"), options: .withoutOverwriting)
        }
    }
    @MainActor func testMissingRawTooLargePartialAndExplicitRetryNonceSurviveReopen() async throws {
        let h = try BatchHarness(); defer { h.close() }; try await h.audio(); h.aggregateState = "too_large"; h.missingRaw = true
        h.model.transcribe(); try await h.wait()
        XCTAssertNil(h.model.error)
        XCTAssertEqual(try h.saved().aggregate?.status, "too_large")
        XCTAssertTrue(try h.saved().results.isEmpty)
        XCTAssertNotNil(try h.saved().notice)
        h.missingRaw = false; h.aggregateState = "partial"; h.state = "partial"; h.slots[0] = "failed"; h.revision += 1
        h.model.refresh(); try await h.wait()
        XCTAssertEqual(try h.saved().aggregate?.missingChunks, [0])
        h.loseRetry = true
        h.model.retryBatch(index: 0); try await h.wait()
        let nonce = try XCTUnwrap(h.saved().pending?.requestId)
        let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
        model.retryBatch(index: 0); try await h.wait(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(h.nonces, [nonce, nonce])
        XCTAssertEqual(try h.saved().results["0:2"]?.rawText, h.raw)
        let callCount = h.calls.count
        model.retryBatch(index: 0); try await h.wait(model)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(h.calls.count, callCount + 1) // reconciliation only; no generation mutation
    }
    func testSubMillisecondRawAllowsOnlyUntimedAndRejectsBadProvenance() throws {
        let data = Data("{\"version\":1,\"source\":{\"sha256\":\"\(String(repeating: "a", count: 64))\",\"bytes\":1,\"duration\":{\"value\":1,\"timescale\":48000}},\"chunks\":[{\"sha256\":\"\(String(repeating: "b", count: 64))\",\"bytes\":1}]}".utf8)
        let manifest = try JSONDecoder().decode(BatchManifest.self, from: data)
        let timed = BatchRawResult(version: 1, batchId: "b", index: 0, attempt: 1, rawText: #"{"version":1,"segments":[{"startMs":0,"endMs":1,"speaker":null,"text":"x"}]}"#)
        XCTAssertThrowsError(try timed.validate(manifest: manifest))
        let untimed = BatchRawResult(version: 1, batchId: "b", index: 0, attempt: 1, rawText: #"{"version":1,"segments":[{"startMs":null,"endMs":null,"speaker":null,"text":"x"}]}"#)
        XCTAssertNoThrow(try untimed.validate(manifest: manifest))
        let bad = BatchAggregateResponse(version: 1, batchId: "b", revision: 1, status: "complete", missingChunks: [], aggregate: .init(version: 1, durationMs: 1, missingChunks: [], timed: [], untimed: [.init(chunkIndex: 0, segments: [.init(text: "x", source: .init(chunkIndex: 9, segmentIndex: 0, speaker: nil))])]))
        XCTAssertThrowsError(try bad.validate(manifest: manifest))
    }
    func testGenerateNativeBackendFixtureOptIn() async throws {
        guard ProcessInfo.processInfo.environment["LESSMEET_BATCH_NATIVE_FIXTURE"] == "1" else { throw XCTSkip("Opt-in tiny native AAC fixture generation") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("Tests/fixtures/batch-native")
        guard !FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("Fixture exists; never overwrite evidence") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("system.caf")
        try Self.writePCM(source, frames: 132301, rate: 44100)
        _ = try await CapturedAudio(directory: root, tracks: [.init(source: .system, url: source, start: .zero, duration: CMTime(value: 132301, timescale: 44100))], warning: "").exportCombined()
        let native = try await TranscriptionChunks.prepare(source: root.appendingPathComponent("combined.m4a"), destination: root.appendingPathComponent("chunks"))
        let wire = try BatchManifest(prepared: native)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(wire).write(to: root.appendingPathComponent("wire-manifest.json"), options: .withoutOverwriting)
        struct Evidence: Encodable { let manifestDigest: String; let canonicalJSON: String; let description: String }
        try encoder.encode(Evidence(manifestDigest: wire.digest, canonicalJSON: wire.canonical, description: "Synthetic 440Hz mono tone; 132301/44100 seconds. Native chunk metadata/checksum/requested rational range in chunks/manifest.json. No server decoder claim.")).write(to: root.appendingPathComponent("evidence.json"), options: .withoutOverwriting)
        print("BATCH_NATIVE_FIXTURE digest=\(try wire.digest) source=\(wire.source.sha256) chunks=\(wire.chunks)")
    }
}
