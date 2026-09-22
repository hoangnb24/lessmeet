import AVFoundation
import ScreenCaptureKit
import AppKit

@MainActor
final class CaptureService {
    var onFailure: ((String) -> Void)?
    private enum State { case idle, starting, recording, stopping }
    private var state = State.idle
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var sleepObserver: NSObjectProtocol?
    private var pendingFailure: String?
    private var sessionID: UUID?

    init() {}

    func start(directory: URL) async throws {
        guard state == .idle else { throw CaptureError(message: "A recording is already starting or active. Stop it before starting another.") }
        state = .starting
        pendingFailure = nil
        let sessionID = UUID()
        self.sessionID = sessionID
        do {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                throw CaptureError(message: "Microphone access is denied. Enable LessMeet in System Settings → Privacy & Security → Microphone, then try again.")
            }
            try Task.checkCancellation()
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw CaptureError(message: "System audio access failed. Enable LessMeet in System Settings → Privacy & Security → Screen & System Audio Recording and reopen the app if requested. \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            guard let display = content.displays.first else {
                throw CaptureError(message: "No display is available for system audio capture. Connect a display and try again.")
            }
            let output = try CaptureOutput(directory: directory) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.sessionID == sessionID else { return }
                    self.reportFailure(message)
                }
            }
            self.output = output
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.capturesAudio = true
            config.captureMicrophone = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: output)
            self.stream = stream
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            try Task.checkCancellation()
            try await output.checkStartup()
            try Task.checkCancellation()
            if let pendingFailure { throw CaptureError(message: pendingFailure) }
            state = .recording
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == sessionID else { return }
                    self.output?.interrupt("The Mac is going to sleep. This recording was interrupted; start a new recording after waking.")
                }
            }
        } catch {
            try? await stream?.stopCapture()
            // Finish any originals produced before startup failed; do not leave open files.
            _ = try? await output?.close()
            output = nil
            stream = nil
            state = .idle
            self.sessionID = nil
            throw error
        }
    }

    func stop() async throws -> CaptureResult {
        guard state == .recording, let output else {
            throw CaptureError(message: "There is no active recording to stop.")
        }
        state = .stopping
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        defer { self.output = nil; stream = nil; state = .idle; sessionID = nil }
        var stopWarning: String?
        do { try await stream?.stopCapture() }
        catch { stopWarning = "System audio capture stopped with an error: \(error.localizedDescription)" }
        // The queue barrier closes after already-delivered samples, before export starts.
        let audio = try await output.close(warning: stopWarning)
        return try await audio.exportCombined()
    }

    private func reportFailure(_ message: String) {
        guard state == .starting || state == .recording, pendingFailure == nil else { return }
        pendingFailure = message
        if state == .recording { onFailure?(message) }
    }
}

/// ScreenCaptureKit calls both outputs on this queue; disk writes never run on MainActor.
final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "LessMeet.capture.audio", qos: .userInitiated)
    private let recorder: CaptureAudioRecorder
    private let failure: (String) -> Void
    private var firstFailure: String?
    private var closed = false

    init(directory: URL, failure: @escaping (String) -> Void) throws {
        recorder = try CaptureAudioRecorder(directory: directory)
        self.failure = failure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: CaptureSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        receive(sampleBuffer, source: source, clockTime: stream.synchronizationClock.map { CMClockGetTime($0) })
    }

    /// Also permits synthetic tests to exercise the actual queue/drain boundary without TCC.
    func receive(_ sampleBuffer: CMSampleBuffer, source: CaptureSource, clockTime: CMTime? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, firstFailure == nil else { return }
        // This validates buffer timestamps against the capture clock, NOT the interval
        // since the previous buffer. Arbitrarily long genuine source silence is allowed.
        if let clockTime {
            let pts = sampleBuffer.presentationTimeStamp
            guard pts.isNumeric, clockTime.isNumeric, pts.epoch == clockTime.epoch,
                  abs(CMTimeSubtract(pts, clockTime).seconds) <= 30 else {
                fail("Captured audio has an invalid or severely delayed timestamp relative to the stream clock. The recording was interrupted; start a new recording.")
                return
            }
        }
        do { try recorder.append(sampleBuffer, source: source) }
        catch { fail("\(source.rawValue.capitalized) recording failed: \(error.localizedDescription) Check available disk space and your audio device.") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        interrupt("Capture was interrupted: \(error.localizedDescription) Check recording permissions and your audio devices, then start a new recording.")
    }

    func interrupt(_ message: String) {
        queue.async { self.fail(message) }
    }

    private func fail(_ message: String) {
        guard !closed, firstFailure == nil else { return }
        firstFailure = message
        failure(message)
    }

    func checkStartup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let failure = self.firstFailure {
                    continuation.resume(throwing: CaptureError(message: failure))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func close(warning: String? = nil) async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.closed = true
                let warnings = [self.firstFailure, warning].compactMap { $0 }.joined(separator: " ")
                continuation.resume(with: Result { try self.recorder.close(warning: warnings.isEmpty ? nil : warnings) })
            }
        }
    }
}
