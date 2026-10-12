import SwiftUI

struct LocalTranscriptView: View {
    @ObservedObject var model: LocalTranscriptionModel
    let recordingID: UUID

    var body: some View {
        LocalTranscriptContent(model: model, recordingID: recordingID)
            .id(recordingID)
    }
}

private struct LocalTranscriptContent: View {
    @ObservedObject var model: LocalTranscriptionModel
    let recordingID: UUID
    @State private var saved: SavedTranscript = .loading

    private enum SavedTranscript {
        case loading, missing, loaded(LocalTranscript), failed(String)
    }

    private var state: LocalTranscriptionModel.RecordingState { model.state(for: recordingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local transcript").font(.headline)
                Spacer()
                Button("Transcribe on this Mac") { model.transcribe(recordingID: recordingID) }
                    .disabled(state.isPending)
                if model.canCancel {
                    Button("Cancel all transcription") { model.cancel() }
                }
            }
            status
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    savedContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle:
            Text("Transcription runs locally. Audio stays on this Mac.").foregroundStyle(.secondary)
        case .queued:
            switch model.activity {
            case .waitingForModels(let message): Text(message)
            case .draining: Text("Queued. Waiting for cancelled model work to stop…")
            default: Text("Queued behind another recording…")
            }
        case .running(let progress):
            Text(progress.message)
            ProgressView(value: progress.fraction).accessibilityLabel("Local transcription progress")
        case .completed:
            Label("Transcript saved on this Mac", systemImage: "checkmark.circle")
        case .cancelled:
            Text("Transcription cancelled. Saved output was not changed.")
            if model.activity == .draining { Text("Waiting for model work to stop…").foregroundStyle(.secondary) }
        case .failed(let message):
            Text("Transcription failed: \(message)").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    @ViewBuilder private var savedContent: some View {
        switch saved {
        case .loading:
            Text("Reading saved transcript…").foregroundStyle(.secondary)
        case .missing:
            Text("No local transcript saved yet.").foregroundStyle(.secondary)
        case .failed(let message):
            Text("Could not read the saved local transcript: \(message)").foregroundStyle(.red)
        case .loaded(let transcript):
            if state.showsPreviousTranscript {
                Text("Previous transcript · unchanged").font(.subheadline.bold()).foregroundStyle(.secondary)
            }
            if transcript.segments.isEmpty {
                Text("No recognized speech in this saved transcript.").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(segment.speaker ?? "Unknown speaker").fontWeight(.semibold)
                                Text(timing(segment)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.caption)
                            Text(segment.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        do {
            saved = try model.loadTranscript(recordingID: recordingID).map(SavedTranscript.loaded) ?? .missing
        } catch { saved = .failed(error.localizedDescription) }
    }

    private func timing(_ segment: LocalTranscriptSegment) -> String {
        guard let start = segment.startMs, let end = segment.endMs else { return "Time unavailable" }
        return "\(timestamp(start)) – \(timestamp(end))"
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", seconds / 3600,
                      seconds / 60 % 60, seconds % 60, milliseconds % 1000)
    }
}
