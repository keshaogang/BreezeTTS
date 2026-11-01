import AppKit
import Foundation
import Speech
import SwiftUI

/// Command line modes used for verification and for grabbing screenshots without
/// a window server session:
///
///   BreezeTTS --snapshot /tmp/ui.png [main|onboarding]   render a screen to PNG
///   BreezeTTS --smoke model.gguf out.wav "文本"          run the real bridge end to end
///
/// Both exit before the app run loop starts, so they never touch the UI state.
enum Headless {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        // `exit(0)` from a redirected stdout would otherwise drop every line.
        setvbuf(stdout, nil, _IONBF, 0)
        #if DEBUG
        if runRequestFileIfPresent() { return true }
        #endif
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            let mode = args.count > index + 2 ? args[index + 2] : "main"
            renderSnapshot(mode: mode, to: args[index + 1])
            return true
        }
        if let index = args.firstIndex(of: "--reftest"), args.count > index + 1 {
            runRefTest(outDir: args[index + 1])
            return true
        }
        if let index = args.firstIndex(of: "--smoke"), args.count > index + 3 {
            runSmoke(modelPath: args[index + 1], outPath: args[index + 2], text: args[index + 3],
                     useGPU: !args.contains("--cpu"))
            return true
        }
        if let index = args.firstIndex(of: "--playtest"), args.count > index + 1 {
            runPlayTest(url: URL(fileURLWithPath: args[index + 1]))
            return true
        }
        if let index = args.firstIndex(of: "--voicetest"), args.count > index + 1 {
            runVoiceTest(url: URL(fileURLWithPath: args[index + 1]))
            return true
        }
        if let index = args.firstIndex(of: "--recommend"), args.count > index + 1 {
            for pick in VoiceAdvisor.recommend(for: args[index + 1], limit: 5) {
                print(String(format: "%-10@ %5.2f  %@",
                             pick.style.id as NSString, pick.score, pick.reason as NSString))
            }
            return true
        }
        if let index = args.firstIndex(of: "--estimate"), args.count > index + 1 {
            runEstimateTest(text: args[index + 1],
                            modelID: args.count > index + 2 && !args[index + 2].hasPrefix("--")
                                ? args[index + 2] : "q8_0")
            return true
        }
        if let index = args.firstIndex(of: "--runtest"), args.count > index + 1 {
            runGenerationTest(text: args[index + 1])
            return true
        }
        if let index = args.firstIndex(of: "--asr"), args.count > index + 1 {
            let outIndex = args.firstIndex(of: "--out")
            runTranscribeTest(url: URL(fileURLWithPath: args[index + 1]),
                              locale: args.count > index + 2 && !args[index + 2].hasPrefix("--")
                                  ? args[index + 2] : SpeechTranscriber.autoID,
                              allowNetwork: args.contains("--net"),
                              logPath: outIndex.map { args[$0 + 1] })
            return true
        }
        return false
    }

    private final class Flag {
        var raised = false
    }

    #if DEBUG
    /// Development hook: `open -n App --args …` does not forward arguments on
    /// every macOS build, but speech recognition only behaves under a real
    /// LaunchServices launch (TCC aborts anything started from a terminal). A
    /// JSON request file bridges the two:
    ///
    ///     {"mode":"asr","input":"/tmp/clip.wav","locale":"zh-CN","out":"/tmp/r.txt"}
    ///
    /// Debug builds only; the release app has no such entry point.
    @MainActor
    private static func runRequestFileIfPresent() -> Bool {
        let url = URL(fileURLWithPath: "/tmp/breeze-headless.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = object["mode"] as? String else { return false }
        try? FileManager.default.removeItem(at: url)

        if mode == "asr", let input = object["input"] as? String {
            runTranscribeTest(url: URL(fileURLWithPath: input),
                              locale: object["locale"] as? String ?? SpeechTranscriber.autoID,
                              allowNetwork: object["net"] as? Bool ?? false,
                              logPath: object["out"] as? String)
            return true
        }
        return false
    }
    #endif

    /// Runs the recogniser over a real WAV so the transcription path can be
    /// checked without clicking through the sheet.
    ///
    /// Speech authorisation goes through TCC, which aborts any process that was
    /// not started by LaunchServices — launch it with
    /// `open -n BreezeTTS.app --args --asr clip.wav --out result.txt` rather than
    /// executing the binary directly.
    @MainActor
    private static func runTranscribeTest(url: URL, locale: String, allowNetwork: Bool, logPath: String?) {
        var lines: [String] = []
        func emit(_ line: String) {
            print(line)
            lines.append(line)
            if let logPath {
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }

        guard let loaded = ExportService.readSamples(at: url) else {
            emit("cannot_read: \(url.path)")
            return
        }
        emit(String(format: "samples=%d rate=%.0f duration=%.2f",
                    loaded.samples.count, loaded.sampleRate,
                    Double(loaded.samples.count) / max(loaded.sampleRate, 1)))
        emit("on_device_zh=\(SpeechTranscriber.supportsOnDeviceChinese ? 1 : 0)")
        emit("auth_before=\(SFSpeechRecognizer.authorizationStatus().rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        emit("locale=\(locale) network=\(allowNetwork ? 1 : 0)")

        // The consent sheet only shows up for a foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let transcriber = SpeechTranscriber()
        let flag = Flag()
        Task { @MainActor in
            let outcome = await transcriber.transcribe(samples: loaded.samples,
                                                       sampleRate: loaded.sampleRate,
                                                       locale: locale,
                                                       allowNetwork: allowNetwork)
            if let outcome {
                emit("ok=1 on_device=\(outcome.onDevice ? 1 : 0) locale=\(outcome.localeID)")
                emit("text=\(outcome.text)")
            } else {
                emit("ok=0 status=\(transcriber.status)")
            }
            flag.raised = true
        }

        let deadline = Date().addingTimeInterval(120)
        while !flag.raised && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if !flag.raised { emit("timeout") }
    }

    /// Runs one real synthesis through `AppModel` so the estimate, the live
    /// countdown and the calibration write can be checked end to end.
    @MainActor
    private static func runGenerationTest(text: String) {
        let model = AppModel()
        guard model.modelReady else {
            print("no_model")
            return
        }
        model.text = text
        if let forecast = model.forecast {
            print(String(format: "forecast audio=%.2fs compute=%.1fs total=%.1fs label=%@ calibrated=%d",
                         forecast.audioSeconds, forecast.computeSeconds,
                         forecast.totalSeconds, forecast.totalLabel as NSString,
                         forecast.calibrated ? 1 : 0))
        }
        print("samples_before=\(model.estimator.sampleCount)")

        let started = Date()
        model.generate()
        var shown = -1
        while true {
            if case .done = model.phase { break }
            if case .failed = model.phase { break }
            if Date().timeIntervalSince(started) > 600 {
                print("timeout")
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let progress = model.runProgress {
                let percent = Int(progress.fraction * 100)
                if percent >= shown + 25 {
                    shown = percent
                    print(String(format: "  %@ remaining=%@ elapsed=%.1fs audio=%.2fs",
                                 progress.percentLabel as NSString,
                                 progress.remainingLabel as NSString,
                                 Date().timeIntervalSince(started),
                                 model.audioSeconds))
                }
            }
        }
        if case .failed(let message) = model.phase {
            print("failed=\(message)")
        }

        let wall = Date().timeIntervalSince(started)
        print(String(format: "actual wall=%.1fs compute=%.1fs audio=%.2fs samples=%d",
                     wall, model.generationSeconds, model.audioSeconds,
                     model.estimator.sampleCount))
        // A second pass must be calibrated now and land closer to reality.
        if let refined = model.forecast {
            print(String(format: "refined audio=%.2fs compute=%.1fs calibrated=%d",
                         refined.audioSeconds, refined.computeSeconds,
                         refined.calibrated ? 1 : 0))
        }
    }

    /// Prints the duration forecast for a text, so the arithmetic behind the
    /// footer label can be checked without starting a real run.
    private static func runEstimateTest(text: String, modelID: String) {
        let spec = ModelCatalog.spec(id: modelID) ?? ModelCatalog.all[1]
        let estimator = GenerationEstimator.shared
        let units = GenerationEstimator.units(in: text)
        let pauses = GenerationEstimator.pauses(in: text)
        let cold = estimator.forecast(for: text, modelID: spec.id,
                                      modelBytes: spec.bytes, modelLoaded: false)
        let warm = estimator.forecast(for: text, modelID: spec.id,
                                      modelBytes: spec.bytes, modelLoaded: true)

        print(String(format: "model=%@ chars=%d units=%.1f pauses=%.2f",
                     spec.id as NSString, text.count, units, pauses))
        print(String(format: "calibrated=%d samples=%d rtf=%.2f first_chunk=%.2f",
                     warm.calibrated ? 1 : 0, estimator.sampleCount,
                     warm.streamingRTF, warm.firstChunkSeconds))
        print(String(format: "audio=%.2fs compute=%.1fs load=%.1fs total=%.1fs",
                     warm.audioSeconds, warm.computeSeconds, cold.loadSeconds, cold.totalSeconds))
        print("label=\(cold.totalLabel) detail=\(cold.detail)")

        // The same run seen at several points: the countdown must stay sane and
        // must not jump backwards.
        for fraction in [0.1, 0.25, 0.5, 0.9] {
            let elapsed = warm.computeSeconds * fraction
            let progress = estimator.progress(forecast: warm,
                                              elapsed: elapsed,
                                              producedAudio: warm.audioSeconds * fraction)
            print(String(format: "  at %3.0f%% elapsed=%6.1fs -> %@ remaining=%@",
                         fraction * 100, elapsed,
                         progress.percentLabel as NSString,
                         progress.remainingLabel as NSString))
        }
    }

    /// Verifies the reference-clip import path and the recorder's take preview
    /// against a real file, then removes the voice it created.
    private static func runVoiceTest(url: URL) {
        let model = AppModel()
        print("voices_before=\(model.voices.voices.count)")

        let imported = model.importReferenceVoice(from: url, name: "导入自检", refText: "这是参考音频。")
        print("imported=\(imported ? 1 : 0) status=\(model.statusLine)")
        print("voices_after=\(model.voices.voices.count)")
        if let added = model.voices.voices.first(where: { $0.name == "导入自检" }) {
            print(String(format: "voice duration=%.2f ref=%@ file=%@",
                         added.durationSeconds,
                         added.refText as NSString,
                         added.url.lastPathComponent as NSString))
            model.voices.delete(added)
            print("cleanup=\(model.voices.voices.count)")
        }

        let staged = model.stageReferenceClip(from: url)
        print(String(format: "staged=%d take=%.2f external=%d",
                     staged ? 1 : 0, model.recorder.takeDuration,
                     model.recorder.hasExternalTake ? 1 : 0))
        model.recorder.togglePreview()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        print(String(format: "preview playing=%d position=%.2f",
                     model.recorder.isPreviewing ? 1 : 0, model.recorder.previewPosition))
        model.recorder.stopPreview()
        print(String(format: "preview stopped=%d", model.recorder.isPreviewing ? 0 : 1))
    }

    /// Exercises the transport against a real WAV: play, pause, resume, seek.
    private static func runPlayTest(url: URL) {
        let transport = PlaybackService()
        guard transport.load(url: url) else {
            print("load failed: \(url.path)")
            return
        }
        print(String(format: "loaded duration=%.2f", transport.duration))

        transport.play()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        print(String(format: "playing=%d position=%.2f", transport.isPlaying ? 1 : 0, transport.currentTime))

        transport.pause()
        let frozen = transport.currentTime
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print(String(format: "paused=%d frozen=%.2f drift=%.3f",
                     transport.isPlaying ? 0 : 1, frozen, abs(transport.currentTime - frozen)))

        transport.play()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print(String(format: "resumed=%d position=%.2f", transport.isPlaying ? 1 : 0, transport.currentTime))

        transport.seek(toProgress: 0.5)
        print(String(format: "seeked position=%.2f progress=%.2f",
                     transport.currentTime, transport.progress))
        transport.stop()
    }

    @MainActor
    private static func renderSnapshot(mode: String, to path: String) {
        RenderMode.useGlass = false
        RenderMode.isPreview = true

        let dark = mode.hasPrefix("dark-")
        let base = dark ? String(mode.dropFirst(5)) : mode

        // A throwaway preference suite keeps snapshots reproducible: a hand-written
        // instruction would otherwise show up as "自定义" in every screenshot.
        let previewDefaults = UserDefaults(suiteName: "com.breeze.BreezeTTS.preview") ?? .standard
        let model = AppModel(settings: AppSettings(defaults: previewDefaults))
        let size: CGSize
        if base.hasPrefix("onboarding") {
            size = CGSize(width: 980, height: 720)
        } else if base == "recorder" {
            size = CGSize(width: 620, height: 660)
        } else if base == "voices" {
            size = CGSize(width: 460, height: 600)
        } else if base == "role" || base == "role-advanced" {
            size = CGSize(width: 520, height: 700)
        } else if base == "audiobook" {
            size = CGSize(width: 560, height: 640)
        } else if base == "voice-menu" {
            size = CGSize(width: 340, height: 330)
        } else {
            size = CGSize(width: 980, height: 700)
        }
        let screen: AnyView
        if base == "voice-menu" {
            // The popover has no chrome when rendered offscreen, so the harness
            // wraps it in the card it would normally sit on.
            model.text = "深夜的城市，那一年我们说过晚安。"
            screen = AnyView(
                VStack(spacing: 0) {
                    VoiceMenu(model: model, isPresented: .constant(true), onManage: {})
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: size.width, height: size.height)
            )
        } else if base == "recorder" {
            // Stage a tone so the review controls render in the screenshot.
            let rate = 24_000.0
            let count = Int(rate * 12.7)
            var tone = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let envelope = sin(Double(i) / rate * .pi / 12.7)
                tone[i] = Float(sin(Double(i) / rate * 2 * .pi * 220) * 0.25 * envelope)
            }
            model.recorder.stage(samples: tone, sampleRate: rate)
            screen = AnyView(RecorderSheet(model: model))
        } else if base == "voices" {
            // Seed one voice of each kind so both sections render populated.
            // The preview suite persists on disk, so replace rather than add.
            for existing in model.voices.voices where existing.isTextVoice && existing.name == "温柔女声" {
                model.voices.delete(existing)
            }
            model.saveTextVoice(name: "温柔女声", instruction: "语速偏慢，低声，带一点笑意。")
            screen = AnyView(VoiceSheet(model: model))
        } else if base == "role" || base == "role-advanced" {
            // 角色声线面板：铺一个已有人设的角色，看普通视图与生成按钮。
            let character = StoryCharacter(name: "林舟",
                                           age: "青年",
                                           personality: "沉稳",
                                           lines: 12,
                                           sample: "别急，先把灯关了。",
                                           ageDesc: "二十出头",
                                           gender: "男",
                                           feature: "柔和男中音，轻微气声，内敛冷静")
            model.audiobookCharacters = [character]
            model.refStatus = ""
            screen = AnyView(RoleEditorSheet(model: model,
                                             characterID: character.id,
                                             startAdvanced: base == "role-advanced"))
        } else if base == "audiobook" {
            // 听书主面板：两三个人物 + 若干分段，检查人物行与摘要在窄窗里的排版。
            var a = StoryCharacter(name: "林舟", age: "青年", personality: "沉稳",
                                   lines: 12, sample: "别急，先把灯关了。",
                                   ageDesc: "二十出头", gender: "男",
                                   feature: "柔和男中音，轻微气声，内敛冷静")
            a.refFile = "demo-ref.wav"
            var b = StoryCharacter(name: "沈晚", age: "少年", personality: "温柔",
                                   lines: 9, sample: "你终于回来了。",
                                   ageDesc: "十七八岁", gender: "女",
                                   feature: "清亮偏薄的少女音，气息轻，尾音带一点软")
            b.refFile = "demo-ref-2.wav"
            b.refStale = true
            let c = StoryCharacter(name: "老周", age: "中年", personality: "亲和",
                                   lines: 5, sample: "坐下说吧。",
                                   ageDesc: "四十多岁", gender: "男",
                                   feature: "沙哑的中年男声，语速慢，气息厚")
            model.audiobookCharacters = [a, b, c]
            model.audiobookSegments = [
                StorySegment(id: 0, speaker: nil, text: "雨停在半夜，楼道的灯还亮着。"),
                StorySegment(id: 1, speaker: "林舟", text: "别急，先把灯关了。", hint: "低沉，语速慢"),
                StorySegment(id: 2, speaker: "沈晚", text: "你终于回来了。", hint: "轻声，带一点哽咽"),
                StorySegment(id: 3, speaker: "老周", text: "坐下说吧。", hint: "温和，放缓"),
            ]
            model.audiobookText = "雨停在半夜，楼道的灯还亮着。"
            model.audiobookStatus = "识别出 3 个人物 · 3 句对话 · 1 段旁白 · 声线已锁定，逐句情绪可变"
            screen = AnyView(AudiobookSheet(model: model))
        } else if base.hasPrefix("onboarding") {
            let step: OnboardingView.Step = base == "onboarding-model" ? .model
                : (base == "onboarding-pair" ? .pair
                   : (base == "onboarding-ready" ? .ready : .welcome))
            screen = AnyView(OnboardingView(model: model, step: step)
                .frame(width: size.width, height: size.height))
        } else {
            if base == "running" {
                // Stage a run mid-flight so the progress row can be reviewed.
                model.phase = .generating
                model.audioSeconds = 2.7
                model.runProgress = RunProgress(fraction: 0.38, remainingSeconds: 68)
            }
            screen = AnyView(MainView(model: model).frame(width: size.width, height: size.height))
        }
        let view = screen.environment(\.colorScheme, dark ? .dark : .light)

        // ImageRenderer 是 macOS 13 的 API；12 上直接放弃截图，别为了截图
        // 把整个 App 的最低系统抬上去。
        guard #available(macOS 13.0, *) else {
            FileHandle.standardError.write(Data("snapshot requires macOS 13+\n".utf8))
            return
        }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot: \(path)")
    }

    /// 验证听书的两条链路：先用角色档案生成基准 ref，再用 ref 锁音色 + 单句情绪读正文。
    ///   BreezeTTS --reftest /tmp/refout
    ///
    /// 注意：所有回调都回到主队列，这里绝对不能拿信号量死等主线程——
    /// 那样回调永远排不上队，只能等到超时。用 RunLoop 泵着走。
    private static func runRefTest(outDir: String) {
        let models = (try? FileManager.default.contentsOfDirectory(at: Paths.models,
                                                                   includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "gguf" && $0.lastPathComponent.contains("breeze-tts-2") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        guard let model = models.first else {
            print("reftest: 找不到 breeze-tts-2 权重")
            return
        }
        print("reftest: model \(model.lastPathComponent)")

        let started = Date()
        var loaded = false
        SpeechEngine.shared.load(path: model.path, useGPU: true) { result in
            if case .failure(let error) = result {
                print("reftest: load failed \(error.localizedDescription)")
            }
            loaded = true
        }
        pump({ loaded }, timeout: 300)
        print(String(format: "reftest: load %.1fs rate %.0f", Date().timeIntervalSince(started),
                     SpeechEngine.shared.sampleRate))

        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                                 withIntermediateDirectories: true)
        let refURL = URL(fileURLWithPath: outDir).appendingPathComponent("role-ref.wav")
        try? FileManager.default.removeItem(at: refURL)

        // 链路 1：档案 → baseInstruction → 基准 ref
        var params = GenParams()
        params.instruction = "二十出头，男，柔和男中音，轻微气声，内敛冷静"
        params.seed = 42
        params.cfgScale = 4.0

        var refDone = false
        var refOK = false
        let refStart = Date()
        SpeechEngine.shared.generateToWAV(text: "今天天气不错，我们边走边说吧。",
                                          params: params,
                                          refAudio: nil,
                                          refText: nil,
                                          outURL: refURL) { result in
            switch result {
            case .success: refOK = true
            case .failure(let error): print("reftest: ref failed \(error.localizedDescription)")
            }
            refDone = true
        }
        pump({ refDone }, timeout: 300)
        print(String(format: "reftest: ref %@ %.1fs %@", refOK ? "ok" : "fail",
                     Date().timeIntervalSince(refStart),
                     Paths.size(of: refURL).humanBytes))
        guard refOK, let loadedRef = ExportService.readSamples(at: refURL) else { return }

        // 链路 2：ref 锁音色，提示词只写情绪
        var lineParams = GenParams()
        lineParams.instruction = "低沉，语速慢"
        lineParams.seed = 7
        lineParams.cfgScale = 1.0
        let lineURL = URL(fileURLWithPath: outDir).appendingPathComponent("line-with-ref.wav")
        try? FileManager.default.removeItem(at: lineURL)
        var lineDone = false
        var lineOK = false
        let lineStart = Date()
        SpeechEngine.shared.generateToWAV(text: "别急，先把灯关了。",
                                          params: lineParams,
                                          refAudio: loadedRef.samples,
                                          refText: "今天天气不错，我们边走边说吧。",
                                          outURL: lineURL) { result in
            switch result {
            case .success: lineOK = true
            case .failure(let error): print("reftest: line failed \(error.localizedDescription)")
            }
            lineDone = true
        }
        pump({ lineDone }, timeout: 300)
        print(String(format: "reftest: line %@ %.1fs %@", lineOK ? "ok" : "fail",
                     Date().timeIntervalSince(lineStart),
                     Paths.size(of: lineURL).humanBytes))
        print("reftest: done")
    }

    /// 边跑 RunLoop 边等回调，避免在主线程上死锁。
    private static func pump(_ finished: () -> Bool, timeout: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        while !finished() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func runSmoke(modelPath: String, outPath: String, text: String, useGPU: Bool = true) {
        let loadStart = Date()
        guard let engine = BreezeEngine(modelPath: modelPath, useGPU: useGPU) else {
            FileHandle.standardError.write(Data("breeze_init failed: \(BreezeEngine.lastErrorMessage())\n".utf8))
            return
        }
        print("backend: \(engine.backendName.isEmpty ? (useGPU ? "gpu" : "cpu") : engine.backendName)")
        print("sample_rate: \(engine.sampleRate)")
        print(String(format: "load_seconds: %.2f", Date().timeIntervalSince(loadStart)))

        var collected: [Float] = []
        var chunks = 0
        var firstChunkAt: TimeInterval = 0
        let genStart = Date()

        let ok = engine.generate(withText: text,
                                 instruction: "Speak clearly and naturally.",
                                 refText: nil,
                                 refAudioSamples: nil,
                                 cfgScale: 1.0,
                                 seed: 42,
                                 maxNewTokens: 0,
                                 splitChars: 0,
                                 temperature: 0,
                                 topK: 0,
                                 topP: 0,
                                 repetitionPenalty: 0,
                                 chunkFirst: 0,
                                 chunkMax: 0) { payload, _ in
            let count = payload.count / MemoryLayout<Float>.size
            guard count > 0 else { return }
            if chunks == 0 { firstChunkAt = Date().timeIntervalSince(genStart) }
            chunks += 1
            var chunk = [Float](repeating: 0, count: count)
            chunk.withUnsafeMutableBytes { raw in
                _ = payload.copyBytes(to: raw)
            }
            collected.append(contentsOf: chunk)
        }

        let elapsed = Date().timeIntervalSince(genStart)
        guard ok else {
            FileHandle.standardError.write(Data("generate failed: \(BreezeEngine.lastErrorMessage())\n".utf8))
            return
        }

        let rate = Double(engine.sampleRate)
        print("chunks: \(chunks)")
        print("samples: \(collected.count)")
        print(String(format: "audio_seconds: %.2f", Double(collected.count) / rate))
        print(String(format: "first_chunk_seconds: %.2f", firstChunkAt))
        print(String(format: "generate_seconds: %.2f", elapsed))
        print(String(format: "rtf: %.2f", elapsed / max(0.01, Double(collected.count) / rate)))

        do {
            try ExportService.writeWAV(samples: collected, sampleRate: rate, to: URL(fileURLWithPath: outPath))
            print("wav: \(outPath)")
        } catch {
            FileHandle.standardError.write(Data("wav write failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
