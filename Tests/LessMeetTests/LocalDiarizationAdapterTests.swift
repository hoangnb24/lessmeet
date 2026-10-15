import AVFoundation
import AudioCommon
import SpeechVAD
import XCTest
#if !LOCAL_DIARIZATION_STANDALONE
@testable import LessMeet
#endif

final class LocalDiarizationAdapterTests: XCTestCase {
    private var root: URL!

    private enum ProbeError: Error { case start, push, finish }

    private final class Session: LocalDiarizationSession {
        var pushes = 0
        var samples = 0
        var finishes = 0
        var result = DiarizationResult(segments: [], numSpeakers: 0, speakerEmbeddings: [])
        var onPush: (() throws -> Void)?
        var onFinish: (() throws -> Void)?
        var checkSequence = false

        func push(audio: [Float]) throws -> DiarizationResult {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertGreaterThan(audio.count, 0)
            XCTAssertLessThanOrEqual(audio.count, 16_384)
            if checkSequence {
                for (index, sample) in audio.enumerated() {
                    XCTAssertEqual(sample, Float((samples + index) % 127) / 128)
                }
            }
            pushes += 1
            samples += audio.count
            try onPush?()
            // Deliberately conflicts with the final ID. This must never reach output.
            return DiarizationResult(segments: [.init(startTime: 0, endTime: 1, speakerId: 0)],
                                     numSpeakers: 1, speakerEmbeddings: [])
        }

        func finish() throws -> DiarizationResult {
            XCTAssertFalse(Thread.isMainThread)
            finishes += 1
            try onFinish?()
            return result
        }
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDiarization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func run(_ body: @escaping () async throws -> Void) {
        let done = expectation(description: "adapter result")
        Task {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    private func audio(frames: Int = 32_000, nonfinite: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 1, interleaved: false))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var offset = 0
        while offset < frames {
            let count = min(4_096, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer.floatChannelData![0][index] = nonfinite ? .nan : Float((offset + index) % 127) / 128
            }
            try writer.write(from: buffer)
            offset += count
        }
        return url
    }

    func testOneContinuousSessionPast300SecondsAndFinalGlobalLabels() throws {
        let url = try audio(frames: 301 * 16_000 + 7)
        run {
            let session = Session()
            session.checkSequence = true
            session.result = DiarizationResult(segments: [
                .init(startTime: 0, endTime: 1, speakerId: 7),
                .init(startTime: 299, endTime: 302, speakerId: 0),
                .init(startTime: 10, endTime: 11, speakerId: 7)
            ], numSpeakers: 2, speakerEmbeddings: [])
            var starts = 0
            let adapter = LocalDiarizationAdapter { core, right in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(core, 340)
                XCTAssertEqual(right, 40)
                starts += 1
                return session
            }
            let progress = Progress()
            let result = try await adapter.diarize(audioURL: url) { progress.append($0) }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(session.finishes, 1)
            XCTAssertEqual(session.samples, 301 * 16_000 + 7)
            XCTAssertEqual(session.pushes, (session.samples + 16_383) / 16_384)
            XCTAssertEqual(result.map(\.speaker), ["Speaker8", "Speaker1", "Speaker8"])
            XCTAssertEqual(result.map(\.startMs), [0, 299_000, 10_000])
            XCTAssertEqual(result.map(\.endMs), [1_000, 301_000, 11_000])
            let values = progress.values
            XCTAssertEqual(values.first, 0)
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(values.count, session.pushes + 2)
            XCTAssertEqual(values[1], 16_384.0 / Double(session.samples), accuracy: 1e-12)
            XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
            print("301-second stream: starts=\(starts), finishes=\(session.finishes), pushes=\(session.pushes), samples=\(session.samples)")
        }
    }

    func testFreshSessionForEachRecordingAndNoForcedSilenceLabels() throws {
        let url = try audio()
        run {
            var sessions: [Session] = []
            let adapter = LocalDiarizationAdapter { _, _ in
                let session = Session()
                sessions.append(session)
                return session
            }
            for _ in 0..<2 {
                let result = try await adapter.diarize(audioURL: url) { _ in }
                XCTAssertTrue(result.isEmpty)
            }
            XCTAssertEqual(sessions.count, 2)
            XCTAssertFalse(sessions[0] === sessions[1])
            XCTAssertEqual(sessions.map(\.finishes), [1, 1])
            XCTAssertEqual(sessions.map(\.samples), [32_000, 32_000])
        }
    }

