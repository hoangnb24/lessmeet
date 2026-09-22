import SwiftUI

@main
struct LessMeetApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
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
