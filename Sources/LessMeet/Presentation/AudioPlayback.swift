import AVFoundation
import SwiftUI

@MainActor
final class AudioPlayback: ObservableObject {
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        error = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
            player?.prepareToPlay()
        } catch { self.error = error.localizedDescription }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false }
        else {
            if position >= duration { player.currentTime = 0 }
            isPlaying = player.play()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    self.position = player.currentTime
                    self.isPlaying = player.isPlaying
                    if !player.isPlaying { self.timer?.invalidate() }
                }
            }
        }
    }

    func seek(_ time: TimeInterval) { player?.currentTime = time; position = time }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
    }
}

func durationLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
