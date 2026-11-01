import Foundation

/// Human-readable duration for estimates: "7 秒", "1 分 50 秒".
enum DurationText {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let rest = total % 60
        if minutes < 60 {
            return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
        }
        let hours = minutes / 60
        return "\(hours) 时 \(minutes % 60) 分"
    }
}

/// What the run is expected to cost before the user commits to it.
struct GenerationForecast: Equatable {
    /// Predicted length of the finished clip.
    var audioSeconds: Double
    /// Seconds the weights still need before the first sample exists; zero when
    /// the model is already in memory.
    var loadSeconds: Double
    /// Streaming time after the model answers.
    var computeSeconds: Double
    /// Latency before the decoder emits its first chunk.
    var firstChunkSeconds: Double
    /// Extra silent stretch spent encoding a cloned reference voice before any
    /// audio exists. Part of `computeSeconds`, split out so the progress bar can
    /// keep moving during it.
    var prefillSeconds: Double
    /// Streaming cost per audio second for this weight file.
    var streamingRTF: Double
    /// False when the whole clip is decoded in one flush: no audio exists until
    /// the run ends, so live progress must lean on the wall clock alone.
    var streaming: Bool
    /// True once real runs replaced the built-in priors.
    var calibrated: Bool

    var totalSeconds: Double { loadSeconds + computeSeconds }

    /// "预计 1 分 50 秒" — the headline number.
    var totalLabel: String { DurationText.short(totalSeconds) }

    var audioLabel: String { DurationText.short(audioSeconds) }

    /// Tooltip that spells out where the number comes from.
    var detail: String {
        var parts: [String] = []
        parts.append("预计音频 \(audioLabel)")
        if loadSeconds >= 0.5 {
            parts.append("加载 \(DurationText.short(loadSeconds))")
        }
        parts.append("合成 \(DurationText.short(computeSeconds))")
        parts.append(calibrated ? "按本机实测校准" : "按默认参数估算")
        return parts.joined(separator: " · ")
    }
}

/// Live progress for the run that is in flight.
struct RunProgress: Equatable {
    /// 0…1, clamped just below 1 until the engine actually finishes.
    var fraction: Double
    var remainingSeconds: Double

    var percentLabel: String { "\(Int((fraction * 100).rounded()))%" }
    var remainingLabel: String { DurationText.short(remainingSeconds) }
}

/// Predicts how long synthesis takes. Two independent guesses:
///
/// * how many seconds of speech the text becomes — syllables per second plus
///   punctuation pauses, which is stable across runs;
/// * how long the engine needs per audio second (RTF), which depends on the
///   weight file, the machine and the sampler, so it is measured locally and
///   remembered between launches.
///
/// Everything is a local computation: no model call, no network.
final class GenerationEstimator {
    static let shared = GenerationEstimator()

    /// One finished run, kept to recalibrate the priors.
    private struct Sample: Codable {
        var modelID: String
        var units: Double
        var audioSeconds: Double
        var computeSeconds: Double
        var firstChunkSeconds: Double
        var loadSeconds: Double
        var recordedAt: Date
    }

    private enum Prior {
        /// Syllables (Chinese characters) per second of speech.
        static let unitsPerSecond = 6.2
        /// Trailing/leading silence the engine always emits.
        static let leadSeconds = 0.45
        /// Streaming cost per audio second on the reference weights.
        static let streamingRTF = 13.8
        static let firstChunk = 3.0
        static let loadSecondsPerGB = 1.6
        static let referenceBytes = 3_568_844_480.0
        /// Clips shorter than this are effectively fixed length: even "你好"
        /// comes back with ~1.2 s of audio.
        static let minAudio = 1.1
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var samples: [Sample] = []
    private let sampleLimit = 30
    private let key = "gen.estimator.samples"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Text → speech length

    /// Rough syllable count of the text. Latin runs are converted with an
    /// average of ~2.7 letters per syllable, digits are read one by one.
    static func units(in text: String) -> Double {
        var units = 0.0
        var latinRun = 0
        func flushLatin() {
            if latinRun > 0 {
                units += max(1.0, Double(latinRun) / 2.7)
                latinRun = 0
            }
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                flushLatin()
                units += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                latinRun += 1
            case 0x30...0x39:
                flushLatin()
                units += 1.1
            default:
                flushLatin()
            }
        }
        flushLatin()
        return units
    }

