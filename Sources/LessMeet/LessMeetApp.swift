import SwiftUI

@main
struct LessMeetApp: App {
    @StateObject private var model: AppModel
    @StateObject private var accountSession: AccountSession
    @StateObject private var cloud: RecordingCloudModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        let account = AccountSession()
        _model = StateObject(wrappedValue: model)
        _accountSession = StateObject(wrappedValue: account)
        _cloud = StateObject(wrappedValue: RecordingCloudModel(app: model, account: account))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model, accountSession: accountSession, cloud: cloud)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { appDelegate.model = model }
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
