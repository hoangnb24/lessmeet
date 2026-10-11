import Combine
import Foundation

/// Compile with the three LocalModels source files. Uses the production manager.
@main enum LocalModelDownloadCheck {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            throw CheckFailure("Usage: download-check /absolute/model-cache [cancel-after-bytes]")
        }
        let path = CommandLine.arguments[1]
        guard path.hasPrefix("/") else { throw CheckFailure("Use an absolute model-cache path.") }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let cancelAt = CommandLine.arguments.count > 2 ? Int64(CommandLine.arguments[2]) : nil
        if CommandLine.arguments.count > 2 && (cancelAt ?? 0) <= 0 {
            throw CheckFailure("Cancellation byte count must be positive.")
        }
        let manager = LocalModelManager(root: root)
        var bucket: Int64 = -1
        var cancelled = false
        let receipt = manager.$completedBytes.sink { bytes in
            let nextBucket = bytes / 50_000_000
            if nextBucket != bucket {
                bucket = nextBucket
                print("bytes=\(bytes) total=\(manager.totalBytes) state=\(manager.state.rawValue)")
                fflush(stdout)
            }
            if let cancelAt, bytes >= cancelAt, !cancelled, manager.state == .downloading {
                cancelled = true
                manager.cancel()
            }
        }
        let started = Date()
        await manager.startup()
        withExtendedLifetime(receipt) {}
        print("final=\(manager.state.rawValue) bytes=\(manager.completedBytes) elapsedSeconds=\(Date().timeIntervalSince(started))")
        if cancelled {
            guard manager.state == .cancelled else { throw CheckFailure("Cancellation did not finish.") }
        } else {
            guard manager.state == .ready, manager.installed != nil else {
                throw CheckFailure(manager.error ?? "The manager did not reach ready.")
            }
        }
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
