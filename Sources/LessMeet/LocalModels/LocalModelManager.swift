import Foundation
import Combine

public struct InstalledLocalModels: Sendable, Equatable {
    public let whisperDirectory: URL
    public let tokenizerDirectory: URL
    public let diarizerDirectory: URL
}

@MainActor
final class LocalModelManager: ObservableObject {
    enum State: String, Equatable {
        case idle, checking, missing, downloading, cancelling, cancelled, failed, ready
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var currentFile: String?
    @Published private(set) var error: String?
    @Published private(set) var installed: InstalledLocalModels?
    let totalBytes: Int64
    let fileCount: Int
    var progress: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }

    private let store: ModelDownloadStore?
    private let setupError: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var didStartup = false
    private var didPrepare = false
    private var retryRequested = false

    convenience init(root: URL? = nil) {
        let folder = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LessMeet/Models", isDirectory: true)
        self.init(root: folder, catalog: LocalModelCatalog.artifacts, configuration: .ephemeral)
    }

    // Internal injection keeps the production catalog and transport fixed.
    init(root: URL, catalog: [LocalModelArtifact], configuration: URLSessionConfiguration) {
        fileCount = catalog.reduce(0) { $0 + $1.files.count }
        do {
            let store = try ModelDownloadStore(root: root, catalog: catalog, configuration: configuration)
            self.store = store
            totalBytes = store.totalBytes
            setupError = nil
        } catch {
            store = nil
            totalBytes = 0
            setupError = error.localizedDescription
        }
    }

    // The app shell must share one manager across windows and controllers.
    // The guard belongs here, not in a transient SwiftUI view.
    func startup() async {
        guard !didStartup else { return }
        didStartup = true
        await prepare()
        guard state == .missing else { return }
        await start()
    }

    func prepare() async {
        if let operation { await operation.value; return }
        guard !didPrepare, state != .cancelled, state != .failed else { return }
        await run(download: false)
    }

    func start() async {
        if let operation {
            await operation.value
            if state == .missing { await start() }
            return
        }
        guard installed == nil, state != .cancelled, state != .failed else { return }
        await run(download: true)
    }

    func cancel() {
        retryRequested = false
        guard state != .ready else { return }
        if let operation {
            state = .cancelling
            operation.cancel()
        } else { state = .cancelled }
        installed = nil
    }

    // Retry is an explicit user action. If cancellation is still draining,
    // queue exactly one retry after the previous writer has released its lock.
    func retry() {
        guard installed == nil else { return }
        if let operation {
            retryRequested = true
            state = .cancelling
            operation.cancel()
            return
        }
        state = .missing
        error = nil
        Task { await start() }
    }

    private func run(download: Bool) async {
        guard let store else {
            error = setupError
            state = .failed
            return
        }
        let token = UUID()
        generation = token
        state = download ? .downloading : .checking
        error = nil
        completedBytes = 0
        let report: @Sendable (Int64, String) -> Void = { [weak self] bytes, file in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token,
                      self.state == .downloading || self.state == .checking else { return }
                self.completedBytes = bytes
                self.currentFile = file
            }
        }
        let worker = Task.detached(priority: .utility) {
            try await store.run(download: download, progress: report)
        }
        let operation = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await worker.result },
                                                           onCancel: { worker.cancel() })
            guard let self, self.generation == token else { return }
            if Task.isCancelled {
                self.installed = nil
                self.state = .cancelled
            } else {
                switch result {
                case .success(let installed):
                    self.installed = installed
                    self.didPrepare = true
                    self.state = installed == nil ? .missing : .ready
                    if installed != nil { self.completedBytes = self.totalBytes }
                case .failure(let error):
                    self.installed = nil
                    self.error = error.localizedDescription
                    self.state = error is CancellationError ? .cancelled : .failed
                }
            }
            self.currentFile = nil
            self.operation = nil
            if self.retryRequested {
                self.retryRequested = false
                self.retry()
            }
        }
        self.operation = operation
        await operation.value
    }
}
