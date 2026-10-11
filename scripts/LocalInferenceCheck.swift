import Foundation

@main enum LocalInferenceCheck {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("Local inference check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments.dropFirst().allSatisfy({ $0.hasPrefix("/") }) else {
            throw CheckFailure("Usage: inference-check /model-cache /fixture.wav /new-output.json")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CheckFailure("Output already exists; choose a new evidence path.")
        }
        let manager = LocalModelManager(root: root)
        await manager.prepare()
        guard let models = manager.installed else {
            throw CheckFailure(manager.error ?? "The pinned models are not ready. No download was attempted.")
        }
        let started = Date()
        let transcript = try await LocalTranscriptionEngine().transcribe(audioURL: audio, models: models) { update in
            print(String(format: "progress=%.3f %@", update.fraction, update.message))
            fflush(stdout)
        }
        try transcript.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript)
        try data.write(to: output, options: .withoutOverwriting)
        let reopened = try JSONDecoder().decode(LocalTranscript.self, from: Data(contentsOf: output))
        guard reopened == transcript else { throw CheckFailure("Transcript JSON did not round-trip.") }
        print("PASS elapsedSeconds=\(Date().timeIntervalSince(started)) segments=\(transcript.segments.count) speakers=\(Set(transcript.segments.compactMap(\.speaker)).count) bytes=\(data.count)")
    }

    private struct CheckFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
