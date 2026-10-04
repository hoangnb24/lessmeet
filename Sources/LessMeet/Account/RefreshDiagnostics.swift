import Foundation
import OSLog

enum RefreshOrigin: String { case manual, automatic, unspecified }

enum RefreshPhase: String {
    case started, skippedBusy, skippedNoIdentity, tokenStarted, sendStarted
    case httpSucceeded, transportError, transportCancelled, invalidHTTP, httpRejected
    case decodeFailed, decoded, invalidStatus, received, applied
    case discardedAfterToken, discardedAfterResponse, discardedError, invalidAccountResponse
    case tokenError, responseError
}

/// Local diagnostic data only. Correlation never leaves the process in a request.
struct RefreshTrace {
    let id = UUID()
    let origin: RefreshOrigin
    let diagnostics: RefreshDiagnostics

    func event(_ phase: RefreshPhase, requested: Bool? = nil,
               localComplete: Bool? = nil, providersComplete: Bool? = nil) {
        diagnostics.record(id: id, origin: origin, phase: phase, requested: requested,
                           localComplete: localComplete, providersComplete: providersComplete)
    }
}

/// The lock protects the shared event budget and sink. No network or account data.
final class RefreshDiagnostics: @unchecked Sendable {
    @TaskLocal static var current: RefreshTrace?
    static let runtime: RefreshDiagnostics? = {
        let logger = Logger(subsystem: "com.lessmeet.app", category: "RefreshDiagnostics")
        return configured(info: Bundle.main.infoDictionary ?? [:]) { line in
            logger.notice("\(line, privacy: .public)")
        }
    }()

    private let lock = NSLock()
    private let expires: Date
    private var remaining: Int
    private let sink: (String) -> Void
    private let now: () -> Date

    init(expires: Date, limit: Int = 120, now: @escaping () -> Date = Date.init,
         sink: @escaping (String) -> Void) {
        self.expires = expires; self.remaining = limit; self.now = now; self.sink = sink
    }

    static func configured(info: [String: Any], now: Date = Date(),
                           sink: @escaping (String) -> Void) -> RefreshDiagnostics? {
        guard info["LessMeetPackagingMode"] as? String == "dev",
              let epoch = info["LessMeetRefreshDiagnosticsUntil"] as? Double,
              epoch.isFinite, epoch > now.timeIntervalSince1970 else { return nil }
        // An explicit trial deadline cannot enable more than ten minutes per launch.
        return RefreshDiagnostics(expires: min(Date(timeIntervalSince1970: epoch), now.addingTimeInterval(600)), sink: sink)
    }

    func trace(origin: RefreshOrigin) -> RefreshTrace { .init(origin: origin, diagnostics: self) }

    fileprivate func record(id: UUID, origin: RefreshOrigin, phase: RefreshPhase,
                            requested: Bool?, localComplete: Bool?, providersComplete: Bool?) {
        lock.lock(); defer { lock.unlock() }
        let date = now()
        guard remaining > 0, date < expires else { return }
        remaining -= 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var line = "refresh utc=\(formatter.string(from: date)) local=\(id.uuidString) origin=\(origin.rawValue) phase=\(phase.rawValue)"
        if let requested { line += " requested=\(requested)" }
        if let localComplete { line += " localComplete=\(localComplete)" }
        if let providersComplete { line += " providersComplete=\(providersComplete)" }
        sink(line)
    }
}
