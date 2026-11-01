import AVFoundation
import Combine
import Foundation

/// Transport for audio that already exists on disk — a finished generation or a
/// history entry.
///
/// `AudioPlayer` stays responsible for the live stream: chunks arrive while the
/// model is still running and cannot be paused in a meaningful way. Once a run is
/// complete the samples are a real file, so playback moves here, where pause,
/// resume, scrub and a position read-out are all possible.
final class PlaybackService: NSObject, ObservableObject {
    @Published private(set) var hasAudio = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var currentURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// 0…1 for the progress track.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var timeLabel: String {
        "\(Self.clock(currentTime)) / \(Self.clock(duration))"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Loading

    @discardableResult
    func load(url: URL) -> Bool {
        guard Paths.exists(url) else { return false }
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else { return false }
        fresh.delegate = self
        fresh.isMeteringEnabled = true
        fresh.prepareToPlay()

        if player?.isPlaying == true { player?.stop() }
        player = fresh
        currentURL = url
        duration = fresh.duration
        currentTime = 0
        isPlaying = false
        level = 0
        hasAudio = duration > 0
        return hasAudio
    }

    func play(url: URL) {
        if currentURL != url || player == nil {
            guard load(url: url) else { return }
        }
        play()
    }

    func unload() {
        stop()
        player = nil
        currentURL = nil
        hasAudio = false
        duration = 0
    }

    // MARK: - Transport

    func play() {
        guard let player, duration > 0 else { return }
        // Pressing play at the very end restarts instead of doing nothing.
        if player.currentTime >= duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else { return }
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        level = 0
        if let player { currentTime = player.currentTime }
        stopTicker()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func restart() {
        guard let player else { return }
        player.currentTime = 0
        currentTime = 0
        play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        level = 0
        stopTicker()
    }

    func seek(toProgress value: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(1, max(0, value))
        let target = clamped * duration
        player.currentTime = target
        currentTime = target
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if player.isPlaying {
                player.updateMeters()
                let db = player.averagePower(forChannel: 0)
                let linear = powf(10, db / 20)
                self.level = max(self.level * 0.5, min(1, linear * 2.6))
            } else {
                self.level *= 0.55
                if self.isPlaying { self.isPlaying = false }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Preview

    /// Snapshot harness only: fakes a loaded clip so the transport appears in
    /// the rendered screenshots.
    func seedPreview(duration seconds: Double, at position: Double) {
        hasAudio = seconds > 0
        duration = seconds
        currentTime = position
        isPlaying = false
        level = 0
    }
}

extension PlaybackService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        level = 0
        currentTime = duration
        stopTicker()
    }
}
