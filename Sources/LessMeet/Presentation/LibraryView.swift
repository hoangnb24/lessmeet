import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accountSession: AccountSession
    @ObservedObject var cloud: RecordingCloudModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "waveform.circle.fill").font(.title).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LessMeet").font(.headline)
                        Text("A little less to remember.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                Divider()
                List(selection: $model.selection) {
                    Section("Recordings") {
                        ForEach(model.recordings) { recording in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recording.title).fontWeight(.medium).lineLimit(2)
                                HStack {
                                    Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    Spacer()
                                    Text(recording.status == .recording ? "Recording" : durationLabel(recording.duration))
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(recording.id)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Stored on this Mac", systemImage: "internaldrive").font(.caption)
                    Text("Audio stays local until you ask for a transcript.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
                AccountPanel(session: accountSession)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 350)
        } detail: {
            VStack(spacing: 0) {
                recordingBar
                Divider()
                if let recording = model.selected {
                    RecordingDetailView(model: model, accountSession: accountSession, cloud: cloud, recording: recording)
                        .id(recording.id)
                } else {
                    ContentUnavailableView {
                        Label("Room to listen", systemImage: "waveform")
                    } description: {
                        Text("Record your microphone and system audio separately.\nKeep the conversation, not another meeting bot.")
                    } actions: {
                        Text("Use headphones for the cleanest recording.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: model.selection, initial: true) { _, _ in model.loadPlayback() }
        .onChange(of: model.selection) { _, _ in cloud.contextChanged() }
        .onChange(of: accountSession.sessionIdentifier) { _, _ in cloud.contextChanged() }
        .onChange(of: model.phase) { _, phase in if phase != .idle { cloud.contextChanged() } }
        .onDisappear { cloud.contextChanged() }
        .alert("LessMeet", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            Button("Open Recording Permissions") { model.openPermissions() }
        } message: { Text(model.error ?? "") }
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            if model.phase == .recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(durationLabel(context.date.timeIntervalSince(model.startedAt ?? context.date)))
                        .monospacedDigit().font(.headline)
                }
                Text("Microphone + system audio").foregroundStyle(.secondary)
            } else {
                Label("Microphone + system audio", systemImage: "waveform").foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
            Button {
                Task {
                    if model.phase == .recording { await model.stopRecording() }
                    else { await model.startRecording() }
                }
            } label: {
                Label(buttonTitle, systemImage: model.phase == .recording ? "stop.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.phase == .recording ? .red : .teal)
            .disabled(model.phase == .starting || model.phase == .stopping || model.store == nil)
        }.padding(20)
    }

    private var buttonTitle: String {
        switch model.phase {
        case .idle: "Start Recording"
        case .starting: "Starting…"
        case .recording: "Stop Recording"
        case .stopping: "Saving…"
        }
    }
}

private struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accountSession: AccountSession
    @ObservedObject var cloud: RecordingCloudModel
    let recording: Recording
    @State private var draft = ""
    @State private var confirmUpload = false

    private var remote: CloudRecording? { cloud.cached(recording) }
    private var canUseCloud: Bool {
        accountSession.sessionIdentifier != nil && model.phase == .idle && !cloud.busy && cloud.configurationIssue == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Recording title", text: Binding(get: { recording.title }, set: model.rename))
                    .textFieldStyle(.plain).font(.largeTitle.bold())
                HStack(spacing: 14) {
                    Text(recording.createdAt, format: .dateTime.month(.wide).day().year().hour().minute())
                    Text("•")
                    Text(durationLabel(recording.duration))
                    Spacer()
                    Button("Show Files", systemImage: "folder") { model.revealSelected() }
                }.font(.callout).foregroundStyle(.secondary)
            }
            if let failure = recording.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            PlaybackBar(player: model.playback)
                .disabled(model.phase != .idle)
            HStack {
                if remote == nil || remote?.status == "failed" {
                    Button(remote == nil ? "Create Transcript" : "Upload Again", systemImage: "text.badge.plus") { confirmUpload = true }
                        .disabled(!canUseCloud || recording.status == .recording)
                }
                if remote != nil {
                    Button("Refresh", systemImage: "arrow.clockwise") { cloud.refresh() }.disabled(!canUseCloud)
                    Text(remote?.status.capitalized ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if cloud.busy {
                    ProgressView().controlSize(.small)
                    Text(cloud.activity ?? "Working…").font(.caption)
                    Button("Stop Waiting") { cloud.cancel() }
                }
                Spacer()
            }
            if let issue = cloud.configurationIssue ?? cloud.error ?? remote?.error {
                Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !accountSession.isSignedIn {
                Text("Sign in to create a transcript or view your account's saved cloud results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("Transcript", systemImage: "text.alignleft").font(.headline)
                            Spacer()
                        }
                        if let transcript = remote?.transcript {
                            MarkdownView(text: transcript)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("From conversation to clarity.").font(.title2.weight(.semibold))
                                Text("Choose Create Transcript to upload combined audio to Convex and Gemini. Audio stays local until you choose to upload it.")
                                    .foregroundStyle(.secondary)
                                Label("Maximum upload: 18 MiB", systemImage: "cloud")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 28)
                        }
                    }.padding(.trailing, 20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 300)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Ask this recording", systemImage: "bubble.left.and.bubble.right").font(.headline)
                    ScrollView {
                        if remote?.messages.isEmpty != false {
                            Text("Find decisions, pull out action items, or ask what you missed.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array((remote?.messages ?? []).enumerated()), id: \.offset) { _, message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "You" : "LessMeet").font(.caption.bold()).foregroundStyle(.teal)
                                    MarkdownView(text: message.text)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                    TextField("Ask about this recording…", text: $draft, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                        .disabled(!canUseCloud || remote?.status != "ready")
                    HStack {
                        Text("Answers use this transcript.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Send", systemImage: "paperplane") {
                            cloud.send(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(!canUseCloud || remote?.status != "ready" || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf8.count > 8 * 1024)
                    }
                }.padding(.leading, 20).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
        }.padding(28)
        .onChange(of: accountSession.sessionIdentifier) { _, _ in draft = ""; confirmUpload = false }
        .onChange(of: remote?.messages.count) { old, new in
            if (new ?? 0) > (old ?? 0) { draft = "" }
        }
        .confirmationDialog("Upload this recording?", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button("Upload and Create Transcript") { cloud.transcribe() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Combined audio is sent to Convex and Google Gemini using the owner's paid API key. Audio, transcript and chat stay in Convex indefinitely. Local source files are kept. Uploading again creates a new paid request.")
        }
    }
}

private struct PlaybackBar: View {
    @ObservedObject var player: AudioPlayback
    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
                }.buttonStyle(.bordered).disabled(player.duration <= 0)
                Text(durationLabel(player.position)).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { player.position }, set: player.seek), in: 0...max(player.duration, 0.1))
                    .disabled(player.duration <= 0)
                Text(durationLabel(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
