import Foundation
import XCTest
@testable import LessMeet

final class LocalModelManifestTests: XCTestCase {
    func testImmutablePinsAndHashes() {
        for artifact in LocalModelCatalog.artifacts {
            XCTAssertNotNil(artifact.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
            XCTAssertEqual(artifact.repository.split(separator: "/").count, 2)
            for file in artifact.files {
                XCTAssertGreaterThan(file.bytes, 0)
                XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            }
        }
    }

    func testSafeUniquePaths() {
        let artifacts = LocalModelCatalog.artifacts
        XCTAssertEqual(Set(artifacts.map(\.id)).count, artifacts.count)
        XCTAssertEqual(Set(artifacts.map(\.directory)).count, artifacts.count)
        for artifact in artifacts {
            XCTAssertTrue(isSafe(artifact.directory))
            XCTAssertFalse(artifact.directory.contains("/"))
            XCTAssertTrue(isSafe(artifact.repository))
            XCTAssertEqual(Set(artifact.files.map(\.path)).count, artifact.files.count)
            for file in artifact.files { XCTAssertTrue(isSafe(file.path), file.path) }
        }
        for unsafe in ["", "/a", "../a", "a/../b", "./a", "a//b", "a/", "a\\b", "a%2fb", "a?b", "a#b"] {
            XCTAssertFalse(isSafe(unsafe), unsafe)
        }
    }

    func testExactSizesAndCounts() {
        XCTAssertEqual(LocalModelCatalog.artifacts.map(\.id), ["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"])
        XCTAssertEqual(LocalModelCatalog.artifacts.map { $0.files.count }, [19, 3, 14])
        XCTAssertEqual(LocalModelCatalog.artifacts.map(\.totalBytes), [3_090_319_899, 2_764_732, 107_083_235])
        XCTAssertEqual(LocalModelCatalog.artifacts.reduce(Int64(0)) { $0 + $1.totalBytes }, 3_200_167_866)
    }

    func testWhisperIsFullLargeV3NotTurbo() throws {
        let model = try XCTUnwrap(LocalModelCatalog.artifacts.first)
        XCTAssertEqual(model.repository, "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(model.revision, "0f63a7800b00dd0226abd051b906c246e1907482")
        XCTAssertTrue(model.files.allSatisfy { $0.path.hasPrefix("openai_whisper-large-v3/") })
        XCTAssertFalse(model.files.contains { $0.path.lowercased().contains("turbo") })
        let bundles = Set(model.files.compactMap { file -> String? in
            let components = file.path.split(separator: "/")
            return components.count > 2 ? String(components[1]) : nil
        })
        XCTAssertEqual(bundles, ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"])
    }

    func testTokenizerSelection() throws {
        let model = try XCTUnwrap(LocalModelCatalog.artifacts.first { $0.id == "whisper-tokenizer" })
        XCTAssertEqual(model.repository, "openai/whisper-large-v3")
        XCTAssertEqual(model.revision, "06f233fe06e710322aca913c1bc4249a0d71fce1")
        XCTAssertEqual(Set(model.files.map(\.path)), ["tokenizer.json", "tokenizer_config.json", "config.json"])
    }

    func testNemotronIncludesBothBundlesAndNotices() throws {
        let model = try XCTUnwrap(LocalModelCatalog.artifacts.first { $0.id == "nemotron3-int8" })
        XCTAssertEqual(model.repository, "aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8")
        XCTAssertEqual(model.revision, "db823d36c2230d5535a6165c932f8a5369484b7a")
        XCTAssertEqual(Set(model.files.filter { !$0.path.contains("/") }.map(\.path)),
                       ["learnable_silence.f32", "config.json", "LICENSE", "NOTICE"])
        for bundle in ["Nemotron3Head.mlmodelc", "Nemotron3PreEncoder.mlmodelc"] {
            XCTAssertEqual(model.files.filter { $0.path.hasPrefix(bundle + "/") }.count, 5)
        }
    }

    private func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
        }
    }
}
