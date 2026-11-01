import AVFoundation
import Foundation

/// Streams engine chunks straight to the speakers.
///
/// Chunks arrive slower than they drain (generation is roughly real time or
/// faster), so the player node's own queue is the ring buffer: every chunk is
/// scheduled as its own buffer with `.interrupts: false` and playback stays
/// gapless as long as the queue never runs dry.
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat
    private var pendingBuffers = 0
    private var meterTimer: Timer?

    init(sampleRate: Double = 24_000) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
    }

    func configure(sampleRate: Double) {
        guard abs(format.sampleRate - sampleRate) > 1 else { return }
        stop()
        engine.disconnectNodeOutput(player)
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func begin() {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("BreezeTTS: audio engine failed to start \(error.localizedDescription)")
                return
            }
        }
        player.play()
        isPlaying = true
        startMeter()
    }

    /// Enqueues one chunk of mono float samples at the model sample rate.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }

        pendingBuffers += 1
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 && !self.isPlaying {
                    // nothing to do; state already settled by finish()
                }
            }
        }

        if !player.isPlaying {
            player.play()
            isPlaying = true
            startMeter()
        }

        updateMeter(with: samples)
    }

    /// Called when the engine finished producing audio; playback stops naturally
    /// once the queued buffers drain.
    func finish() {
        isPlaying = false
        stopMeterAfterDrain()
    }

    func stop() {
        player.stop()
        pendingBuffers = 0
        isPlaying = false
        level = 0
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.level > 0.001 {
                self.level *= 0.72
            } else {
                self.level = 0
            }
            if self.pendingBuffers == 0 && self.level < 0.01 {
                self.isPlaying = false
            }
        }
    }

    private func stopMeterAfterDrain() {
        // keep the timer alive briefly so the level decays instead of snapping to 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if self.pendingBuffers == 0 {
                self.meterTimer?.invalidate()
                self.meterTimer = nil
            }
        }
    }

    private func updateMeter(with samples: [Float]) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        let scaled = min(1, rms * 3.2)
        level = max(scaled, level * 0.6)
    }
}
