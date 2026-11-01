import AppKit
import Combine
import Foundation

/// Central coordinator: model lifecycle, generation runs, playback and export.
/// Everything user-visible funnels through here so the views stay declarative.
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingModel
        case generating
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loadingModel, .generating: return true
            default: return false
            }
        }
    }

    let settings: AppSettings
    let history: HistoryStore
    let voices: VoiceStore
    let player: AudioPlayer
    /// Transport for finished audio (play / pause / scrub). The streaming player
    /// above only covers the live run.
    let playback: PlaybackService
    let downloader: ModelDownloader
    let recorder: VoiceRecorder
    /// Predicts run duration; also collects what really happened.
    let estimator: GenerationEstimator
    /// 对话（LLM 聊天 + 语音朗读）。
    let chat = ChatService()

    @Published var text = ""
    @Published var phase: Phase = .idle
    @Published var statusLine = ""
    @Published var generatedSamples: [Float] = []
    @Published var generationSeconds: Double = 0
    @Published var audioSeconds: Double = 0
    /// Live percentage + countdown for the run in flight.
    @Published var runProgress: RunProgress?
    @Published var activeModelPath: String?
    @Published var selectedVoiceID: UUID?
    /// Drives which root view is shown; false once the guided setup is done.
    @Published var needsOnboarding: Bool
    @Published var lastExportedURL: URL?

    private var progressTimer: Timer?
    private var generationStarted: Date?
    private var cancellables: Set<AnyCancellable> = []
    /// Snapshot of the estimate taken when the run started.
    private var runForecast: GenerationForecast?
    private var firstChunkAt: Double?
    private var runLoadSeconds: Double = 0

    init(settings: AppSettings = AppSettings(),
         history: HistoryStore = HistoryStore(),
         voices: VoiceStore = VoiceStore(),
         player: AudioPlayer = AudioPlayer(),
         playback: PlaybackService = PlaybackService(),
         downloader: ModelDownloader = ModelDownloader(),
         recorder: VoiceRecorder = VoiceRecorder(),
         estimator: GenerationEstimator = .shared) {
        self.settings = settings
        self.history = history
        self.voices = voices
        self.player = player
        self.playback = playback
        self.downloader = downloader
        self.recorder = recorder
        self.estimator = estimator
        self.needsOnboarding = !settings.onboarded

        Paths.ensureDirectories()

        // Views observe the model, so transport changes have to be re-published.
        playback.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The toolbar label follows `settings.instruction`, so style changes made
        // in any sheet have to refresh the main window too.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Strategy / override changes take effect immediately, as the spec requires.
        settings.$strategy
            .dropFirst()
            .sink { [weak self] _ in self?.modelSelectionChanged() }
            .store(in: &cancellables)

        settings.$overrideTierID
            .dropFirst()
            .sink { [weak self] _ in self?.modelSelectionChanged() }
            .store(in: &cancellables)

        // iPhone companion: LAN server follows the settings toggle.
        RemoteServer.shared.statusProvider = { [weak self] in
            guard let self else { return [:] }
            return ["ready": self.isModelLoaded,
                    "model": self.activeSpec.displayName,
                    "voice": self.voiceLabel,
                    "backend": SpeechEngine.shared.backendName,
                    // 精简版没有这套服务，iOS 端靠这个字段确认对面是完整版。
                    "edition": "full",
                    "app": "BreezeTTS",
                    "api": 2,
                    "audiobook": true,
                    "chat": self.settings.chatEnabled]
        }
        RemoteServer.shared.generateHandler = { [weak self] text, instruction, completion in
            guard let self else { return }
            self.generateRemote(text: text, instruction: instruction, completion: completion)
        }
        // Settings mirror: the phone reads and writes the same knobs the Mac UI uses.
        // (assigned further down, together with the chat handlers)
        RemoteServer.shared.settingsApplyHandler = { [weak self] object in
            guard let self else { return }
            if let streaming = object["streaming"] as? Bool {
                self.settings.streamPlayback = streaming
            }
            if let instruction = object["instruction"] as? String,
               !instruction.trimmingCharacters(in: .whitespaces).isEmpty {
                self.settings.instruction = instruction
            }
            let match: (VoiceMeta) -> Bool
            if let idString = object["voiceID"] as? String, let id = UUID(uuidString: idString) {
                match = { $0.id == id }
            } else if let name = object["voice"] as? String, !name.isEmpty {
                match = { $0.name == name }
            } else { return }
            guard let voice = self.voices.voices.first(where: match) else { return }
            if voice.isTextVoice {
                self.applyTextVoice(voice)
            } else {
                self.selectedVoiceID = voice.id
            }
        }
        RemoteServer.shared.progressProvider = { [weak self] in
            guard let self else { return [:] }
            var payload: [String: Any] = ["active": self.phase.isBusy]
            switch self.phase {
            case .loadingModel: payload["phase"] = "loading"
            case .generating: payload["phase"] = "generating"
            default: payload["phase"] = "idle"
            }
            if let progress = self.runProgress {
                payload["fraction"] = progress.fraction
                payload["remaining"] = progress.remainingSeconds
            } else if let started = self.remoteRunStarted, self.remoteRunExpected > 0 {
                // Remote runs: derive the time curve on demand (thread-safe).
                let elapsed = Date().timeIntervalSince(started)
                payload["fraction"] = min(0.96, elapsed / self.remoteRunExpected)
                payload["remaining"] = max(1, self.remoteRunExpected - elapsed)
            }
            return payload
        }
        RemoteServer.shared.historyProvider = { [weak self] in
            guard let self else { return [] }
            return self.history.items.prefix(60).map { item in
                ["id": item.id.uuidString,
                 "title": item.title,
                 "duration": item.durationSeconds,
                 "date": item.timeLabel,
                 "voice": item.voiceName ?? "",
                 "hasAudio": item.url != nil] as [String: Any]
            }
        }
        RemoteServer.shared.historyAudioHandler = { [weak self] id in
            guard let self, let uuid = UUID(uuidString: id) else { return nil }
            return self.history.items.first(where: { $0.id == uuid })?.url
        }
        RemoteServer.shared.audiobookStartHandler = { [weak self] text, completion in
            self?.remoteAudiobookAnalyze(text: text, completion: completion)
        }
        RemoteServer.shared.audiobookStateProvider = { [weak self] in
            guard let self else { return [:] }
            let characters: [[String: Any]] = self.audiobookCharacters.map {
                ["id": $0.id.uuidString, "name": $0.name, "age": $0.age,
                 "personality": $0.personality, "lines": $0.lines,
                 "ageDesc": $0.ageDesc, "gender": $0.gender, "feature": $0.feature,
                 "has_ref": $0.hasReference, "ref_stale": $0.refStale,
                 "ref_text": $0.refText] as [String: Any]
            }
            var payload: [String: Any] = [
                "status": self.audiobookStatus,
                "analyzing": self.audiobookAnalyzing,
                "generating": self.audiobookProgress != nil,
                "progress": self.audiobookProgress ?? 0,
                "characters": characters,
                "segments": self.audiobookSegments.count,
                "ref_generating": self.refGeneratingID?.uuidString ?? "",
                "ref_status": self.refStatus,
            ]
            if let id = self.audiobookAudioID {
                payload["audio_id"] = id
                payload["audio_duration"] = self.audiobookAudioDuration
            }
            if let progress = self.audiobookProgress {
                payload["status"] = "\(self.audiobookStatus) · \(Int(progress * 100))%"
            }
            return payload
        }
        RemoteServer.shared.audiobookGenerateHandler = { [weak self] completion in
            self?.remoteAudiobookGenerate(completion: completion)
        }
        RemoteServer.shared.audiobookRoleHandler = { [weak self] object in
            guard let self, let raw = object["id"] as? String,
                  let id = UUID(uuidString: raw) else { return }
            self.updateRoleProfile(id,
                                   name: object["name"] as? String,
                                   ageDesc: object["ageDesc"] as? String,
                                   gender: object["gender"] as? String,
                                   feature: object["feature"] as? String)
        }
        RemoteServer.shared.audiobookRefHandler = { [weak self] raw in
            guard let self, let id = UUID(uuidString: raw) else { return }
            self.generateRoleReference(id)
        }
        RemoteServer.shared.chatHandler = { [weak self] text, completion in
            guard let self else { return }
            self.chat.send(text, settings: self.settings)
            // The chat service publishes the reply; wait for it here.
            var waited = 0.0
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                let last = self.chat.messages.last
                if !self.chat.thinking, last?.role == "assistant",
                   last?.text.isEmpty == false, self.chat.errorText.isEmpty {
                    timer.invalidate()
                    completion(.success(last!.text))
                } else if !self.chat.errorText.isEmpty, !self.chat.thinking {
                    timer.invalidate()
                    completion(.failure(NSError(domain: "BreezeTTS.Chat", code: 20,
                                                userInfo: [NSLocalizedDescriptionKey: self.chat.errorText])))
                } else if waited > 240 {
                    timer.invalidate()
                    completion(.failure(NSError(domain: "BreezeTTS.Chat", code: 21,
                                                userInfo: [NSLocalizedDescriptionKey: "对话超时"])))
                }
                waited += 1
            }
            _ = timer
        }
        RemoteServer.shared.chatHistoryProvider = { [weak self] in
            self?.chat.historyProvider() ?? []
        }
        RemoteServer.shared.settingsProvider = { [weak self] in
            guard let self else { return [:] }
            let catalog: [[String: Any]] = self.voices.voices.map {
                ["id": $0.id.uuidString,
                 "name": $0.name,
                 "kind": $0.isTextVoice ? "text" : "clone"]
            }
            return ["voice": self.voiceLabel,
                    "instruction": self.settings.instruction,
                    "streaming": self.settings.streamPlayback,
                    "chatEnabled": self.settings.chatEnabled,
                    "voices": catalog]
        }
        // Remote (iPhone) chat: same conversation as the Mac sheet.
        chat.speakHandler = { [weak self] text, onProgress, completion in
            self?.speakChat(text, progress: onProgress, completion: completion)
        }
        if settings.remoteServer { RemoteServer.shared.start() }
        settings.$remoteServer
            .dropFirst()
            .sink { [weak self] on in on ? RemoteServer.shared.start() : RemoteServer.shared.stop()
                self?.statusLine = on ? "已开启 iPhone 遥控" : "已关闭 iPhone 遥控" }
            .store(in: &cancellables)

        if RenderMode.isPreview {
            text = "欢迎使用 Breeze TTS。这是一个完全本地运行的语音合成工具：模型在你自己的 Mac 上推理，文本不会离开这台机器。\n\n把任意中英文段落粘到左边，点「生成语音」，几秒后就能听到结果，也可以直接导出 WAV 交剪辑软件使用。"
            statusLine = "本地引擎就绪 · Metal 加速"
            // Gives the snapshot harness a finished clip so the transport renders.
            audioSeconds = 9.4
            generatedSamples = [0]
            playback.seedPreview(duration: 9.4, at: 3.2)
        }
    }

    // MARK: - Derived state

    var activeSpec: ModelSpec { settings.resolvedSpec }

    var activeSpecInstalled: Bool { activeSpec.installed }

    var selectedVoice: VoiceMeta? {
        guard let selectedVoiceID else { return nil }
        return voices.voices.first { $0.id == selectedVoiceID }
    }

    // MARK: - Voice style

    /// The preset currently in effect, or nil when the wording is hand-written.
    var activeStyle: VoiceStyle? {
        VoiceStyles.match(instruction: settings.instruction)
    }

    /// The saved text voice whose wording is currently in effect. Matching is
    /// derived from the instruction itself, so no extra selection state exists
    /// to fall out of sync.
    var activeTextVoice: VoiceMeta? {
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }
        return voices.voices.first {
            ($0.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(current) == .orderedSame
        }
    }

    /// What the toolbar button shows: an explicit clone wins, otherwise the style.
    var voiceLabel: String {
        if let selectedVoice { return selectedVoice.name }
        if let style = activeStyle {
            return style.id == VoiceStyles.neutral.id ? "音色" : style.name
        }
        if let textVoice = activeTextVoice { return textVoice.name }
        // 空指令 = 中性默认（克隆/文字音色都不选时的单选空位）。
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? "中性自然" : "自定义"
    }

    /// Best guess for the text in the editor, used for the toolbar hint dot.
    var suggestedStyle: VoiceAdvisor.Pick? {
        VoiceAdvisor.recommend(for: text, limit: 1).first
    }

    /// A style never clears a cloned voice: the clone decides *who* speaks, the
    /// style decides *how*. Hand-written wording is kept aside so the menu can
    /// hand it back.
    func applyStyle(_ style: VoiceStyle) {
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if VoiceStyles.match(instruction: current) == nil,
           !current.isEmpty,
           current.caseInsensitiveCompare(style.instruction) != .orderedSame {
            settings.instructionBackup = current
        }
        settings.instruction = style.instruction
        statusLine = style.id == VoiceStyles.neutral.id ? "声线：中性自然" : "声线：\(style.name)"
    }

    /// Applies a saved text voice: its wording becomes the instruction. 单选模式：
    /// 文字音色与克隆音色互斥，选一个就清掉另一个。
    func applyTextVoice(_ voice: VoiceMeta) {
        let wording = (voice.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, current.caseInsensitiveCompare(wording) != .orderedSame {
            settings.instructionBackup = settings.instruction
        }
        settings.instruction = voice.instruction ?? ""
        selectedVoiceID = nil
        statusLine = "声线：\(voice.name)"
    }

    /// 选中克隆音色：参考音频决定音色，音色自带的文字辅助描述叠加为指令
    /// （语气/语速/情绪），保持单选。
    func selectCloneVoice(_ voice: VoiceMeta) {
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let wording = (voice.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, current.caseInsensitiveCompare(wording) != .orderedSame {
            settings.instructionBackup = settings.instruction
        }
        settings.instruction = voice.instruction ?? ""
        selectedVoiceID = voice.id
        statusLine = "声线：\(voice.name)"
    }

    /// 回到中性默认：无克隆、无文字声线。
    func resetToNeutralVoice() {
        let current = settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            settings.instructionBackup = settings.instruction
        }
        settings.instruction = ""
        selectedVoiceID = nil
        statusLine = "声线：中性自然"
    }

    /// Saves a text-described voice. Empty wording is meaningless, so it is
    /// rejected at the store boundary.
    @discardableResult
    func saveTextVoice(name: String, instruction: String) -> VoiceMeta? {
        let wording = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !wording.isEmpty else { return nil }
        return voices.addTextVoice(name: title, instruction: wording)
    }

    /// Puts the hand-written instruction back, if a preset replaced it.
    var canRestoreInstruction: Bool {
        guard let backup = settings.instructionBackup, !backup.isEmpty else { return false }
        return backup.caseInsensitiveCompare(settings.instruction) != .orderedSame
    }

    func restoreCustomInstruction() {
        guard let backup = settings.instructionBackup, !backup.isEmpty else { return }
        settings.instruction = backup
        statusLine = "已恢复自定义指令"
    }

    var modelFileURL: URL? {
        if let custom = settings.customModelPath, Paths.exists(URL(fileURLWithPath: custom)) {
            return URL(fileURLWithPath: custom)
        }
        // Catalogue entries must match their exact byte count: a half finished
        // download would fail inside breeze_init with a confusing error.
        if activeSpec.installed { return activeSpec.fileURL }
        // Fall back to any complete gguf so a hand-imported file still works.
        return ModelCatalog.installedFiles().first { url in
            if let spec = ModelCatalog.spec(fileName: url.lastPathComponent) {
                return spec.installed
            }
            return Paths.size(of: url) > 200_000_000
        }
    }

    var modelReady: Bool { modelFileURL != nil }

    /// 对话能否发图片：仅云端视觉模型支持（本地 1.5B 模型不识别图片）。
    var chatVisionAvailable: Bool {
        settings.cloudConfig != nil && settings.cloudSupportsVision
    }

    var modelLabel: String {
        if let path = modelFileURL, let spec = ModelCatalog.spec(fileName: path.lastPathComponent) {
            return spec.displayName
        }
        return modelFileURL?.lastPathComponent ?? "未选择模型"
    }

    var isModelLoaded: Bool {
        guard let activeModelPath else { return false }
        return activeModelPath == modelFileURL?.path
    }

    var charCount: Int { text.count }

    var estimatedFrames: Int { max(1, Int(Double(charCount) * 1.6)) }

    // MARK: - Duration estimate

    /// Catalogue id of the weights in use, so calibration is kept per file.
    private var estimateModelID: String {
        guard let url = modelFileURL,
              let spec = ModelCatalog.spec(fileName: url.lastPathComponent) else { return "custom" }
        return spec.id
    }

    private var estimateModelBytes: Int64 {
        guard let url = modelFileURL else { return activeSpec.bytes }
        if let spec = ModelCatalog.spec(fileName: url.lastPathComponent) { return spec.bytes }
        return Paths.size(of: url)
    }

    /// Calibration samples are keyed per weight file AND per playback mode: a
    /// single-flush run is ~40% faster, so mixing the two would corrupt the RTF.
    private var calibrationModelID: String {
        estimateModelID + (settings.streamPlayback ? "" : "-ns")
    }

    /// What the footer shows while typing: clip length plus wall-clock estimate.
    var forecast: GenerationForecast? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return estimator.forecast(for: trimmed,
                                  modelID: calibrationModelID,
                                  modelBytes: estimateModelBytes,
                                  modelLoaded: isModelLoaded,
                                  refAudioSeconds: selectedVoice?.durationSeconds ?? 0,
                                  streaming: settings.streamPlayback)
    }

    // MARK: - First run

    func completeOnboarding() {
        settings.onboarded = true
        needsOnboarding = false
        statusLine = ""
        if let url = modelFileURL, !isModelLoaded {
            loadModel(at: url)
        }
    }

    func restartOnboarding() {
        needsOnboarding = true
    }

    // MARK: - Bootstrapping

    /// "模型已就绪 · 24000 Hz · Metal 加速" — the backend name tells a silent
    /// CPU fallback apart from a genuinely loaded GPU path.
    static var readyStatusLine: String {
        let backend = SpeechEngine.shared.backendName
        return "模型已就绪 · \(Int(SpeechEngine.shared.sampleRate)) Hz"
            + (backend.isEmpty ? "" : " · \(backend) 加速")
    }

    /// Called from the main view's `.task`. Loads whatever model is already on disk.
    func bootstrap() {
        Paths.ensureDirectories()
        // The snapshot harness seeds its own state and must not load weights.
        if RenderMode.isPreview { return }
        player.configure(sampleRate: SpeechEngine.shared.sampleRate)
        recorder.configure(sampleRate: SpeechEngine.shared.sampleRate)

        if let url = modelFileURL {
            statusLine = "正在加载模型…"
            loadModel(at: url)
        } else {
            phase = .idle
            statusLine = "尚未安装模型，先从「模型」面板下载一档权重"
        }
    }

    func loadModel(at url: URL) {
        guard phase != .loadingModel else { return }
        // The model IS the active one already: nothing to do.
        if isModelLoaded {
            phase = .idle
            statusLine = Self.readyStatusLine
            return
        }

        phase = .loadingModel
        statusLine = "正在加载 \(url.lastPathComponent)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            SpeechEngine.shared.load(path: url.path, useGPU: self.settings.useGPU) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.activeModelPath = url.path
                    self.player.configure(sampleRate: SpeechEngine.shared.sampleRate)
                    self.recorder.configure(sampleRate: SpeechEngine.shared.sampleRate)
                    self.phase = .idle
                    self.statusLine = Self.readyStatusLine
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                    self.statusLine = "模型加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func modelSelectionChanged() {
        // Switching strategy swaps the weight file; do it lazily so we never hold two
        // multi-gigabyte contexts at once.
        SpeechEngine.shared.unload()
        activeModelPath = nil
        if let url = modelFileURL {
            loadModel(at: url)
        } else {
            phase = .idle
            statusLine = "当前档位未下载：\(activeSpec.displayName)"
        }
    }

    // MARK: - Generation

    func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "先输入要合成的文本"
            return
        }
        guard let url = modelFileURL else {
            phase = .failed("没有可用的模型文件")
            statusLine = "请先下载模型"
            return
        }
        if phase == .generating {
            // Audiobook keeps running in the background; a user run slots in
            // between its segments (the engine queue serialises at segment
            // granularity), so both take longer but neither is cancelled.
            guard audiobookProgress != nil else { return }
            statusLine = "听书正在后台继续 · 本次生成将插队执行，听书完成时间顺延"
        }

        // Freeze the estimate now: loading weights must not change the promise
        // the user is looking at.
        let plan = forecast ?? estimator.forecast(for: trimmed,
                                                  modelID: calibrationModelID,
                                                  modelBytes: estimateModelBytes,
                                                  modelLoaded: isModelLoaded,
                                                  refAudioSeconds: selectedVoice?.durationSeconds ?? 0,
                                                  streaming: settings.streamPlayback)
        runForecast = nil
        runProgress = nil
        runLoadSeconds = 0

        let start: () -> Void = { [weak self] in
            self?.runGeneration(text: trimmed, plan: plan)
        }

        if isModelLoaded {
            start()
        } else {
            statusLine = "加载模型后开始合成…"
            let loadBegan = Date()
            SpeechEngine.shared.load(path: url.path, useGPU: settings.useGPU) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.runLoadSeconds = Date().timeIntervalSince(loadBegan)
                    self.activeModelPath = url.path
                    self.player.configure(sampleRate: SpeechEngine.shared.sampleRate)
                    start()
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                    self.statusLine = "模型加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func runGeneration(text trimmed: String, plan: GenerationForecast) {
        phase = .generating
        generationSeconds = 0
        audioSeconds = 0
        generatedSamples.removeAll(keepingCapacity: true)
        playback.unload()
        statusLine = "合成中…"
        generationStarted = Date()
        firstChunkAt = nil
        // The weights are in memory by now, so only the streaming part is left.
        var livePlan = plan
        livePlan.loadSeconds = 0
        runForecast = livePlan
        runProgress = RunProgress(fraction: 0.02,
                                  remainingSeconds: max(1, livePlan.computeSeconds))
        startProgressTimer()

        let params = settings.genParams()
        var refAudio: [Float]?
        var refText: String?
        if let voice = selectedVoice {
            if let loaded = ExportService.readSamples(at: voice.url) {
                refAudio = ExportService.resample(loaded.samples,
                                                  from: loaded.sampleRate,
                                                  to: SpeechEngine.shared.sampleRate)
                refText = voice.refText
            }
        }

        // Stream playback is opt-in: off (default) the whole clip is decoded in
        // one vocoder flush — measurably faster — and plays when it is done.
        let streaming = settings.streamPlayback
        if streaming {
            player.begin()
        }

        let rate = SpeechEngine.shared.sampleRate
        SpeechEngine.shared.generate(text: trimmed,
                                     params: params,
                                     refAudio: refAudio,
                                     refText: refText,
                                     streaming: streaming,
                                     onChunk: { [weak self] chunk in
            guard let self else { return }
            if self.firstChunkAt == nil {
                self.firstChunkAt = Date().timeIntervalSince(self.generationStarted ?? Date())
            }
            self.generatedSamples.append(contentsOf: chunk)
            self.audioSeconds = Double(self.generatedSamples.count) / rate
            if streaming {
                self.player.enqueue(chunk)
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            let compute = Date().timeIntervalSince(self.generationStarted ?? Date())
            self.generationSeconds = compute
            self.stopProgressTimer()
            self.runProgress = nil
            self.player.finish()
            switch result {
            case .success(let samples):
                self.generatedSamples = samples
                self.audioSeconds = Double(samples.count) / rate
                self.phase = .done
                if samples.isEmpty {
                    self.playback.unload()
                    self.statusLine = "生成结束，但没有音频输出"
                } else {
                    // Teach the estimator what this machine really did.
                    self.estimator.record(modelID: self.calibrationModelID,
                                          text: trimmed,
                                          audioSeconds: self.audioSeconds,
                                          computeSeconds: compute,
                                          firstChunkSeconds: self.firstChunkAt ?? 0,
                                          loadSeconds: self.runLoadSeconds,
                                          streaming: streaming)
                    let saved = self.finishRun(text: trimmed, params: params, computeSeconds: compute)
                    self.attachPlayback(savedURL: saved)
                    if !streaming {
                        self.playback.play()
                    }
                }
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
                self.statusLine = "生成失败：\(error.localizedDescription)"
            }
        })
    }

    @discardableResult
    private func finishRun(text trimmed: String, params: GenParams, computeSeconds: Double) -> URL? {
        let name = ExportService.suggestedFileName(for: trimmed)
        let folder = settings.exportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        var savedPath: String?
        var savedURL: URL?
        do {
            try ExportService.writeWAV(samples: generatedSamples,
                                       sampleRate: SpeechEngine.shared.sampleRate,
                                       to: url)
            savedPath = url.path
            savedURL = url
            lastExportedURL = url
        } catch {
            NSLog("BreezeTTS: export failed \(error.localizedDescription)")
        }

        statusLine = String(format: "完成 · 音频 %.1fs · 用时 %.1fs",
                            audioSeconds, generationSeconds)

        history.add(HistoryItem(text: trimmed,
                                instruction: params.instruction,
                                modelID: settings.resolvedSpec.id,
                                voiceName: selectedVoice?.name,
                                durationSeconds: audioSeconds,
                                wavPath: savedPath,
                                seed: params.seed,
                                computeSeconds: computeSeconds))
        return savedURL
    }

    /// Points the transport at the clip that was just produced.
    private func attachPlayback(savedURL: URL?) {
        guard !generatedSamples.isEmpty else {
            playback.unload()
            return
        }
        if let savedURL, playback.load(url: savedURL) { return }

        // Export failed: encode once into the cache so ⏯ still works.
        Paths.ensureDirectories()
        let scratch = Paths.cache.appendingPathComponent("last-generation.wav")
        if (try? ExportService.writeWAV(samples: generatedSamples,
                                        sampleRate: SpeechEngine.shared.sampleRate,
                                        to: scratch)) != nil {
            playback.load(url: scratch)
        }
    }

    func stop() {
        SpeechEngine.shared.cancel()
        player.stop()
        if playback.isPlaying { playback.pause() }
        stopProgressTimer()
        runProgress = nil
        phase = .done
        statusLine = "已停止"
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let started = self.generationStarted else { return }
            let elapsed = Date().timeIntervalSince(started)
            self.generationSeconds = elapsed
            if let plan = self.runForecast {
                self.runProgress = self.estimator.progress(forecast: plan,
                                                           elapsed: elapsed,
                                                           producedAudio: self.audioSeconds)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Audiobook (小说听书)

    /// How a character speaks. `auto` derives the style from the parsed age /
    /// personality tags; otherwise a preset style or a saved voice wins.
    struct RoleAssignment: Equatable {
        var mode: Mode = .auto
        var styleID: String = ""
        var voiceID: UUID?

        enum Mode: String { case auto, style, voice }
    }

    @Published var audiobookText = ""
    @Published var audiobookSegments: [StorySegment] = []
    @Published var audiobookCharacters: [StoryCharacter] = []
    @Published var audiobookRoles: [UUID: RoleAssignment] = [:]
    /// Narration voice overrides ("narration" row); nil = 沉稳旁白 preset.
    @Published var narrationStyleID: String?
    @Published var narrationVoiceID: UUID?
    /// nil = idle; otherwise 0…1 across the whole story.
    @Published var audiobookProgress: Double?
    @Published var audiobookStatus = ""
    /// History id of the finished audiobook WAV, so the iPhone can download it
    /// (GET /audio/h/<id>) and the sheet can offer a local save.
    @Published var audiobookAudioID: String?
    @Published var audiobookAudioDuration: Double = 0
    /// True while the analyzer (cloud or local LLM) is working.
    @Published var audiobookAnalyzing = false
    private var audiobookCancelled = false
    private var audiobookSamples: [Float] = []
    /// 听书预计剩余时间：用已完成段的平均耗时推算。
    @Published var audiobookRemaining: Double?
    private var audiobookRunStarted: Date?
    /// Remote (iPhone) run progress bookkeeping, read by progressProvider.
    private var remoteRunStarted: Date?
    private var remoteRunExpected: Double = 0

    // MARK: 听书角色档案 / 基准音色

    /// 正在生成基准参考音色的角色；nil = 空闲。
    @Published var refGeneratingID: UUID?
    @Published var refStatus = ""
    /// 有角色面板被请求弹出（自动弹出或点行），sheet 读取后清空。
    @Published var pendingRoleEditorID: UUID?
    /// 正在为哪些角色补人设（任务 A）。
    @Published var profileFilling = false

    func analyzeStory() {
        let trimmed = audiobookText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            audiobookStatus = "文本太短，粘贴一段小说试试"
            audiobookAnalyzing = false
            return
        }
        audiobookAnalyzing = true
        // Engine routing: cloud (zero local memory) → local LLM → rules.
        // Choosing cloud never starts the llama process.
        let cloud = settings.storyBackend == .cloud ? settings.cloudConfig : nil
        if let cloud {
            audiobookStatus = "正在用云端 API 分析（不占用本地内存）…"
            let source = audiobookText
            StoryAnalyzer.analyze(text: source, cloud: cloud, progress: { [weak self] step in
                self?.audiobookStatus = step
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    self.applyAnalyzed(outcome)
                case .failure(let error):
                    self.applyRuleParsing(source, note: "云端与本地分析都失败（\(error.message)），已用规则解析")
                }
            }
        } else if StoryAnalyzer.available {
            audiobookStatus = "正在用本地模型分析人物与情绪…"
            let source = audiobookText
            StoryAnalyzer.analyze(text: source, cloud: nil, progress: { [weak self] step in
                self?.audiobookStatus = step
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    self.applyAnalyzed(outcome)
                case .failure(let error):
                    self.applyRuleParsing(source, note: "本地模型分析失败（\(error.message)），已用规则解析")
                }
            }
        } else if settings.storyBackend == .cloud, settings.cloudAPIKey.isEmpty {
            applyRuleParsing(trimmed, note: "未填写云端 API Key（设置 → 听书分析），已用规则解析")
        } else {
            applyRuleParsing(trimmed, note: "未安装分析模型，已用规则解析（对话/说话人靠引号与提示词推断）")
        }
    }

    /// Installs a successful analyzer outcome into the sheet state.
    private func applyAnalyzed(_ outcome: StoryAnalyzer.Outcome) {
        audiobookSegments = outcome.segments
        audiobookCharacters = outcome.characters
        audiobookAnalyzing = false
        let dialogues = outcome.segments.filter(\.isDialogue).count
        audiobookStatus = "识别出 \(outcome.characters.count) 个人物 · \(dialogues) 句对话 · \(outcome.segments.count - dialogues) 段旁白 · 声线已锁定，逐句情绪可变"
        afterCastChanged()
    }

    private func applyRuleParsing(_ text: String, note: String) {
        audiobookSegments = StoryParser.segments(in: text)
        audiobookCharacters = StoryParser.characters(from: audiobookSegments, fullText: text)
        audiobookAnalyzing = false
        let ids = Set(audiobookCharacters.map(\.id))
        audiobookRoles = audiobookRoles.filter { ids.contains($0.key) }
        let dialogues = audiobookSegments.filter(\.isDialogue).count
        audiobookStatus = "\(note) · \(audiobookCharacters.count) 个人物 · \(dialogues) 句对话"
        afterCastChanged()
    }

    func cancelAudiobook() {
        audiobookCancelled = true
        SpeechEngine.shared.cancel()
    }

    // MARK: Remote audiobook (driven from the iPhone)

    /// iPhone sent a story: fill the same state the local sheet uses, wait for
    /// the analyzer to settle, then report the discovered characters.
    func remoteAudiobookAnalyze(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audiobookText = text
            self.audiobookSegments = []
            self.audiobookCharacters = []
            self.audiobookRoles = [:]
            self.analyzeStory()
            var waited = 0.0
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if !self.audiobookCharacters.isEmpty {
                    timer.invalidate()
                    completion(.success(()))
                } else if waited > 300 {
                    timer.invalidate()
                    completion(.failure(NSError(domain: "BreezeTTS.Remote", code: 10,
                                                userInfo: [NSLocalizedDescriptionKey: "分析超时"])))
                }
                waited += 1
            }
            _ = timer
        }
    }

    /// iPhone pressed 生成: run the chained synthesis and return the joined WAV.
    func remoteAudiobookGenerate(completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let baseline = self.history.items.first?.id
            self.audiobookCancelled = false
            self.generateAudiobook()
            var waited = 0.0
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let finished = self.audiobookProgress == nil && !self.audiobookSegments.isEmpty
                if finished, self.audiobookStatus.hasPrefix("完成"),
                   let fresh = self.history.items.first(where: { $0.id != baseline }), let url = fresh.url {
                    timer.invalidate()
                    completion(.success(url))
                } else if finished || waited > 7200 {
                    timer.invalidate()
                    completion(.failure(NSError(domain: "BreezeTTS.Remote", code: 11,
                                                userInfo: [NSLocalizedDescriptionKey: self.audiobookStatus.isEmpty ? "合成失败" : self.audiobookStatus])))
                }
                waited += 2
            }
        }
    }

    /// Voice choice for a role: explicit assignment → age/personality preset.
    func roleInstruction(_ character: StoryCharacter?) -> String {
        if character == nil {
            if let id = narrationVoiceID,
               let voice = voices.voices.first(where: { $0.id == id && $0.isTextVoice }),
               let wording = voice.instruction { return wording }
            if let id = narrationStyleID, let style = VoiceStyles.style(id: id) {
                return style.instruction
            }
            return VoiceStyles.style(id: "steady")?.instruction ?? VoiceStyles.neutral.instruction
        }
        guard let character else {
            // Narration.
            return VoiceStyles.style(id: "steady")?.instruction ?? VoiceStyles.neutral.instruction
        }
        if let role = audiobookRoles[character.id] {
            switch role.mode {
            case .style:
                if let style = VoiceStyles.style(id: role.styleID) { return style.instruction }
            case .voice:
                if let id = role.voiceID,
                   let voice = voices.voices.first(where: { $0.id == id && $0.isTextVoice }),
                   let wording = voice.instruction { return wording }
            case .auto:
                break
            }
        }
        // 没有显式选声线时，角色档案就是底色：年龄 + 性别 + 音色特征。
        // 这一步只在「还没生成基准 ref」时用得上；生成过 ref 的角色走 ref 链路。
        let base = character.baseInstruction
        if !base.isEmpty {
            return base
        }
        return VoiceStyles.style(id: StoryParser.presetID(age: character.age,
                                                          personality: character.personality))?
            .instruction ?? VoiceStyles.neutral.instruction
    }

    /// Clone voice chosen for a role (or narration), if any.
    private func roleCloneVoice(_ character: StoryCharacter?) -> VoiceMeta? {
        let id: UUID?
        if character == nil {
            id = narrationVoiceID
        } else if let character, let role = audiobookRoles[character.id], role.mode == .voice {
            id = role.voiceID
        } else {
            id = nil
        }
        guard let voiceID = id else { return nil }
        return voices.voices.first { $0.id == voiceID && !$0.isTextVoice }
    }

    // Role setters used by the audiobook sheet.

    func setAudiobookRole(_ id: UUID, style: VoiceStyle) {
        var role = audiobookRoles[id] ?? .init()
        role.mode = .style
        role.styleID = style.id
        role.voiceID = nil
        audiobookRoles[id] = role
    }

    func setAudiobookRole(_ id: UUID, voice: VoiceMeta) {
        var role = audiobookRoles[id] ?? .init()
        role.mode = .voice
        role.voiceID = voice.id
        audiobookRoles[id] = role
    }

    func setAudiobookRole(_ id: UUID, auto: Bool) {
        audiobookRoles[id] = .init()
    }

    func setAudiobookRole(roleID: String, style: VoiceStyle) {
        guard roleID == "narration" else { return }
        narrationStyleID = style.id
        narrationVoiceID = nil
    }

    func setAudiobookRole(roleID: String, voice: VoiceMeta) {
        guard roleID == "narration" else { return }
        narrationVoiceID = voice.id
        narrationStyleID = nil
    }

    func setAudiobookRole(roleID: String, auto: Bool) {
        guard roleID == "narration" else { return }
        narrationStyleID = nil
        narrationVoiceID = nil
    }

    func setAudiobookAge(_ id: UUID, tag: String) {
        if let index = audiobookCharacters.firstIndex(where: { $0.id == id }) {
            audiobookCharacters[index].age = tag
            audiobookRoles[id] = .init()   // tags changed → back to auto
        }
    }

    func setAudiobookPersonality(_ id: UUID, tag: String) {
        if let index = audiobookCharacters.firstIndex(where: { $0.id == id }) {
            audiobookCharacters[index].personality = tag
            audiobookRoles[id] = .init()
        }
    }

    /// Synthesizes the whole story segment by segment, chaining engine runs.
    func generateAudiobook() {
        guard phase != .generating else { return }
        guard !audiobookSegments.isEmpty else {
            audiobookStatus = "先分析文本"
            return
        }
        guard modelFileURL != nil, isModelLoaded || modelReady else {
            audiobookStatus = "先在主界面加载模型"
            return
        }

        // Merge adjacent same-speaker segments only when their delivery hint
        // matches — different emotions need separate passes to sound right.
        var plan: [(speaker: String?, text: String, hint: String?)] = []
        for segment in audiobookSegments {
            if let last = plan.last, last.speaker == segment.speaker, last.hint == segment.hint {
                plan[plan.count - 1].text += " " + segment.text
            } else {
                plan.append((segment.speaker, segment.text, segment.hint))
            }
        }

        phase = .generating
        audiobookCancelled = false
        audiobookSamples = []
        audiobookProgress = 0
        audiobookRunStarted = Date()
        audiobookRemaining = nil
        playback.unload()
        audiobookStatus = "开始合成 \(plan.count) 段…"

        let params = settings.genParams()
        let rate = SpeechEngine.shared.sampleRate

        func character(named speaker: String?) -> StoryCharacter? {
            speaker.flatMap { name in audiobookCharacters.first { $0.name == name } }
        }

        func run(index: Int) {
            guard !audiobookCancelled, index < plan.count else {
                stopProgressTimer()
                phase = .idle
                audiobookProgress = nil
                audiobookRunStarted = nil
                audiobookRemaining = nil
                if audiobookCancelled {
                    audiobookStatus = "已取消"
                } else if audiobookSamples.isEmpty {
                    audiobookStatus = "生成结束，但没有音频输出"
                } else {
                    finishAudiobook(rate: rate)
                }
                return
            }

            let item = plan[index]
            let character = character(named: item.speaker)
            // 两条链路要分开：有基准 ref 时，音色由 ref 锁死，提示词只写情绪；
            // 没有 ref 时才退回「人设 / 预设声线 + 情绪」的写法。
            var instruction = roleInstruction(character)
            var refAudio: [Float]?
            var refText: String?
            if let character, let ref = referenceSamples(for: character) {
                refAudio = ref.samples
                refText = character.refText
                instruction = item.hint ?? ""
            } else if let clone = roleCloneVoice(character),
                      let loaded = ExportService.readSamples(at: clone.url) {
                refAudio = ExportService.resample(loaded.samples,
                                                  from: loaded.sampleRate,
                                                  to: rate)
                refText = clone.refText
                // A clone's own timbre wins; only the emotion hint survives.
                instruction = item.hint ?? ""
            } else if let hint = item.hint, !hint.isEmpty {
                instruction = instruction.isEmpty ? hint : instruction + ", " + hint
            }

            audiobookStatus = "第 \(index + 1)/\(plan.count) 段 · \(item.speaker == nil ? "旁白" : item.speaker!) · \(item.text.prefix(12))…"

            SpeechEngine.shared.generate(text: item.text,
                                         params: GenParams(instruction: instruction,
                                                           seed: params.seed,
                                                           cfgScale: params.cfgScale,
                                                           maxNewTokens: params.maxNewTokens,
                                                           splitChars: params.splitChars,
                                                           temperature: params.temperature,
                                                           topK: params.topK,
                                                           topP: params.topP,
                                                           repetitionPenalty: params.repetitionPenalty),
                                         refAudio: refAudio,
                                         refText: refText,
                                         streaming: false,
                                         onChunk: { [weak self] chunk in
                                             self?.audiobookSamples.append(contentsOf: chunk)
                                         },
                                         completion: { [weak self] _ in
                guard let self else { return }
                self.audiobookProgress = Double(index + 1) / Double(plan.count)
                // 预计剩余：已完成段的平均耗时 × 剩余段数。
                if let started = self.audiobookRunStarted, index + 1 < plan.count {
                    let elapsed = Date().timeIntervalSince(started)
                    let perSegment = elapsed / Double(index + 1)
                    self.audiobookRemaining = perSegment * Double(plan.count - index - 1)
                } else {
                    self.audiobookRemaining = nil
                }
                run(index: index + 1)
            })
        }
        run(index: 0)
    }

    /// Saves the concatenated audiobook, files it into history and hooks up ⏯.
    private func finishAudiobook(rate: Double) {
        let samples = audiobookSamples
        let duration = Double(samples.count) / rate
        Paths.ensureDirectories()
        let stamp = Int(Date().timeIntervalSince1970)
        let url = Paths.cache.appendingPathComponent("audiobook-\(stamp).wav")
        do {
            try ExportService.writeWAV(samples: samples, sampleRate: rate, to: url)
            playback.load(url: url)
            playback.play()
            let firstLine = audiobookText.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = HistoryItem(text: String(firstLine.prefix(60)),
                                   instruction: "听书模式",
                                   modelID: estimateModelID,
                                   voiceName: "听书",
                                   durationSeconds: duration,
                                   wavPath: url.path,
                                   seed: settings.seed)
            history.add(item)
            audiobookAudioID = item.id.uuidString
            audiobookAudioDuration = duration
            audiobookStatus = "完成 · \(DurationText.short(duration))音频，已开始播放"
        } catch {
            audiobookStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Remote (iPhone)

    /// Same pipeline as the main window's run, but stateless: the iPhone picks
    /// the text (and optionally the style), the Mac does all the compute.
    private func generateRemote(text: String, instruction: String?,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        var params = settings.genParams()
        if let instruction, !instruction.isEmpty { params.instruction = instruction }
        // The remote run bypasses the local UI estimator, so drive a time-based
        // progress curve here — the phone polls /job and mirrors it.
        let chars = max(1, text.count)
        let expected = Double(chars) * 0.8      // measured: ~0.8 s per char in flush mode
        // No timers needed: progressProvider derives the curve on demand.
        DispatchQueue.main.async { [weak self] in
            self?.remoteRunStarted = Date()
            self?.remoteRunExpected = expected
        }
        func finishProgress() {
            DispatchQueue.main.async { [weak self] in
                self?.remoteRunStarted = nil
                self?.remoteRunExpected = 0
                self?.runProgress = nil
            }
        }
        var refAudio: [Float]?
        var refText: String?
        if let voice = selectedVoice,
           let loaded = ExportService.readSamples(at: voice.url) {
            refAudio = ExportService.resample(loaded.samples,
                                              from: loaded.sampleRate,
                                              to: SpeechEngine.shared.sampleRate)
            refText = voice.refText
        }
        let rate = SpeechEngine.shared.sampleRate
        SpeechEngine.shared.generate(text: text,
                                     params: params,
                                     refAudio: refAudio,
                                     refText: refText,
                                     streaming: false,
                                     onChunk: { _ in },
                                     completion: { [weak self] result in
            guard let self else { return }
            finishProgress()
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let samples):
                guard !samples.isEmpty else {
                    completion(.failure(NSError(domain: "BreezeTTS.Remote", code: 4,
                                                userInfo: [NSLocalizedDescriptionKey: "没有音频输出"])))
                    return
                }
                Paths.ensureDirectories()
                let url = Paths.cache.appendingPathComponent("remote-\(Int(Date().timeIntervalSince1970)).wav")
                do {
                    try ExportService.writeWAV(samples: samples, sampleRate: rate, to: url)
                    // Remote runs land in the same history the Mac UI shows.
                    history.add(HistoryItem(text: String(text.prefix(60)),
                                            instruction: params.instruction,
                                            modelID: activeSpec.id,
                                            voiceName: voiceLabel,
                                            durationSeconds: Double(samples.count) / rate,
                                            wavPath: url.path,
                                            seed: params.seed))
                    completion(.success(url))
                } catch {
                    completion(.failure(error))
                }
            }
        })
    }

    // MARK: - Chat speech（对话回复朗读）

    /// 用当前音色把一段短文本读出来（引擎队列串行，不会打断正在跑的合成）。
    /// 合成并播放回复语音。用引擎流式模式：音频分块到达即播放，
    /// 长回复不用等整段合成完；progress 实时报 0…1（已生成秒数 ÷ 估算总时长）。
    func speakChat(_ text: String, progress: ((Double) -> Void)? = nil,
                   completion: @escaping () -> Void) {
        guard let url = modelFileURL, !text.isEmpty else { completion(); return }
        var params = settings.genParams()
        if params.instruction.isEmpty { params.instruction = "Speak clearly and naturally." }
        let rate = SpeechEngine.shared.sampleRate
        // 主界面选中的克隆音色同样作用于对话朗读。
        var refAudio: [Float]?
        var refText: String?
        if let voice = selectedVoice,
           let loaded = ExportService.readSamples(at: voice.url) {
            refAudio = ExportService.resample(loaded.samples,
                                              from: loaded.sampleRate,
                                              to: rate)
            refText = voice.refText
        }
        // 估算总时长（与 GenerationEstimator 同一套先验：6.2 字/秒 + 首尾静音）。
        let units = Double(min(1500, text.count))
        let estimatedTotal = max(1, units / 6.2 + 0.45)
        // onChunk 可能在引擎线程回调，累计值加锁。
        final class Counter {
            let lock = NSLock()
            let rate: Double
            var samples = 0
            init(sampleRate: Double) { rate = sampleRate }
            func add(_ n: Int) { lock.lock(); samples += n; lock.unlock() }
            var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(samples) / rate }
        }
        let counter = Counter(sampleRate: rate)
        let run: () -> Void = { [weak self] in
            guard let self else { return }
            // 流式播放：清掉上一段残留缓冲，开始接收新流。
            self.player.stop()
            self.player.configure(sampleRate: rate)
            self.player.begin()
            SpeechEngine.shared.generate(text: String(text.prefix(1500)),
                                         params: params,
                                         refAudio: refAudio,
                                         refText: refText,
                                         streaming: true,
                                         onChunk: { chunk in
                                             counter.add(chunk.count)
                                             progress?(min(0.99, counter.seconds / estimatedTotal))
                                         },
                                         completion: { _ in
                                             progress?(1)
                                             self.player.finish()
                                             completion()
                                         })
        }
        if isModelLoaded {
            run()
        } else {
            SpeechEngine.shared.load(path: url.path, useGPU: settings.useGPU) { _ in run() }
        }
    }

    // MARK: - Playback / export

    /// Play / pause the finished clip. The streaming engine is silenced first so
    /// a lingering tail can never overlap with the file.
    func togglePlayback() {
        guard playback.hasAudio else { return }
        if playback.isPlaying {
            playback.pause()
        } else {
            player.stop()
            playback.play()
        }
    }

    func seekPlayback(to progress: Double) {
        playback.seek(toProgress: progress)
    }

    func playHistory(_ item: HistoryItem) {
        guard let url = item.url else { return }
        if playback.currentURL == url {
            togglePlayback()
            return
        }
        player.stop()
        playback.play(url: url)
    }

    func exportLast() {
        guard !generatedSamples.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = ExportService.suggestedFileName(for: text)
        panel.directoryURL = settings.exportFolder
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ExportService.writeWAV(samples: generatedSamples,
                                           sampleRate: SpeechEngine.shared.sampleRate,
                                           to: url)
                lastExportedURL = url
                statusLine = "已导出到 \(url.lastPathComponent)"
            } catch {
                statusLine = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Models

    func download(_ spec: ModelSpec) {
        downloader.start(spec)
    }

    func cancelDownload(_ spec: ModelSpec) {
        downloader.cancel(spec)
    }

    func deleteModel(_ spec: ModelSpec) {
        if isModelLoaded, activeModelPath == spec.fileURL.path {
            SpeechEngine.shared.unload()
            activeModelPath = nil
            phase = .idle
        }
        downloader.deleteFile(spec)
    }

    func selectTier(_ id: String?) {
        settings.overrideTierID = id
    }

    /// Calls come from `.fileImporter` inside the sheets — never open an
    /// `NSOpenPanel` modally there, the sheet's own modal session swallows it.
    func importModel(from url: URL) {
        Paths.ensureDirectories()
        let destination = Paths.models.appendingPathComponent(url.lastPathComponent)
        do {
            if Paths.exists(destination) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: url, to: destination)
            settings.customModelPath = destination.path
            statusLine = "已导入 \(destination.lastPathComponent)"
            SpeechEngine.shared.unload()
            activeModelPath = nil
            loadModel(at: destination)
        } catch {
            statusLine = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Voice cloning

    func saveRecordedVoice(name: String, refText: String, instruction: String = "") {
        let samples = recorder.stop()
        guard samples.count > 2_000 else {
            statusLine = "录音太短，至少说一句完整的话"
            return
        }
        do {
            let meta = try voices.add(name: name.isEmpty ? "我的音色" : name,
                                      samples: samples,
                                      sampleRate: SpeechEngine.shared.sampleRate,
                                      refText: refText,
                                      instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            selectedVoiceID = meta.id
            // 参考音频为主，文字辅助描述（如有）叠加为指令。
            settings.instruction = meta.instruction ?? ""
            statusLine = "已保存音色「\(meta.name)」"
            recorder.discard()
        } catch {
            statusLine = "保存音色失败：\(error.localizedDescription)"
        }
    }

    /// Loads an existing clip as the pending take, so the recorder sheet can
    /// review it, name it and fill in the transcript before saving.
    @discardableResult
    func stageReferenceClip(from url: URL) -> Bool {
        guard let loaded = ExportService.readSamples(at: url) else {
            statusLine = "无法读取该音频文件：\(url.lastPathComponent)"
            return false
        }
        recorder.stage(samples: loaded.samples, sampleRate: loaded.sampleRate)
        guard recorder.hasTake else {
            statusLine = "这个文件里没有可用音频"
            return false
        }
        statusLine = "已载入 \(url.lastPathComponent)，填好名称和逐字稿再保存"
        return true
    }

    /// Saves an existing audio file as a reference clip straight away.
    @discardableResult
    func importReferenceVoice(from url: URL, name: String, refText: String) -> Bool {
        guard let loaded = ExportService.readSamples(at: url) else {
            statusLine = "无法读取该音频文件：\(url.lastPathComponent)"
            return false
        }
        let resampled = ExportService.resample(loaded.samples,
                                               from: loaded.sampleRate,
                                               to: SpeechEngine.shared.sampleRate)
        guard resampled.count > 2_000 else {
            statusLine = "这段音频太短，至少 5 秒效果才好"
            return false
        }
        do {
            let meta = try voices.add(name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                                      samples: resampled,
                                      sampleRate: SpeechEngine.shared.sampleRate,
                                      refText: refText)
            selectedVoiceID = meta.id
            statusLine = refText.isEmpty
                ? "已导入「\(meta.name)」，但没填参考文本，克隆效果会不稳"
                : "已导入参考音色「\(meta.name)」"
            return true
        } catch {
            statusLine = "导入失败：\(error.localizedDescription)"
            return false
        }
    }

    func clearSelection() {
        selectedVoiceID = nil
    }
}
