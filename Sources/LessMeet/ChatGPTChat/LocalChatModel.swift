import Combine
import Foundation

@MainActor
final class LocalChatModel: ObservableObject {
    @Published private(set) var recordingID: UUID?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var models: [ResponsesModel] = []
    @Published private(set) var busy = false
    @Published private(set) var partialAnswer = ""
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var error: String?
    @Published var selectedModelSlug: String?

    private let conversations: ConversationStore
    private let client: ResponsesClient
    private let sessionID: @MainActor () -> String?
    private let accessToken: @MainActor () async throws -> String
    private let transcriptText: (UUID) throws -> String
    private var catalogSession: String?
    private var historyReadable = false
    private var generation = UUID()
    private var requestTask: Task<Bool, Never>?

    init(store: RecordingStore, client: ResponsesClient = ResponsesClient(),
         sessionID: @escaping @MainActor () -> String?,
         accessToken: @escaping @MainActor () async throws -> String,
         transcriptText: ((UUID) throws -> String)? = nil) {
        conversations = ConversationStore(recordingStore: store)
        self.client = client
        self.sessionID = sessionID
        self.accessToken = accessToken
        self.transcriptText = transcriptText ?? { id in
            guard let transcript = try store.loadLocalTranscript(for: id),
                  transcript.segments.contains(where: {
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { throw InputError.transcriptMissing }
            return String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        }
    }

    // Transcript readiness is checked from disk on send, not inferred from this hint.
    var canSend: Bool {
        !busy && recordingID != nil && historyReadable && sessionID() != nil
            && catalogSession == sessionID()
            && models.contains(where: { $0.slug == selectedModelSlug })
    }

    func select(recordingID: UUID?) {
        cancel()
        self.recordingID = recordingID
        error = nil
        messages = []
        historyReadable = false
        guard let recordingID else { return }
        do {
            messages = try conversations.load(for: recordingID).messages
            historyReadable = true
        } catch {
            self.error = InputError.historyUnreadable.message
        }
    }

    func accountChanged() {
        cancel()
        models = []
        selectedModelSlug = nil
        catalogSession = nil
        // Local history belongs to the recording, not the signed-in account.
        if !historyReadable, recordingID != nil { error = InputError.historyUnreadable.message }
    }

    func cancel() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        busy = false
        partialAnswer = ""
        pendingQuestion = nil
        error = historyReadable || recordingID == nil ? nil : InputError.historyUnreadable.message
    }

    func loadModels() async {
        guard !busy, !Task.isCancelled else { return }
        guard let session = sessionID() else {
            accountChanged()
            error = InputError.noSession.message
            return
        }
        if catalogSession != session {
            models = []
            selectedModelSlug = nil
            catalogSession = nil
        }
        let context = begin()
        let selection = recordingID
        let task = Task { [self] in
            defer { finish(context) }
            do {
                let token = try await accessToken()
                guard current(context, recording: selection, session: session) else { return false }
                let result = try await client.models(accessToken: token)
                guard current(context, recording: selection, session: session) else { return false }
                models = result
                catalogSession = session
                if !models.contains(where: { $0.slug == selectedModelSlug }) { selectedModelSlug = nil }
                return true
            } catch {
                if current(context, recording: selection, session: session) {
                    self.error = safeError(error)
                }
                return false
            }
        }
        requestTask = task
        _ = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func send(_ question: String) async -> Bool {
        guard !busy, !Task.isCancelled else { return false }
        error = nil
        guard let recording = recordingID else { error = "Select a recording before sending a question."; return false }
        guard let session = sessionID() else { error = InputError.noSession.message; return false }
        guard catalogSession == session, let model = selectedModelSlug,
              models.contains(where: { $0.slug == model }) else {
            error = "Load the model list and select an available model before sending."
            return false
        }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter a question before sending."
            return false
        }
        let history: [ChatMessage]
        do {
            history = try conversations.load(for: recording).messages
            historyReadable = true
            messages = history
        } catch {
            historyReadable = false
            self.error = InputError.historyUnreadable.message
            return false
        }
        let transcript: String
        do {
            transcript = try transcriptText(recording)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InputError.transcriptMissing
            }
        } catch {
            self.error = (error as? InputError)?.message
                ?? "Could not read the local transcript. No question was sent."
            return false
        }
        let context = begin()
        pendingQuestion = question
        let task = Task { [self] in
            defer { finish(context) }
            do {
                let token = try await accessToken()
                guard current(context, recording: recording, session: session) else { return false }
                let answer = try await client.reply(accessToken: token, model: model,
                    transcript: transcript, history: history, question: question) { [weak self] delta in
                        await self?.apply(delta, context: context, recording: recording, session: session)
                    }
                guard current(context, recording: recording, session: session) else { return false }
                let completed = history + [ChatMessage(role: .user, text: question),
                                           ChatMessage(role: .assistant, text: answer)]
                // No suspension between the last context check, atomic save and publication.
                do {
                    try conversations.save(LocalConversation(recordingID: recording, messages: completed))
                } catch {
                    self.error = "Could not save the completed answer locally. Previous history is unchanged. No retry was made."
                    return false
                }
                messages = completed
                return true
            } catch {
                if current(context, recording: recording, session: session) {
                    self.error = safeError(error)
                }
                return false
            }
        }
        requestTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func begin() -> UUID {
        generation = UUID()
        busy = true
        partialAnswer = ""
        pendingQuestion = nil
        error = nil
        return generation
    }

    private func current(_ context: UUID, recording: UUID?, session: String) -> Bool {
        guard generation == context else { return false }
        guard sessionID() == session else {
            accountChanged()
            return false
        }
        return !Task.isCancelled && recordingID == recording
    }

    private func apply(_ delta: String, context: UUID, recording: UUID, session: String) {
        guard current(context, recording: recording, session: session) else { return }
        partialAnswer += delta
    }

    private func finish(_ context: UUID) {
        guard generation == context else { return }
        requestTask = nil
        busy = false
        partialAnswer = ""
        pendingQuestion = nil
        if error == nil, !historyReadable, recordingID != nil { error = InputError.historyUnreadable.message }
    }

    private func safeError(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let response = error as? ResponsesClientError { return response.localizedDescription }
        // Token providers can throw errors that contain credentials. Never display their raw text.
        return "Could not authorize the ChatGPT request. Check your sign-in and try again."
    }

    private enum InputError: Error {
        case noSession, transcriptMissing, historyUnreadable
        var message: String {
            switch self {
            case .noSession: return "Sign in to ChatGPT before sending a request."
            case .transcriptMissing: return "This recording has no local transcript text. Transcribe it before sending."
            case .historyUnreadable: return "Could not read local chat history. It was not changed. Repair the saved history before sending."
            }
        }
    }
}
