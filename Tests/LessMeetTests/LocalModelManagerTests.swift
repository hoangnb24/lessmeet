import Foundation
import CryptoKit
import Combine
import Darwin
import XCTest
@testable import LessMeet

private final class ModelMockProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data]
        var finish = true
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }
    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let reply = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if reply.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class LocalModelManagerTests: XCTestCase {
    private static let payload = Data(repeating: 97, count: 65_536)

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        let done = expectation(description: "async manager scenario")
        Task { @MainActor in
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
    }

    private func root() throws -> URL {
        // Foundation can shorten /private/var back to the /var symlink.
        // Use the physical POSIX path so the confinement test does not bypass it.
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("LessMeet-model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func catalog(path: String = "openai_whisper-large-v3/nested/model.bin",
                         hash: String? = nil, bytes: Int64? = nil) -> [LocalModelArtifact] {
        let sha = hash ?? SHA256.hash(data: Self.payload).map { String(format: "%02x", $0) }.joined()
        return ["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"].enumerated().map { index, id in
            LocalModelArtifact(id: id, name: id, repository: "test/models", revision: String(repeating: "a", count: 40),
                               directory: id, files: [LocalModelFile(path: index == 0 ? path : "model.bin",
                                                                    bytes: bytes ?? Int64(Self.payload.count), sha256: sha)])
        }
    }

    @MainActor private func manager(_ root: URL, _ catalog: [LocalModelArtifact]? = nil) -> LocalModelManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelMockProtocol.self]
        return LocalModelManager(root: root, catalog: catalog ?? self.catalog(), configuration: config)
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Manager did not reach the expected state")
    }

    func testPassivePrepareStartupOnceAndOfflineReady() {
        run {
            let root = try self.root()
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload]) }
            let manager = self.manager(root)
            await manager.prepare()
            await manager.prepare()
            XCTAssertEqual(manager.state, .missing)
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
            await manager.startup()
            XCTAssertEqual(manager.state, .ready)
            XCTAssertEqual(ModelMockProtocol.seen.count, 3)
            XCTAssertEqual(manager.completedBytes, manager.totalBytes)
            XCTAssertEqual(manager.installed?.whisperDirectory,
                           root.appendingPathComponent("whisper-large-v3/openai_whisper-large-v3"))
            await manager.startup()
            await manager.start()
            XCTAssertEqual(ModelMockProtocol.seen.count, 3)
            ModelMockProtocol.reset { _ in XCTFail("Ready models must not use network"); return .init(chunks: []) }
            let reopened = self.manager(root)
            await reopened.startup()
            await reopened.start()
            XCTAssertEqual(reopened.state, .ready)
            XCTAssertEqual(reopened.installed, manager.installed)
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
        }
    }

    func testProgressCancelResumeAcrossRecreationAndDoubleInvocation() {
        run {
            let root = try self.root()
            let cut = 32_768
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload.prefix(cut)], finish: false) }
            let manager = self.manager(root)
            let first = Task { await manager.startup() }
            let second = Task { await manager.startup() }
            try await self.settle { manager.completedBytes == cut }
            XCTAssertEqual(manager.state, .downloading)
            XCTAssertNotNil(manager.currentFile)
            XCTAssertNil(manager.installed)
            let duplicate = Task { await manager.start() }
            manager.cancel()
            await first.value; await second.value; await duplicate.value
            XCTAssertEqual(manager.state, .cancelled)
            await manager.startup()
            await manager.start()
            XCTAssertEqual(ModelMockProtocol.seen.count, 1)
            XCTAssertNil(manager.installed)
            ModelMockProtocol.reset { request in
                if request.value(forHTTPHeaderField: "Range") != nil {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=32768-")
                    return .init(status: 206, headers: ["Content-Range": "bytes 32768-65535/65536", "Content-Length": "32768"],
                                 chunks: [Self.payload.suffix(from: cut)])
                }
                return .init(chunks: [Self.payload])
            }
            let reopened = self.manager(root)
            await reopened.startup()
            XCTAssertEqual(reopened.state, .ready, reopened.error ?? "")
            XCTAssertEqual(ModelMockProtocol.seen.count, 3)
            XCTAssertEqual(ModelMockProtocol.seen.first?.value(forHTTPHeaderField: "Range"), "bytes=32768-")
        }
    }

    func testIgnoredRangeRestartsWithoutAppending() {
        run {
            let root = try self.root()
            let catalog = self.catalog()
            let partial = root.appendingPathComponent(".partial")
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            try Self.payload.prefix(5).write(to: partial.appendingPathComponent(catalog[0].files[0].sha256 + ".part"))
            ModelMockProtocol.reset { _ in .init(headers: ["Content-Length": "65536"], chunks: [Self.payload]) }
            let manager = self.manager(root)
            await manager.start()
            XCTAssertEqual(manager.state, .ready, manager.error ?? "")
            XCTAssertEqual(ModelMockProtocol.seen.first?.value(forHTTPHeaderField: "Range"), "bytes=5-")
            let bytes = try Data(contentsOf: root.appendingPathComponent("whisper-large-v3/" + catalog[0].files[0].path))
            XCTAssertEqual(bytes, Self.payload)
        }
    }

    func testFailureDoesNotAutoRetryAndExplicitRetryCleansBadHash() {
        run {
            let root = try self.root()
            ModelMockProtocol.reset { _ in .init(chunks: [Data(repeating: 120, count: Self.payload.count)]) }
            let manager = self.manager(root)
            await manager.startup()
            XCTAssertEqual(manager.state, .failed)
            XCTAssertTrue(manager.error?.contains("Integrity") == true)
            XCTAssertNil(manager.installed)
            await manager.startup(); await manager.prepare(); await manager.start()
            XCTAssertEqual(ModelMockProtocol.seen.count, 1)
            ModelMockProtocol.reset { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
                return .init(chunks: [Self.payload])
            }
            manager.retry()
            try await self.settle { manager.state == .ready }
            XCTAssertNotNil(manager.installed)
        }
    }

    func testTruncatedOversizedAndInvalidResponsesNeverReady() {
        run {
            let replies: [ModelMockProtocol.Reply] = [
                .init(chunks: [Self.payload.prefix(3)]),
                .init(chunks: [Self.payload + Data([1])]),
                .init(headers: ["Content-Length": "25"], chunks: [Self.payload]),
                .init(status: 206, headers: ["Content-Range": "bytes 1-23/24"], chunks: [Self.payload]),
                .init(status: 206, headers: [:], chunks: [Self.payload]),
                .init(status: 416, chunks: []),
                .init(status: 401, chunks: []),
                .init(headers: ["Content-Encoding": "gzip"], chunks: [Self.payload])
            ]
            for reply in replies {
                let root = try self.root()
                ModelMockProtocol.reset { _ in reply }
                let manager = self.manager(root)
                await manager.startup()
                XCTAssertEqual(manager.state, .failed)
                XCTAssertNil(manager.installed)
                XCTAssertNotNil(manager.error)
                let reopened = self.manager(root)
                await reopened.prepare()
                XCTAssertNil(reopened.installed)
                XCTAssertEqual(ModelMockProtocol.seen.count, 1)
            }
        }
    }

    func testInvalidCatalogAndSymlinksFailBeforeNetwork() {
        run {
            ModelMockProtocol.reset { _ in XCTFail("Unsafe input reached network"); return .init(chunks: []) }
            for catalog in [self.catalog(path: "../escape"), self.catalog(hash: "no hash"), self.catalog(bytes: -1), []] {
                let manager = self.manager(try self.root(), catalog)
                await manager.startup()
                XCTAssertEqual(manager.state, .failed)
                XCTAssertNil(manager.installed)
            }
            for component in ["whisper-large-v3", ".partial", ".download-lock"] {
                let root = try self.root()
                let outside = try self.root()
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(component), withDestinationURL: outside)
                let manager = self.manager(root)
                await manager.startup()
                XCTAssertEqual(manager.state, .failed)
                XCTAssertNil(manager.installed)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            }
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
        }
    }

    func testCancelThenImmediateRetryHasOneWriterAndNoLateReady() {
        run {
            let root = try self.root()
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload.prefix(32_768)], finish: false) }
            let manager = self.manager(root)
            let first = Task { await manager.start() }
            try await self.settle { manager.completedBytes == 32_768 }
            manager.cancel()
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload]) }
            manager.retry()
            manager.retry()
            await first.value
            try await self.settle { manager.state == .ready }
            XCTAssertEqual(ModelMockProtocol.seen.count, 3)
            XCTAssertEqual(manager.completedBytes, manager.totalBytes)
        }
    }

    func testSeparateManagersCannotWriteSameRootAndUnrelatedFilesSurvive() {
        run {
            let root = try self.root()
            let unrelated = root.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: unrelated)
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload.prefix(32_768)], finish: false) }
            let first = self.manager(root)
            let active = Task { await first.start() }
            try await self.settle { first.completedBytes == 32_768 }
            let second = self.manager(root)
            await second.start()
            XCTAssertEqual(second.state, .failed)
            XCTAssertTrue(second.error?.contains("Another") == true)
            XCTAssertEqual(ModelMockProtocol.seen.count, 1)
            first.cancel()
            await active.value
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        }
    }

    func testCancelledBeforeStartupStaysPausedUntilUserRetry() {
        run {
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload]) }
            let manager = self.manager(try self.root())
            manager.cancel()
            await manager.startup()
            await manager.startup()
            await manager.prepare()
            XCTAssertEqual(manager.state, .cancelled)
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
            manager.retry()
            try await self.settle { manager.state == .ready }
            XCTAssertEqual(ModelMockProtocol.seen.count, 3)
        }
    }

    func testCorruptInstalledFileIsNotReadyAndValidFilesAreReused() {
        run {
            let root = try self.root()
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload]) }
            await self.manager(root).start()
            let broken = root.appendingPathComponent("whisper-tokenizer/model.bin")
            try Data(repeating: 98, count: Self.payload.count).write(to: broken)
            ModelMockProtocol.reset { _ in .init(chunks: [Self.payload]) }
            let reopened = self.manager(root)
            await reopened.prepare()
            XCTAssertEqual(reopened.state, .missing)
            XCTAssertNil(reopened.installed)
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
            await reopened.start()
            XCTAssertEqual(reopened.state, .ready)
            XCTAssertEqual(ModelMockProtocol.seen.count, 1)
            XCTAssertEqual(try Data(contentsOf: broken), Self.payload)
        }
    }

    func testFullPartialIsHashedBeforePromotionAndOversizedPartialRestarts() {
        run {
            for data in [Self.payload, Self.payload + Data([0])] {
                let root = try self.root()
                let partial = root.appendingPathComponent(".partial")
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
                try data.write(to: partial.appendingPathComponent(self.catalog()[0].files[0].sha256 + ".part"))
                ModelMockProtocol.reset { request in
                    XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
                    return .init(chunks: [Self.payload])
                }
                let manager = self.manager(root)
                await manager.start()
                XCTAssertEqual(manager.state, .ready)
                XCTAssertEqual(ModelMockProtocol.seen.count, data == Self.payload ? 2 : 3)
            }
        }
    }

    func testLeafLinksAndRootSymlinkNeverTouchOutsideBytes() {
        run {
            ModelMockProtocol.reset { _ in XCTFail("Link reached network"); return .init(chunks: []) }
            for hardLink in [false, true] {
                let root = try self.root()
                let outside = try self.root().appendingPathComponent("untouched")
                try Self.payload.write(to: outside)
                let partial = root.appendingPathComponent(".partial")
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
                let target = partial.appendingPathComponent(self.catalog()[0].files[0].sha256 + ".part")
                if hardLink { try FileManager.default.linkItem(at: outside, to: target) }
                else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
                let manager = self.manager(root)
                await manager.startup()
                XCTAssertEqual(manager.state, .failed)
                XCTAssertNil(manager.installed)
                XCTAssertEqual(try Data(contentsOf: outside), Self.payload)
            }
            let base = try self.root()
            let outside = try self.root()
            let linkedRoot = base.appendingPathComponent("linked-model-root")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
            let manager = self.manager(linkedRoot)
            await manager.startup()
            XCTAssertEqual(manager.state, .failed)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
        }
    }

    func testMalformedMetadataRejectsAliasesOverflowAndMutableRevision() {
        run {
            let original = self.catalog()
            let artifact = original[0]
            let file = artifact.files[0]
            func changed(repository: String? = nil, revision: String? = nil, directory: String? = nil,
                         files: [LocalModelFile]? = nil) -> [LocalModelArtifact] {
                [LocalModelArtifact(id: artifact.id, name: artifact.name,
                                    repository: repository ?? artifact.repository,
                                    revision: revision ?? artifact.revision,
                                    directory: directory ?? artifact.directory, files: files ?? artifact.files)] + original.dropFirst()
            }
            let invalid = [
                changed(repository: "test/models?token=bad"), changed(revision: "main"),
                changed(directory: ".partial"), changed(files: [file, file]),
                changed(files: [file, LocalModelFile(path: file.path.uppercased(), bytes: file.bytes, sha256: file.sha256)]),
                changed(files: [file, LocalModelFile(path: file.path + "/child", bytes: file.bytes, sha256: file.sha256)]),
                changed(files: [LocalModelFile(path: file.path, bytes: Int64.max, sha256: file.sha256)])
            ]
            ModelMockProtocol.reset { _ in XCTFail("Invalid catalog reached network"); return .init(chunks: []) }
            for catalog in invalid {
                let manager = self.manager(try self.root(), catalog)
                await manager.startup()
                XCTAssertEqual(manager.state, .failed)
                XCTAssertNil(manager.installed)
            }
            XCTAssertTrue(ModelMockProtocol.seen.isEmpty)
        }
    }
}