    func testCancellationBetweenBlocksDoesNotFinish() throws {
        let url = try audio()
        run {
            let session = Session()
            session.onPush = { withUnsafeCurrentTask { $0?.cancel() } }
            let adapter = LocalDiarizationAdapter { _, _ in session }
            do {
                _ = try await adapter.diarize(audioURL: url) { _ in }
                XCTFail("Canceled stream returned results")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(session.pushes, 1)
            XCTAssertEqual(session.finishes, 0)
        }
    }

    func testCancellationAfterFinishDiscardsResults() throws {
        let url = try audio()
        run {
            let session = Session()
            session.onFinish = { withUnsafeCurrentTask { $0?.cancel() } }
            let adapter = LocalDiarizationAdapter { _, _ in session }
            do {
                _ = try await adapter.diarize(audioURL: url) { _ in }
                XCTFail("Canceled final result escaped")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(session.finishes, 1)
        }
    }

    func testAlreadyCanceledDoesNotStartSession() throws {
        let url = try audio()
        run {
            let adapter = LocalDiarizationAdapter { _, _ in XCTFail("Started canceled stream"); return Session() }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await adapter.diarize(audioURL: url) { _ in XCTFail("Reported progress") }
                XCTFail("Ignored cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testSessionErrorsPropagate() throws {
        let url = try audio()
        run {
            for expected in [ProbeError.start, .push, .finish] {
                let session = Session()
                if expected == .push { session.onPush = { throw ProbeError.push } }
                if expected == .finish { session.onFinish = { throw ProbeError.finish } }
                let adapter = LocalDiarizationAdapter { _, _ in
                    if expected == .start { throw ProbeError.start }
                    return session
                }
                do {
                    _ = try await adapter.diarize(audioURL: url) { _ in }
                    XCTFail("Swallowed \(expected)")
                } catch { XCTAssertEqual(error as? ProbeError, expected) }
                XCTAssertEqual(session.finishes, expected == .finish ? 1 : 0)
            }
        }
    }

    func testInvalidFinalIntervalsFailClosed() throws {
        let url = try audio()
        run {
            let invalid: [DiarizedSegment] = [
                .init(startTime: .nan, endTime: 1, speakerId: 0),
                .init(startTime: 0, endTime: .infinity, speakerId: 0),
                .init(startTime: -1, endTime: 1, speakerId: 0),
                .init(startTime: 1, endTime: 1, speakerId: 0),
                .init(startTime: 2, endTime: 1, speakerId: 0),
                .init(startTime: 0, endTime: 7_201, speakerId: 0),
                .init(startTime: 0, endTime: 1, speakerId: -1),
                .init(startTime: 0, endTime: 1, speakerId: 8)
            ]
            for segment in invalid {
                let session = Session()
                session.result = DiarizationResult(segments: [segment], numSpeakers: 1, speakerEmbeddings: [])
                let adapter = LocalDiarizationAdapter { _, _ in session }
                do {
                    _ = try await adapter.diarize(audioURL: url) { _ in }
                    XCTFail("Accepted invalid interval")
                } catch { XCTAssertTrue(error is LocalDiarizationAdapter.Failure) }
            }
            for count in [-1, 1, 9] {
                let session = Session()
                session.result = DiarizationResult(segments: [], numSpeakers: count, speakerEmbeddings: [])
                let adapter = LocalDiarizationAdapter { _, _ in session }
                do {
                    _ = try await adapter.diarize(audioURL: url) { _ in }
                    XCTFail("Accepted invalid count")
                } catch { XCTAssertTrue(error is LocalDiarizationAdapter.Failure) }
            }
        }
    }

    func testClampsTailAndDropsEmptyIntervalsWithoutRenumbering() throws {
        let url = try audio(frames: 16_007)
        run {
            let session = Session()
            session.result = DiarizationResult(segments: [
                .init(startTime: 0.25, endTime: 2, speakerId: 5),
                .init(startTime: 2, endTime: 3, speakerId: 0),
                .init(startTime: 0.00001, endTime: 0.00002, speakerId: 1)
            ], numSpeakers: 3, speakerEmbeddings: [])
            let adapter = LocalDiarizationAdapter { _, _ in session }
            let result = try await adapter.diarize(audioURL: url) { _ in }
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.speaker, "Speaker6")
            XCTAssertEqual(result.first?.startMs, 250)
            XCTAssertEqual(result.first?.endMs, 1_000)
        }
    }

    func testMissingAndNonlocalModelDirectoriesFailWithoutLoading() throws {
        for url in [root.appendingPathComponent("missing"), URL(string: "https://invalid.test/model")!, try audio()] {
            XCTAssertThrowsError(try LocalDiarizationAdapter(modelDirectory: url)) {
                XCTAssertTrue($0 is LocalDiarizationAdapter.Failure)
            }
        }
    }

    func testEmptyLocalModelDirectoryPropagatesLoaderFailure() throws {
        let url = try audio()
        let adapter = try LocalDiarizationAdapter(modelDirectory: root)
        run {
            do {
                _ = try await adapter.diarize(audioURL: url) { _ in XCTFail("Loaded absent model") }
                XCTFail("Loaded empty directory")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("missing"), "\(error)")
            }
        }
    }

    func testReaderRejectsMalformedSourcesAndNonfiniteSamples() throws {
        let malformed = root.appendingPathComponent("malformed.wav")
        try Data("not audio".utf8).write(to: malformed)
        let badSamples = try audio(nonfinite: true)
        run {
            for url in [malformed, badSamples] {
                let session = Session()
                let adapter = LocalDiarizationAdapter { _, _ in session }
                do {
                    _ = try await adapter.diarize(audioURL: url) { _ in }
                    XCTFail("Accepted invalid audio")
                } catch { XCTAssertTrue(error is LocalPCMReader.Failure) }
                XCTAssertEqual(session.pushes, 0)
                XCTAssertEqual(session.finishes, 0)
            }
        }
    }

    func testReaderRejectsOverTwoHoursBeforeSessionStarts() throws {
        let url = root.appendingPathComponent("over-limit.wav")
        let dataBytes = UInt32(7_201 * 16_000 * 2)
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(dataBytes + 36); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(dataBytes)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(dataBytes) + 44)
        try handle.close()
        run {
            let adapter = LocalDiarizationAdapter { _, _ in XCTFail("Started over-limit source"); return Session() }
            do {
                _ = try await adapter.diarize(audioURL: url) { _ in }
                XCTFail("Accepted over-limit source")
            } catch { XCTAssertTrue(error is LocalPCMReader.Failure) }
        }
    }
}

#if LOCAL_DIARIZATION_STANDALONE
@main
enum LocalDiarizationTestRunner {
    static func main() {
        let suite = LocalDiarizationAdapterTests.defaultTestSuite
        suite.run()
        guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
        exit(run.hasSucceeded ? 0 : 1)
    }
}
#endif
