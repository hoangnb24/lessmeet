import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ChatGPTSession
    var chat: LocalChatModel?
    @ObservedObject var modelManager: LocalModelManager
    @ObservedObject var transcription: LocalTranscriptionModel
    @State private var search = ""
    @State private var showingLibrary = true
    @State private var showingAccount = false
    @State private var showingModels = false
    @FocusState private var searchFocused: Bool

    private var filteredRecordings: [Recording] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.recordings.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var groups: [(title: String, recordings: [Recording])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return [
            ("Today", filteredRecordings.filter { $0.createdAt >= today }),
            ("Yesterday", filteredRecordings.filter { $0.createdAt >= yesterday && $0.createdAt < today }),
            ("Earlier", filteredRecordings.filter { $0.createdAt < yesterday })
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.5)
                if showingLibrary || model.selected == nil {
                    library
                } else if let recording = model.selected {
                    RecordingDetailView(model: model, session: session, chat: chat,
                                        transcription: transcription, recording: recording)
                        .id(recording.id)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(.blue)
        .onChange(of: model.selection, initial: true) { _, id in
            model.loadPlayback()
            chat?.select(recordingID: id)
        }
        .onChange(of: session.sessionIdentifier) { _, _ in chat?.accountChanged() }
        .onChange(of: session.canUseChatGPTPlan) { _, enabled in
            if !enabled { chat?.accountChanged() }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .idle { chat?.cancel() }
            if phase == .starting { showingLibrary = false; search = "" }
        }
        .onChange(of: search) { _, value in if !value.isEmpty { showingLibrary = true } }
        .onDisappear { chat?.cancel() }
        .sheet(isPresented: $showingModels) {
            VStack(alignment: .trailing, spacing: 0) {
                Button("Done") { showingModels = false }.padding([.top, .trailing], 16)
                LocalModelSetupView(manager: modelManager)
            }
        }
        .sheet(isPresented: $showingAccount) {
            VStack(alignment: .trailing, spacing: 0) {
                Button("Done") { showingAccount = false }.padding([.top, .trailing], 16)
                ChatGPTAccountView(session: session, beforeAccountChange: { chat?.cancel() })
            }
            .frame(width: 540)
        }
        .alert("LessMeet", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            Button("Open Recording Permissions") { model.openPermissions() }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.square.fill").font(.system(size: 23)).foregroundStyle(.primary)
                Text("LessMeet").font(.system(size: 15, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search recordings", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search recordings")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
            }
            .padding(9)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Button { showingLibrary = true; search = "" } label: {
                HStack(spacing: 9) {
                    Image(systemName: "books.vertical")
                    Text("Library").fontWeight(.medium)
                    Spacer()
                    Text("\(model.recordings.count)").foregroundStyle(.secondary).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(showingLibrary ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8)

            Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.recordings.sorted { $0.createdAt > $1.createdAt }.prefix(12)) { recording in
                        Button { open(recording) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: recording.status == .recording ? "waveform" : "doc.text")
                                    .foregroundStyle(recording.status == .recording ? Color.red : .secondary)
                                    .padding(.top, 2)
                                Text(recording.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(!showingLibrary && model.selection == recording.id ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.recordings.isEmpty {
                        Text("Your recordings will appear here.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                Button { showingModels = true } label: {
                    Label("Local models", systemImage: "internaldrive")
                }.buttonStyle(.plain)
                Text(modelManager.state == .ready ? "Ready for transcription" : "Model setup: \(modelManager.state.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                if modelManager.state == .downloading || modelManager.state == .checking {
                    ProgressView(value: modelManager.progress)
                    Text("\(ByteCountFormatter.string(fromByteCount: modelManager.completedBytes, countStyle: .decimal)) / \(ByteCountFormatter.string(fromByteCount: modelManager.totalBytes, countStyle: .decimal))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Cancel model setup") { modelManager.cancel() }.font(.caption)
                }
            }.padding(.horizontal, 18).padding(.bottom, 14)
            Label("Saved on this Mac", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 14)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                Button { showingAccount = true } label: {
                    Label("ChatGPT account", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Text(session.canUseChatGPTPlan ? "Using ChatGPT plan" : "Sign in to chat")
                    .font(.caption).foregroundStyle(.secondary)
                if session.error != nil {
                    Text("Account needs attention").font(.caption).foregroundStyle(.orange)
                }
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    .font(.caption)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showingLibrary = true } label: {
                Label("Library", systemImage: "books.vertical")
                    .foregroundStyle(showingLibrary ? .primary : .secondary)
            }.buttonStyle(.plain)
            if !showingLibrary, let recording = model.selected {
                Text("/").foregroundStyle(.tertiary)
                Text(recording.title).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.phase == .recording {
                Circle().fill(.red).frame(width: 7, height: 7)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(durationLabel(context.date.timeIntervalSince(model.startedAt ?? context.date)))
                        .monospacedDigit().fontWeight(.medium)
                }
            }
            if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
            Button {
                Task {
                    if model.phase == .recording { await model.stopRecording() }
                    else { await model.startRecording() }
                }
            } label: {
                Label(buttonTitle, systemImage: model.phase == .recording ? "stop.fill" : "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.phase == .recording ? .red : .blue)
            .disabled(model.phase == .starting || model.phase == .stopping || model.store == nil)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24).frame(height: 54)
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(search.isEmpty ? "Library" : "Search results")
                    .font(.system(size: 32, weight: .bold)).padding(.bottom, 8)
                Text(search.isEmpty ? "Your conversations, all in one place." : "Recordings matching “\(search)”")
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 30)
                HStack(spacing: 8) {
                    Label("All recordings", systemImage: "waveform").fontWeight(.medium)
                    Text("\(filteredRecordings.count)").foregroundStyle(.secondary)
                    Spacer()
                    Text("Newest first").foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(.bottom, 12)
                Divider()
                if filteredRecordings.isEmpty {
                    emptyLibrary.padding(.vertical, 72).frame(maxWidth: .infinity)
                } else {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).padding(.top, 26).padding(.bottom, 8)
                        ForEach(group.recordings) { recording in
                            LibraryRecordingRow(recording: recording) { open(recording) }
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 44).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: search.isEmpty ? "doc.badge.plus" : "magnifyingglass")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
            Text(search.isEmpty ? "Make room for the conversation." : "No recordings found")
                .font(.system(size: 19, weight: .semibold))
            Text(search.isEmpty ? "Record your microphone and system audio.\nCome back to every detail when you need it." : "Try another title or clear your search.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !search.isEmpty {
                Button("Clear search") { search = "" }.buttonStyle(.bordered)
            }
        }
    }

    private func open(_ recording: Recording) {
        model.selection = recording.id
        showingLibrary = false
        searchFocused = false
    }

    private var buttonTitle: String {
        switch model.phase {
        case .idle: "New recording"
        case .starting: "Starting…"
        case .recording: "Stop & Save"
        case .stopping: "Saving…"
        }
    }
}

private struct LibraryRecordingRow: View {
    let recording: Recording
    let action: () -> Void
    @State private var hovered = false

    private var status: String {
        if recording.status == .recording { return "Recording" }
        if recording.status == .interrupted { return "Interrupted" }
        return "Saved locally"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: recording.status == .recording ? "waveform" : "doc.text")
                    .font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                Text(durationLabel(recording.duration)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
            .background(hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Divider().opacity(0.35).padding(.leading, 44) }
    }
}

private struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ChatGPTSession
    let chat: LocalChatModel?
    @ObservedObject var transcription: LocalTranscriptionModel
    let recording: Recording
    @State private var title = ""
    @State private var selectedTab = DetailTab.transcript
    @FocusState private var titleFocused: Bool

    private enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case chat = "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Recording view", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Label("This recording only", systemImage: "doc.text")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 12)
            Divider().opacity(0.5)
            ZStack {
                document
                    .opacity(selectedTab == .transcript ? 1 : 0)
                    .allowsHitTesting(selectedTab == .transcript)
                    .accessibilityHidden(selectedTab != .transcript)
                if let chat {
                    LocalChatView(model: chat, recordingID: recording.id,
                                  canUsePlan: session.canUseChatGPTPlan && !session.busy
                                    && model.phase == .idle && selectedTab == .chat)
                        .opacity(selectedTab == .chat ? 1 : 0)
                        .allowsHitTesting(selectedTab == .chat)
                        .accessibilityHidden(selectedTab != .chat)
                        .disabled(selectedTab != .chat)
                } else if selectedTab == .chat {
                    Text("Chat is unavailable because the local recording library could not be opened.")
                        .foregroundStyle(.secondary).padding(32)
                }
            }
            Divider().opacity(0.5)
            PlaybackBar(player: model.playback).disabled(model.phase != .idle)
                .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .onAppear { title = recording.title }
        .onDisappear { saveTitle() }
        .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
    }

    private var document: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "doc.text").font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(.secondary).padding(.bottom, 22)
                TextField("Untitled recording", text: $title, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 30, weight: .bold))
                    .focused($titleFocused).onSubmit { saveTitle(); titleFocused = false }
                    .accessibilityLabel("Recording title")
                    .padding(.bottom, 14)
                HStack(spacing: 12) {
                    Label(recording.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Text(durationLabel(recording.duration)).monospacedDigit()
                    Spacer()
                    Menu {
                        Button("Show Files", systemImage: "folder") { model.revealSelected() }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().help("Recording options")
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 30)
                if let failure = recording.failure { notice(failure) }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 28)
            .frame(maxWidth: .infinity)
            LocalTranscriptView(model: transcription, recordingID: recording.id)
                .padding(.horizontal, 28)
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { title = recording.title; return }
        guard var saved = model.recordings.first(where: { $0.id == recording.id }), saved.title != trimmed else { return }
        saved.title = trimmed
        model.persist(saved)
        title = trimmed
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            .padding(.bottom, 16)
    }
}

private struct PlaybackBar: View {
    @ObservedObject var player: AudioPlayback
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
                }.buttonStyle(.borderless).disabled(player.duration <= 0)
                    .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")
                Text(durationLabel(player.position)).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { player.position }, set: player.seek), in: 0...max(player.duration, 0.1))
                    .disabled(player.duration <= 0).accessibilityLabel("Playback position")
                Text(durationLabel(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
