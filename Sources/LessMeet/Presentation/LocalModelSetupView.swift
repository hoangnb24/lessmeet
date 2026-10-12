import SwiftUI

struct LocalModelSetupView: View {
    @ObservedObject var manager: LocalModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up on-device transcription").font(.title2.bold())
            Text("LessMeet downloads pinned Whisper large-v3 and Nemotron diarization models. After setup, these models stay on this Mac.")
            Text("\(manager.fileCount) files · \(manager.totalBytes.formatted()) bytes (\(ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .decimal)))")
                .font(.headline)
            Text("Allow extra disk space for partial downloads and model caches. Downloads start once when the app opens. Cancel keeps partial files for Resume.")
                .font(.callout).foregroundStyle(.secondary)

            Text(status).font(.headline)
            ProgressView(value: manager.progress)
                .accessibilityLabel("Model download progress")
            Text("\(ByteCountFormatter.string(fromByteCount: manager.completedBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .decimal)) verified or transferred")
                .font(.caption).monospacedDigit()
            if let file = manager.currentFile {
                Text(file).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if let error = manager.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                switch manager.state {
                case .checking, .downloading:
                    Button("Cancel") { manager.cancel() }
                case .cancelling:
                    Button("Cancelling…") {}.disabled(true)
                case .cancelled:
                    Button("Resume") { manager.retry() }
                case .failed:
                    Button("Retry") { manager.retry() }
                case .idle, .missing:
                    Button("Download models") { Task { await manager.start() } }
                case .ready:
                    Label("All model files verified", systemImage: "checkmark.circle")
                }
            }
            Divider()
            Text("Sources and licenses").font(.headline)
            Text("Whisper: OpenAI weights and Argmax Core ML conversion (MIT). Nemotron: NVIDIA source weights (OpenMDW-1.1), with community INT8 Core ML files from aufklarer. These are not NVIDIA-official binaries. The Nemotron LICENSE and NOTICE are included in the download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560)
        .task { await manager.startup() }
    }

    private var status: String {
        switch manager.state {
        case .idle: return "Waiting to check model files"
        case .checking: return "Checking model integrity…"
        case .missing: return "Model download required"
        case .downloading: return "Downloading and verifying models…"
        case .cancelling: return "Stopping download…"
        case .cancelled: return "Download paused"
        case .failed: return "Model setup needs attention"
        case .ready: return "Models ready for local transcription"
        }
    }
}
