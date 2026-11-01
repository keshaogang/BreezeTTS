import AVFoundation
import Foundation

/// WAV read / write helpers. The engine speaks 16-bit PCM WAV on export and mono
/// float32 internally; reference clips come back in whichever format the file had.
enum ExportService {
    static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "BreezeTTS.Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法分配音频缓冲"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    /// In-memory 16-bit PCM WAV. `AVAudioPlayer` needs a file or a data blob, so
    /// previewing a take that has not been written to disk goes through this.
    static func wavData(samples: [Float], sampleRate: Double) -> Data? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let rate = UInt32(sampleRate.rounded())
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = rate * UInt32(blockAlign)
        let payload = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data(capacity: 44 + Int(payload))
        func put<T>(_ value: T) {
            var copy = value
            withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
        }
        func putASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }

        putASCII("RIFF")
        put(UInt32(36) + payload)
        putASCII("WAVE")
        putASCII("fmt ")
        put(UInt32(16))
        put(UInt16(1))
        put(channels)
        put(rate)
        put(byteRate)
        put(blockAlign)
        put(bitsPerSample)
        putASCII("data")
        put(payload)

        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1, min(1, samples[i]))
            pcm[i] = Int16(clamped * 32_767)
        }
        pcm.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            data.append(Data(bytes: base, count: buffer.count * MemoryLayout<Int16>.size))
        }
        return data
    }

    /// Reads any AVFoundation-supported file and returns mono float samples.
    static func readSamples(at url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            let src = channels[ch]
            for i in 0..<frames {
                mono[i] += src[i] / Float(channelCount)
            }
        }
        return (mono, rate)
    }

    /// Reference audio has to match the model rate; linear resampling is fine for
    /// speech at this length.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, target > 0, abs(source - target) > 1, !samples.isEmpty else { return samples }
        let ratio = target / source
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 1 else { return samples }
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            output[i] = a + (b - a) * frac
        }
        return output
    }

    /// `BreezeTTS-2026-10-27-201530.wav` style names.
    static func suggestedFileName(for text: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)
        let cleaned = head.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        return cleaned.isEmpty ? "BreezeTTS-\(stamp).wav" : "BreezeTTS-\(stamp)-\(cleaned).wav"
    }

    static func saveCopy(of source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
