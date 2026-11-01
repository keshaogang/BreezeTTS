import AVFoundation
import Foundation

/// Records a short reference clip for voice cloning.
///
/// The engine wants mono float32 at the model sample rate (24 kHz), so the input
/// tap is converted on the fly and kept in memory; the WAV file is only written
/// when the user keeps the take.
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    /// Reviewing the take before it is saved.
    @Published private(set) var isPreviewing = false
    @Published private(set) var previewPosition: Double = 0
    /// True when the take came from a file (import) instead of the microphone.
    @Published private(set) var hasExternalTake = false
    /// Bumped once per new take, so the review sheet can transcribe it exactly
    /// once instead of on every published change.
    @Published private(set) var takeToken = 0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat
    private var collected: [Float] = []
    private var timer: Timer?
    private var startedAt: Date?
    private let maxSeconds: Double = 30
    private var previewPlayer: AVAudioPlayer?
    private var previewTicker: Timer?

    init(sampleRate: Double = 24_000) {
        targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        super.init()
    }

    func configure(sampleRate: Double) {
        targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() {
        guard !isRecording else { return }
        Self.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.errorMessage = "没有麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 BreezeTTS"
                return
            }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "找不到可用的输入设备"
            return
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        resetPreview()
        collected.removeAll(keepingCapacity: true)
        hasExternalTake = false
        errorMessage = nil

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "录音启动失败：\(error.localizedDescription)"
            return
        }

        isRecording = true
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(startedAt)
            if self.elapsed >= self.maxSeconds {
                self.stop()
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("BreezeTTS: resample failed \(error.localizedDescription)")
            return
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let frames = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        collected.append(contentsOf: samples)

        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(frames, 1))).squareRoot()
        DispatchQueue.main.async {
            self.level = min(1, self.level * 0.65 + rms * 6 * 0.35)
        }
    }

    /// Stops and returns the clip; empty when nothing usable was captured.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return collected }
        isRecording = false
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        if !collected.isEmpty { takeToken += 1 }
        return collected
    }

    /// Drops the current take.
    func discard() {
        _ = stop()
        resetPreview()
        collected.removeAll()
        hasExternalTake = false
        elapsed = 0
    }

    /// Loads an external clip as the pending take, so the recorder sheet can
    /// review it, name it and fill in the transcript before saving.
    func stage(samples: [Float], sampleRate: Double) {
        discard()
        collected = ExportService.resample(samples, from: sampleRate, to: targetFormat.sampleRate)
        hasExternalTake = !collected.isEmpty
        elapsed = takeDuration
        if !collected.isEmpty { takeToken += 1 }
    }

    func writeWAV(to url: URL) throws {
        try ExportService.writeWAV(samples: collected, sampleRate: targetFormat.sampleRate, to: url)
    }

    var capturedSamples: [Float] { collected }

    var hasTake: Bool { !collected.isEmpty }

    var sampleRate: Double { targetFormat.sampleRate }

    var takeDuration: Double {
        Double(collected.count) / max(targetFormat.sampleRate, 1)
    }

    // MARK: - Reviewing the take

    func togglePreview() {
        if isPreviewing { pausePreview() } else { playPreview() }
    }

    func playPreview() {
        guard !isRecording, !collected.isEmpty else { return }
        if previewPlayer == nil {
            guard let data = ExportService.wavData(samples: collected,
                                                   sampleRate: targetFormat.sampleRate),
                  let player = try? AVAudioPlayer(data: data) else {
                errorMessage = "无法试听这段音频"
                return
            }
            player.delegate = self
            player.prepareToPlay()
            previewPlayer = player
        }
        guard let player = previewPlayer else { return }
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
            previewPosition = 0
        }
        guard player.play() else { return }
        isPreviewing = true
        startPreviewTicker()
    }

    func pausePreview() {
        previewPlayer?.pause()
        previewPosition = previewPlayer?.currentTime ?? 0
        isPreviewing = false
        stopPreviewTicker()
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer?.currentTime = 0
        isPreviewing = false
        previewPosition = 0
        stopPreviewTicker()
    }

    private func resetPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewing = false
        previewPosition = 0
        stopPreviewTicker()
    }

    private func startPreviewTicker() {
        stopPreviewTicker()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self, let player = self.previewPlayer else { return }
            self.previewPosition = player.currentTime
            if !player.isPlaying && self.isPreviewing { self.isPreviewing = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTicker = timer
    }

    private func stopPreviewTicker() {
        previewTicker?.invalidate()
        previewTicker = nil
    }
}

extension VoiceRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPreviewing = false
        previewPosition = 0
        player.currentTime = 0
        stopPreviewTicker()
    }
}
