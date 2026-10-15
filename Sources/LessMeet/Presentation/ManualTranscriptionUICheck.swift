import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

@MainActor
struct ManualUICheckControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var transcription: LocalTranscriptionModel
    let capture: ManualUICheckCapture
    let reopen: () -> Void

    var body: some View {
        HStack {
            Text("Offline manual-start check — generated audio, synthetic transcript")
            Button("Simulate sleep interruption") { capture.interrupt() }
                .disabled(model.phase != .recording)
            Button("Reopen saved library", action: reopen)
                .disabled(model.phase != .idle || transcription.canCancel)
        }.padding(8)
    }
}

/// Synthetic inputs for the existing isolated Library fixture. No device or model inference.
@MainActor
enum ManualTranscriptionUICheck {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["LESSMEET_MANUAL_TRANSCRIPTION_UI_CHECK"] == "1"
    }
    static let interruptedID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!

    static func seed(_ store: RecordingStore) throws {
        let record = Recording(id: interruptedID, title: "Synthetic saved sleep interruption",
                               duration: 2, status: .interrupted,
                               failure: "The Mac is going to sleep. This recording was interrupted; start a new recording after waking.")
        try store.save(record)
        try writeAudio(store.audioURL(for: record.id))
        let corrupt = Recording(title: "Synthetic corrupt interrupted audio", status: .interrupted,
                                failure: "Synthetic interruption with invalid audio")
        try store.save(corrupt)
        try Data("not an audio container".utf8).write(to: store.audioURL(for: corrupt.id))
    }

    static func writeAudio(_ url: URL) throws {
        let writer = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 96_000),
              let samples = buffer.floatChannelData?[0] else { throw LibraryUICheckError.disabled }
        buffer.frameLength = 96_000
        for index in 0..<96_000 { samples[index] = Float(sin(Double(index) * 0.0576)) * 0.05 }
        try writer.write(from: buffer)
    }

    static func manager(root: URL) throws -> LocalModelManager {
        let payload = Data("synthetic models; decoder-only fixture".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let catalog = ["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"].map { id in
            LocalModelArtifact(id: id, name: id, repository: "test/models",
                revision: String(repeating: "a", count: 40), directory: id,
                files: [.init(path: id == "whisper-large-v3" ? "openai_whisper-large-v3/model.bin" : "model.bin",
                              bytes: Int64(payload.count), sha256: digest)])
        }
        for artifact in catalog {
            let file = root.appendingPathComponent(artifact.directory).appendingPathComponent(artifact.files[0].path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: file)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManualUICheckDenyNetwork.self]
        return LocalModelManager(root: root, catalog: catalog, configuration: config)
    }
}

@MainActor
final class ManualUICheckCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    func start(directory: URL) async throws {
        try ManualTranscriptionUICheck.writeAudio(directory.appendingPathComponent("combined.m4a"))
    }
    func stop() async throws -> CaptureResult { .init(duration: 2, warning: nil) }
    func interrupt() {
        onFailure?("The Mac is going to sleep. This recording was interrupted; start a new recording after waking.")
    }
}

struct ManualUICheckEngine: LocalTranscriptionProcessing {
    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript {
        let reader = try LocalPCMReader(url: audioURL)
        while !(try reader.read(maxSamples: 16_384)).isEmpty { try Task.checkCancellation() }
        return .init(segments: [.init(startMs: 0, endMs: Int64(reader.duration * 1000), speaker: nil,
                                     text: "Synthetic transcription after an explicit request. Audio decoding passed; no speech model ran.")])
    }
}

private final class ManualUICheckDenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
