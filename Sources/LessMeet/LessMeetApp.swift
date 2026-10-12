import SwiftUI

#if LESSMEET_OFFLINE_CHECK
@main
struct LessMeetOfflineApp: App {
    var body: some Scene {
        WindowGroup("LessMeet Offline Check") {
            OfflineAccountCheckView().frame(minWidth: 580, minHeight: 440)
        }
        .defaultSize(width: 640, height: 520)
    }
}
#else
@main
struct LessMeetApp: App {
    @StateObject private var model: AppModel
    @StateObject private var chatGPTSession: ChatGPTSession
    @StateObject private var modelManager: LocalModelManager
    @StateObject private var transcription: LocalTranscriptionModel
    @State private var chat: LocalChatModel?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        let session = ChatGPTSession()
        let manager = LocalModelManager()
        let transcription = LocalTranscriptionModel(app: model, manager: manager)
        model.onRecordingFinalized = { [weak transcription] id in
            transcription?.transcribe(recordingID: id)
        }
        _model = StateObject(wrappedValue: model)
        _chatGPTSession = StateObject(wrappedValue: session)
        _modelManager = StateObject(wrappedValue: manager)
        _transcription = StateObject(wrappedValue: transcription)
        _chat = State(initialValue: model.store.map { store in
            LocalChatModel(store: store, sessionID: { session.sessionIdentifier },
                           accessToken: { try await session.accessToken() })
        })
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model, session: chatGPTSession, chat: chat,
                        modelManager: modelManager, transcription: transcription)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { appDelegate.model = model }
                .task { await modelManager.startup() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.canQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recording is still in progress"
        alert.informativeText = "Stop the recording and wait for it to save before quitting."
        alert.addButton(withTitle: "Keep LessMeet Open")
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