    /// Extra silence the punctuation implies.
    static func pauses(in text: String) -> Double {
        var seconds = 0.0
        for character in text {
            switch character {
            case "，", ",", "、", "；", ";", "：", ":": seconds += 0.18
            case "。", "！", "？", "!", "?", ".": seconds += 0.34
            case "…", "—": seconds += 0.30
            case "\n", "\r": seconds += 0.28
            default: break
            }
        }
        return seconds
    }

    // MARK: - Forecast

    /// - Parameters:
    ///   - text: the text about to be spoken.
    ///   - modelID: catalogue id, or "custom" for a hand-imported gguf.
    ///   - modelBytes: file size, used to scale the prior when uncalibrated.
    ///   - modelLoaded: false adds the load time to the total.
    ///   - refAudioSeconds: length of the cloned reference clip, if one is
    ///     selected. Its prompt has to be encoded before the first sample, which
    ///     for a 6 s clip costs more than the whole rest of a short sentence
    ///     (measured: "你好" + 5.9 s clone → first audio at ~15 s).
    func forecast(for text: String,
                  modelID: String,
                  modelBytes: Int64,
                  modelLoaded: Bool,
                  refAudioSeconds: Double = 0,
                  streaming: Bool = true) -> GenerationForecast {
        let units = Self.units(in: text)
        let pauses = Self.pauses(in: text)
        let stats = statistics(for: modelID, modelBytes: modelBytes)

        let audio = max(Prior.minAudio, units / stats.unitsPerSecond + pauses + Prior.leadSeconds)
        let firstChunk = stats.firstChunk
        // Reference-voice prefill measured at roughly 2× its playback length.
        let prefill = refAudioSeconds > 0.3 ? refAudioSeconds * 2.0 + 1.5 : 0
        let compute = firstChunk + prefill + audio * stats.streamingRTF
        let load = modelLoaded ? 0 : stats.loadSeconds

        return GenerationForecast(audioSeconds: audio,
                                  loadSeconds: load,
                                  computeSeconds: compute,
                                  firstChunkSeconds: firstChunk,
                                  prefillSeconds: prefill,
                                  streamingRTF: stats.streamingRTF,
                                  streaming: streaming,
                                  calibrated: stats.calibrated)
    }

    /// Predicts audio length alone — used by the footer while typing.
    func audioSeconds(for text: String, modelID: String, modelBytes: Int64) -> Double {
        forecast(for: text, modelID: modelID, modelBytes: modelBytes, modelLoaded: true).audioSeconds
    }

    // MARK: - Live progress

    /// Turns elapsed wall clock plus produced audio into a percentage and a
    /// countdown. Early on the prior dominates; once a few chunks exist the
    /// observed pace takes over, so a slow machine stops lying to the user.
    func progress(forecast: GenerationForecast,
                  elapsed: Double,
                  producedAudio: Double) -> RunProgress {
        let total = max(0.5, forecast.totalSeconds)

        // Single-flush mode: nothing audible exists until the very end, so the
        // bar is a plain wall-clock curve instead of chunk-driven.
        guard forecast.streaming else {
            let fraction = min(0.96, max(0.02, 0.96 * elapsed / total))
            return RunProgress(fraction: fraction,
                               remainingSeconds: max(1, total - elapsed))
        }

        // Everything before the first audible sample: reference-voice prefill
        // plus the lead frames. During this quiet stretch the bar must still
        // crawl forward — pinning it made short clone runs look frozen at 3%.
        let quiet = forecast.firstChunkSeconds + forecast.prefillSeconds
        guard producedAudio > 0.15 else {
            let pace = max(quiet, total * 0.35)
            let fraction = min(0.42, max(0.015, 0.42 * elapsed / pace))
            return RunProgress(fraction: fraction,
                               remainingSeconds: max(1, total - elapsed))
        }

        let observed = max(0.6, (elapsed - quiet) / producedAudio)
        // Small samples are noisy — weight the prior until ~a quarter of the
        // clip exists.
        let share = min(0.85, producedAudio / max(forecast.audioSeconds * 0.25, 0.2))
        let rtf = observed * share + forecast.streamingRTF * (1 - share)
        let predicted = quiet + forecast.audioSeconds * rtf
        let predictedTotal = forecast.loadSeconds + predicted

        let audioFraction = producedAudio / max(forecast.audioSeconds, 0.2)
        let remaining = max(0.5, predictedTotal - elapsed)
        return RunProgress(fraction: min(0.97, max(0.02, audioFraction)),
                           remainingSeconds: remaining)
    }

