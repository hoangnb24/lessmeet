import AppKit
import Foundation

// Promo-video support for the offline Library fixture. Only LibraryUICheckView
// calls into it, and it stays inert unless LESSMEET_DEMO_CAPTURE_DIR is set.
enum DemoCapture {
    static let directory: URL? = ProcessInfo.processInfo.environment["LESSMEET_DEMO_CAPTURE_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    static var isActive: Bool { directory != nil }

    static let meetingTitle = "Product weekly"
    static let transcript: [(String, String)] = [
        ("Maya", "Thanks for joining. Let's lock the scope for the beta today."),
        ("Alex", "I'd keep it to three things: recording, a readable transcript, and questions about the meeting."),
        ("Priya", "Customer interviews back that up. People mostly want to find what was decided."),
        ("Maya", "Agreed. Then sharing and calendar sync move to after the beta."),
        ("Alex", "The onboarding copy still needs one more pass before we invite testers."),
        ("Maya", "Can you own that, Alex?"),
        ("Alex", "Yes. I'll send the revised draft by Thursday."),
        ("Priya", "Then I'll book five usability sessions for next week."),
        ("Maya", "Open question: do we support recordings longer than two hours at launch?"),
        ("Alex", "Let's measure on real hardware first and decide on Monday."),
        ("Maya", "Great. Decisions are captured. Thanks, everyone."),
    ]
    static let answer = """
    **Decision:** keep the beta focused on recording, a readable transcript and questions about the meeting. \
    Sharing and calendar sync move to after the beta.

    **Next steps**
    1. **Alex** sends the revised onboarding draft by Thursday.
    2. **Priya** books five usability sessions for next week.

    **Open question:** support for recordings over two hours, to be decided on Monday after measuring.
    """

    static func seed(store: RecordingStore) throws -> [UUID] {
        let now = Date()
        let weekly = UUID(), research = UUID(), design = UUID()
        try store.save(Recording(id: weekly, title: meetingTitle, createdAt: now.addingTimeInterval(-5400),
                                 duration: 1448, status: .ready))
        try store.save(Recording(id: research, title: "Customer research", createdAt: now.addingTimeInterval(-90_000),
                                 duration: 1920, status: .ready))
        try store.save(Recording(id: design, title: "Design sync", createdAt: now.addingTimeInterval(-96_000),
                                 duration: 1080, status: .ready))
        var start: Int64 = 0
        let segments = transcript.map { speaker, text -> LocalTranscriptSegment in
            let length = Int64(4_000 + text.count * 60)
            defer { start += length + 900 }
            return LocalTranscriptSegment(startMs: start, endMs: start + length, speaker: speaker, text: text)
        }
        try store.saveLocalTranscript(LocalTranscript(segments: segments), for: weekly)
        try store.saveLocalTranscript(LocalTranscript(segments: [
            LocalTranscriptSegment(startMs: 0, endMs: 9_000, speaker: "Priya",
                                   text: "Most interviewees review meetings to find decisions and owners."),
        ]), for: research)
        return [weekly, research, design]
    }
}

@MainActor
final class DemoCaptureRecorder: RecordingCapture {
    var onFailure: ((String) -> Void)?
    private var started: Date?
    func start(directory: URL) async throws { started = .now }
    func stop() async throws -> CaptureResult {
        CaptureResult(duration: started.map { Date.now.timeIntervalSince($0) } ?? 0, warning: nil)
    }
}

/// Records the app's own window at 60 fps from inside the process, so no
/// Screen Recording permission is involved. Frames are raw RGBA written to
/// `frames.rgba`; `frames.tsv` has one wall-clock timestamp per frame.
/// Records the app's own window at 60 fps from inside the process, so no
/// Screen Recording permission is involved. Frames are raw RGBA written to
/// `frames.rgba` (normally a FIFO read by ffmpeg); `frames.tsv` has one
/// wall-clock timestamp per frame.
@MainActor
final class DemoWindowRecorder {
    static let shared = DemoWindowRecorder()
    static let width = 1920, height = 1080
    static let pointSize = NSSize(width: 1280, height: 720)
    private var timer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "demo.capture.grab", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "demo.capture.write")

    func startIfRequested() {
        guard timer == nil, let directory = DemoCapture.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = directory.appendingPathComponent("frames.rgba")
        let stamps = directory.appendingPathComponent("frames.tsv")
        // frames.rgba may be a FIFO read by an encoder; never replace an existing path.
        for path in [frames.path, stamps.path] where !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let output = try? FileHandle(forWritingTo: frames), let times = try? FileHandle(forWritingTo: stamps),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        window.title = "LessMeet"
        let screen = window.screen?.visibleFrame ?? .zero
        window.setFrame(NSRect(x: screen.midX - Self.pointSize.width / 2, y: screen.midY - Self.pointSize.height / 2,
                               width: Self.pointSize.width, height: Self.pointSize.height), display: true)
        let number = UInt32(window.windowNumber)
        let writeQueue = writeQueue
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(500_000))
        timer.setEventHandler {
            let stamp = Date().timeIntervalSince1970
            guard let data = Self.grab(number) else { return }
            writeQueue.async {
                output.write(data)
                times.write(Data(String(format: "%.6f\n", stamp).utf8))
            }
        }
        timer.resume()
        self.timer = timer
    }

    private nonisolated static func grab(_ number: UInt32) -> Data? {
        guard let image = windowImageFunction?(.null, 1 << 3, number, (1 << 0) | (1 << 3))?.takeRetainedValue(),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return nil }
        context.interpolationQuality = .high
        // Matte the rounded window corners onto the promo stage colour (#dce1cf).
        context.setFillColor(CGColor(red: 0xdc / 255, green: 0xe1 / 255, blue: 0xcf / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes: base, count: width * height * 4)
    }

    // CGWindowListCreateImage is unavailable to Swift on the macOS 15 SDK but still
    // returns a process's own windows without Screen Recording permission.
    // Arguments: optionIncludingWindow = 1 << 3; boundsIgnoreFraming | bestResolution.
    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private nonisolated static let windowImageFunction: WindowImage? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: WindowImage.self) }
}
