import AppKit
import AVFoundation
import Foundation
import Speech

/// Turns a reference take into text, so cloning never asks the user to type what
/// they just said out loud.
///
/// The app promises local inference, so the on-device recogniser is always the
/// first attempt. Apple's server engine is only used when this Mac has no local
/// language pack, and the UI says so when that happens.
@MainActor
final class SpeechTranscriber: ObservableObject {
    enum Status: Equatable {
        case idle
        case working
        case done
        case failed(String)

        var isWorking: Bool { self == .working }
    }

    struct Outcome: Equatable {
        let text: String
        let localeID: String
        let onDevice: Bool

        var sourceLabel: String {
            onDevice ? "本地识别" : "系统在线识别"
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastOutcome: Outcome?
    /// Set when the OS refused consent, so the sheet can offer a shortcut to the
    /// privacy pane instead of dead-ending on a message.
    @Published private(set) var needsPermission = false

    /// `auto` runs both the Chinese and the English model and keeps the better
    /// fit, which is what almost every reference clip wants.
    static let autoID = "auto"
    static let choices: [(id: String, label: String)] = [
        (autoID, "自动"),
        ("zh-CN", "中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
    ]

    static func label(for localeID: String) -> String {
        choices.first { $0.id == localeID }?.label ?? localeID
    }

    /// True when this Mac can recognise speech without the network.
    static var supportsOnDeviceChinese: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition ?? false
    }

    /// Asks for consent while the user is still talking, so the consent sheet is
    /// not what they stare at after finishing a take.
    static func prewarm() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func reset() {
        status = .idle
        lastOutcome = nil
        needsPermission = false
    }

    /// Deep link into the pane that owns the speech-recognition switch.
    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Entry point

    /// Recognises the take. Returns nil when nothing usable came back, leaving a
    /// readable reason in `status`.
    func transcribe(samples: [Float],
                    sampleRate: Double,
                    locale: String,
                    allowNetwork: Bool) async -> Outcome? {
        guard samples.count > Int(sampleRate * 0.4) else {
            status = .failed("音频太短，没法识别")
            return nil
        }

        status = .working
        lastOutcome = nil
        needsPermission = false

        let auth = await Self.currentAuthorization()
        guard auth == .authorized else {
            needsPermission = auth != .restricted
            status = .failed(Self.permissionHint(for: auth))
            return nil
        }

        guard let url = Self.stash(samples: samples, sampleRate: sampleRate) else {
            status = .failed("无法准备临时音频")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let duration = Double(samples.count) / max(sampleRate, 1)
        let targets = locale == Self.autoID ? ["zh-CN", "en-US"] : [locale]
        let isAuto = locale == Self.autoID

        // 1) On-device pass: fastest and stays offline.
        var best: Outcome?
        var localFailure: String?
        for target in targets {
            if Task.isCancelled { return nil }
            do {
                let raw = try await recognize(url: url, localeID: target, onDevice: true, duration: duration)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let candidate = Outcome(text: text, localeID: target, onDevice: true)
                best = pick(candidate, over: best, auto: isAuto)
                if !isAuto { break }
            } catch {
                localFailure = Self.describe(error)
            }
        }
        if let best {
            status = .done
            lastOutcome = best
            return best
        }

        // 2) The local pack is missing for this language: fall back to the
        //    system service, only if the caller allows leaving the machine.
        if allowNetwork {
            for target in targets {
                if Task.isCancelled { return nil }
                do {
                    let raw = try await recognize(url: url, localeID: target, onDevice: false, duration: duration)
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let candidate = Outcome(text: text, localeID: target, onDevice: false)
                    let chosen = pick(candidate, over: best, auto: isAuto)
                    if let chosen {
                        status = .done
                        lastOutcome = chosen
                        return chosen
                    }
                } catch {
                    localFailure = localFailure ?? Self.describe(error)
                }
            }
        } else if localFailure == nil {
            localFailure = "这台 Mac 没有该语言的本地听写资源"
        }

        status = .failed(localFailure ?? "没有识别出内容，可以手动填写")
        return nil
    }

    /// With `auto`, prefer the model whose script actually matches the output:
    /// a Chinese model hallucinating on English speech scores badly, and the
    /// English model on Mandarin scores badly too.
    private func pick(_ candidate: Outcome, over current: Outcome?, auto: Bool) -> Outcome? {
        guard auto, let current else { return candidate }
        let lhs = Self.scriptFit(candidate.text, localeID: candidate.localeID)
        let rhs = Self.scriptFit(current.text, localeID: current.localeID)
        return lhs > rhs ? candidate : current
    }

    private static func scriptFit(_ text: String, localeID: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        var hits = 0
        for scalar in scalars {
            switch localeID {
            case "zh-CN", "ja-JP":
                if (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) {
                    hits += 1
                }
            default:
                if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                    hits += 1
                }
            }
        }
        return Double(hits) / Double(scalars.count)
    }

    // MARK: - Speech framework plumbing

    private func recognize(url: URL,
                           localeID: String,
                           onDevice: Bool,
                           duration: Double) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw ASRFailure.message("系统里没有 \(localeID) 的语音识别")
        }
        if onDevice && !recognizer.supportsOnDeviceRecognition {
            throw ASRFailure.noLocalPack
        }
        guard recognizer.isAvailable else {
            throw ASRFailure.message("语音识别服务暂时不可用")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        // 标点补全只有 macOS 13 以后才有，12 上让识别结果保持原样。
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        request.taskHint = .dictation

        // 20 s of speech resolves in ~1 s locally; the budget is only there so a
        // wedged service cannot leave the sheet spinning forever.
        let budget = min(60, 12 + duration * 1.5)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var finished = false
            var task: SFSpeechRecognitionTask?

            func finish(_ result: Result<String, Error>) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                task?.cancel()
                continuation.resume(with: result)
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                finish(.success(result.bestTranscription.formattedString))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + budget) {
                finish(.failure(ASRFailure.timeout))
            }
        }
    }

    private static func currentAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }

        return await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            let lock = NSLock()
            var finished = false

            func settle(_ status: SFSpeechRecognizerAuthorizationStatus) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                continuation.resume(returning: status)
            }

            SFSpeechRecognizer.requestAuthorization { settle($0) }
            // Give the user room to read the consent sheet; a command line run
            // never gets an answer, so it needs a way out.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { settle(.denied) }
        }
    }

    private static func permissionHint(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return ""
        case .notDetermined:
            return "还没有授权语音识别"
        case .denied:
            return "没有语音识别权限，到「系统设置 → 隐私与安全性 → 语音识别」里允许 BreezeTTS，或直接手动填写"
        case .restricted:
            return "这台 Mac 限制了语音识别，请手动填写"
        @unknown default:
            return "语音识别不可用，请手动填写"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? ASRFailure {
            switch failure {
            case .timeout:
                return "识别超时，可以重试或手动填写"
            case .noLocalPack:
                return "这台 Mac 没有该语言的本地听写资源"
            case .message(let text):
                return text
            }
        }
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            return "系统听写出错（\(nsError.code)），可以重试或手动填写"
        }
        if (error as NSError).code == 1110 {
            return "没有听清，请靠近麦克风再说一次"
        }
        return error.localizedDescription
    }

    private static func stash(samples: [Float], sampleRate: Double) -> URL? {
        Paths.ensureDirectories()
        let url = Paths.cache.appendingPathComponent("asr-\(UUID().uuidString).wav")
        do {
            try ExportService.writeWAV(samples: samples, sampleRate: sampleRate, to: url)
            return url
        } catch {
            NSLog("BreezeTTS: cannot stage ASR clip \(error.localizedDescription)")
            return nil
        }
    }
}

private enum ASRFailure: Error {
    case timeout
    case noLocalPack
    case message(String)
}