    // MARK: - Calibration

    /// Stores a finished run so the next estimate is based on this machine.
    /// In single-flush mode the first chunk IS the end of the run, so the first
    /// chunk is recorded as 0 and the RTF becomes compute/audio directly.
    func record(modelID: String,
                text: String,
                audioSeconds: Double,
                computeSeconds: Double,
                firstChunkSeconds: Double,
                loadSeconds: Double,
                streaming: Bool = true) {
        guard audioSeconds > 0.3, computeSeconds > 0.5, !text.isEmpty else { return }
        let units = Self.units(in: text) + (Self.pauses(in: text) + Prior.leadSeconds) * Prior.unitsPerSecond
        let sample = Sample(modelID: modelID,
                            units: units,
                            audioSeconds: audioSeconds,
                            computeSeconds: computeSeconds,
                            firstChunkSeconds: streaming ? firstChunkSeconds : 0,
                            loadSeconds: loadSeconds,
                            recordedAt: Date())
        lock.lock()
        samples.append(sample)
        if samples.count > sampleLimit { samples.removeFirst(samples.count - sampleLimit) }
        lock.unlock()
        persist()
    }

    /// Number of measured runs, shown in the settings tooltip.
    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func resetCalibration() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        persist()
    }

    private struct Stats {
        var unitsPerSecond: Double
        var streamingRTF: Double
        var firstChunk: Double
        var loadSeconds: Double
        var calibrated: Bool
    }

    private func statistics(for modelID: String, modelBytes: Int64) -> Stats {
        lock.lock()
        let all = samples
        lock.unlock()

        let own = all.filter { $0.modelID == modelID }
        // Two runs of the same weights are enough to trust; otherwise fall back
        // to everything ever measured here.
        let source = own.count >= 2 ? own : all
        let sizeScale = max(0.2, Double(modelBytes) / Prior.referenceBytes)

        guard !source.isEmpty else {
            return Stats(unitsPerSecond: Prior.unitsPerSecond,
                         streamingRTF: Prior.streamingRTF * sizeScale,
                         firstChunk: Prior.firstChunk * pow(sizeScale, 0.6),
                         loadSeconds: Prior.loadSecondsPerGB * (Double(modelBytes) / 1_073_741_824.0),
                         calibrated: false)
        }

        let rate = median(source.map { $0.units / max($0.audioSeconds, 0.2) })
        let rtf = median(source.map { ($0.computeSeconds - $0.firstChunkSeconds) / max($0.audioSeconds, 0.2) })
        let firstChunk = median(source.map { $0.firstChunkSeconds })
        let load = source.compactMap { $0.loadSeconds > 1 ? $0.loadSeconds : nil }

        // Blend with the prior so a single odd run cannot swing the estimate.
        let weight = min(1.0, Double(source.count) / 4.0)
        let priorRate = Prior.unitsPerSecond
        let priorRTF = Prior.streamingRTF * sizeScale

        return Stats(unitsPerSecond: priorRate * (1 - weight) + rate * weight,
                     streamingRTF: priorRTF * (1 - weight) + rtf * weight,
                     firstChunk: Prior.firstChunk * (1 - weight) + firstChunk * weight,
                     loadSeconds: load.isEmpty
                        ? Prior.loadSecondsPerGB * (Double(modelBytes) / 1_073_741_824.0)
                        : median(load),
                     calibrated: true)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return }
        samples = decoded
    }

    private func persist() {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
