import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accountSession: AccountSession
    @ObservedObject var cloud: RecordingCloudModel
    var billing: BillingStore? = nil
    var subscription: SubscriptionModel? = nil
    var billingConfiguration: BillingConfiguration? = nil
    @State private var search = ""
    @State private var showingLibrary = true
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
                    RecordingDetailView(model: model, accountSession: accountSession, cloud: cloud, recording: recording)
                        .id(recording.id)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(.blue)
        .onChange(of: model.selection, initial: true) { _, _ in model.loadPlayback() }
        .onChange(of: model.selection) { _, _ in cloud.contextChanged() }
        .onChange(of: accountSession.sessionIdentifier) { _, _ in cloud.contextChanged() }
        .onChange(of: cloud.busy) { _, busy in
            if !busy { Task { await subscription?.refresh() } }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .idle { cloud.contextChanged() }
            if phase == .starting { showingLibrary = false; search = "" }
        }
        .onChange(of: search) { _, value in if !value.isEmpty { showingLibrary = true } }
        .onDisappear { cloud.contextChanged() }
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
            Label("Saved on this Mac", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 14)
            Divider().opacity(0.5)
            if let billing, let subscription {
                SubscriptionAccountView(account: accountSession, billing: billing,
                                        subscription: subscription, configuration: billingConfiguration)
            } else {
                AccountPanel(session: accountSession)
            }
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
                            LibraryRecordingRow(recording: recording, remote: cloud.cached(recording)) { open(recording) }
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
    let remote: CloudRecording?
    let action: () -> Void
    @State private var hovered = false

    private var status: String {
        if recording.status == .recording { return "Recording" }
        if recording.status == .interrupted { return "Interrupted" }
        switch remote?.status {
        case "ready": return "Transcript ready"
        case "queued", "processing": return "Transcribing"
        case "failed": return "Needs attention"
        default: return "Audio only"
        }
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
    @ObservedObject var accountSession: AccountSession
    @ObservedObject var cloud: RecordingCloudModel
    let recording: Recording
    @State private var composer = RecordingChatDraft()
    @State private var title = ""
    @State private var confirmUpload = false
    @State private var selectedTab = DetailTab.transcript
    @FocusState private var titleFocused: Bool

    private enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case chat = "Chat"
    }

    private var remote: CloudRecording? { cloud.cached(recording) }
    private var canUseCloud: Bool {
        accountSession.sessionIdentifier != nil && model.phase == .idle && !cloud.busy && cloud.configurationIssue == nil
    }
    private var transcriptReady: Bool { remote?.status == "ready" && remote?.transcript != nil }
    private var pending: Bool { remote?.status == "queued" || remote?.status == "processing" }
    private var canSend: Bool {
        canUseCloud && transcriptReady && composer.canSubmit
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Recording view", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                if selectedTab == .chat {
                    Label("This recording only", systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 28).padding(.vertical, 12)
            Divider().opacity(0.5)
            if selectedTab == .transcript {
                document
            } else if transcriptReady {
                RecordingChatView(recording: recording, remote: remote, cloud: cloud,
                                  draft: $composer.text, pendingQuestion: composer.pending,
                                  canUseCloud: canUseCloud, canSend: canSend,
                                  send: sendQuestion)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Start with a transcript").font(.title2.weight(.semibold))
                    Text("Chat answers questions using this recording’s transcript. Create it first, then come back here.")
                        .foregroundStyle(.secondary)
                    Button("Go to transcript") { selectedTab = .transcript }.buttonStyle(.borderedProminent)
                }.padding(44).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider().opacity(0.5)
            PlaybackBar(player: model.playback).disabled(model.phase != .idle)
                .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .onAppear { title = recording.title }
        .onDisappear { saveTitle() }
        .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
        .onChange(of: accountSession.sessionIdentifier) { _, _ in
            composer = RecordingChatDraft(); confirmUpload = false; selectedTab = .transcript
        }
        .onChange(of: cloud.busy) { _, busy in
            if !busy { composer.finishSubmission(failed: cloud.error != nil) }
        }
        .confirmationDialog("Create a transcript?", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button("Upload and Create Transcript") { cloud.transcribe() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This uploads the combined audio to Convex and Google Gemini for processing. Audio, transcript and chat are stored in the cloud indefinitely. Your local files are kept. Maximum upload: 18 MiB. When quotas are enabled, each completed transcription uses your AI minutes. Uploading again is a new request; refresh an existing transcript first.")
        }
    }

    private var document: some View {
        ScrollView {
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
                        if remote != nil { Button("Refresh transcript", systemImage: "arrow.clockwise") { cloud.refresh() }.disabled(!canUseCloud) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().help("Recording options")
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 30)
                HStack {
                    Label("Transcript", systemImage: "text.alignleft").font(.system(size: 13, weight: .medium))
                    Spacer()
                }.padding(.bottom, 12)
                Divider().padding(.bottom, 24)
                if let failure = recording.failure { notice(failure) }
                if let issue = cloud.configurationIssue ?? cloud.error ?? remote?.error { notice(issue) }
                if cloud.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(cloud.activity ?? "Working…").font(.callout)
                        Spacer()
                        Button("Stop Waiting") { cloud.cancel() }.buttonStyle(.borderless)
                    }.padding(.bottom, 20)
                }
                if let transcript = remote?.transcript {
                    MarkdownView(text: transcript).font(.system(size: 14))
                } else {
                    transcriptPlaceholder
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 44).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private var transcriptPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(placeholderTitle).font(.system(size: 20, weight: .semibold))
            Text(placeholderDescription).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if model.phase == .idle && recording.status != .recording && !cloud.busy {
                if !accountSession.isSignedIn {
                    Button("Sign in to create a transcript") { Task { await accountSession.signIn() } }
                        .buttonStyle(.borderedProminent).disabled(accountSession.busy || accountSession.configurationIssue != nil)
                } else if pending {
                    Button("Check for transcript", systemImage: "arrow.clockwise") { cloud.refresh() }
                        .buttonStyle(.bordered).disabled(!canUseCloud)
                } else {
                    Button(remote?.status == "failed" ? "Try again" : "Create Transcript", systemImage: "text.badge.plus") { confirmUpload = true }
                        .buttonStyle(.borderedProminent).disabled(!canUseCloud)
                }
                Text("Audio stays on your Mac until you choose to upload it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }.padding(.vertical, 24)
    }

    private var placeholderTitle: String {
        if recording.status == .recording { return "A little less to remember." }
        if pending || cloud.busy { return "Your transcript is on its way." }
        if remote?.status == "failed" { return "The transcript couldn’t be created." }
        return "Turn this conversation into something useful."
    }

    private var placeholderDescription: String {
        if recording.status == .recording { return "Capturing microphone and system audio. Stop and save when you’re done." }
        if pending || cloud.busy { return "You can come back later and check for the finished transcript." }
        return "Create a transcript to revisit the details, find decisions, and ask questions about this recording."
    }

    private func sendQuestion() {
        guard canSend, let question = composer.beginSubmission() else { return }
        cloud.send(question)
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
