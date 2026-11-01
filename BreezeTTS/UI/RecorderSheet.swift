import SwiftUI
import UniformTypeIdentifiers

/// Record a 5–20 second reference take for cloning. The transcript has to match
/// the recording, so it is filled in by the on-device recogniser right after the
/// take lands; the field stays editable for fixing a word or two.
struct RecorderSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: VoiceRecorder
    @Environment(\.dismiss) private var dismiss

    @StateObject private var asr = SpeechTranscriber()
    /// `auto` recognises with both the Chinese and the English model.
    @AppStorage("asr.locale") private var asrLocale: String = SpeechTranscriber.autoID

    @State private var name = ""
    @State private var transcript = ""
    /// 可选的文字辅助描述：叠加在参考音频之上的语气/语速/情绪指令。
    @State private var assist = ""
    @State private var didStop = false
    @State private var showImporter = false

    init(model: AppModel) {
        self.model = model
        self.recorder = model.recorder
        if RenderMode.isPreview {
            // The snapshot harness stages a tone, not speech: show what a finished
            // transcription looks like instead of an empty field.
            _name = State(initialValue: "我的声音")
            _transcript = State(initialValue: "大家好，这是一段用来复刻音色的参考录音。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            capture
            transcriptSection
            nameSection
            assistSection
            Spacer(minLength: 0)
            actions
        }
        .padding(22)
        .frame(width: 520, height: 640)
        .background(Theme.canvas)
        .task(id: recorder.takeToken) {
            // One transcription per take: mic stop, file import, or the take the
            // voice sheet staged before presenting this sheet.
            guard !RenderMode.isPreview, recorder.hasTake else { return }
            await runTranscription()
        }
        .onDisappear {
            recorder.stopPreview()
            if recorder.isRecording { _ = recorder.stop() }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onChange(of: asrLocale) { _ in
            Task { await runTranscription() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("录制参考音色")
                    .font(.system(size: 15, weight: .semibold))
                Text("建议 5–20 秒、安静环境、正常语速")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1fs", headerSeconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .primary : .secondary)
        }
    }

    private var headerSeconds: Double {
        if recorder.isRecording { return recorder.elapsed }
        if recorder.hasTake { return recorder.takeDuration }
        return 0
    }

    private var capture: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Theme.softFill : Theme.faintFill)
                    .frame(width: 56, height: 56)
                Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 10) {
                LevelMeter(level: recorder.isRecording ? recorder.level : 0, bars: 28)
                    .frame(height: 20)

                HStack(spacing: 8) {
                    Button {
                        if recorder.isRecording {
                            _ = recorder.stop()
                            didStop = true
                        } else {
                            didStop = false
                            transcript = ""
                            asr.reset()
                            SpeechTranscriber.prewarm()
                            recorder.start()
                        }
                    } label: {
                        Label(recorder.isRecording ? "停止" : "开始录音",
                              systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    }
                    .primaryPill()

                    if recorder.hasTake && !recorder.isRecording {
                        Button {
                            recorder.togglePreview()
                        } label: {
                            Label(recorder.isPreviewing ? "暂停" : "试听",
                                  systemImage: recorder.isPreviewing ? "pause.fill" : "play.fill")
                        }
                        .quietPill()
                        .help(recorder.isPreviewing ? "暂停试听" : "试听刚录的这一段")

                        Text("\(PlaybackService.clock(recorder.isPreviewing ? recorder.previewPosition : 0)) / \(PlaybackService.clock(recorder.takeDuration))")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.faintFill)
        )
        .overlay(alignment: .bottomLeading) {
            if let error = recorder.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, -18)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "录音内容")
                Spacer(minLength: 4)
                asrBadge
            }

            if RenderMode.isPreview {
                Text(transcript.isEmpty ? " " : transcript)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 58)
            } else {
                TextEditor(text: $transcript)
                    .font(.system(size: 12.5))
                    .transparentTextBackground()
                    .frame(height: 58)
                    .overlay(alignment: .topLeading) {
                        if transcript.isEmpty && !asr.status.isWorking {
                            Text("录完会自动识别到这里")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            HStack(spacing: 8) {
                Text(hintText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if asr.needsPermission {
                    Button {
                        SpeechTranscriber.openPrivacySettings()
                    } label: {
                        Text("打开设置")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                localeControl
                Button {
                    Task { await runTranscription() }
                } label: {
                    Text("重新识别")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!recorder.hasTake || asr.status.isWorking)
                .opacity(recorder.hasTake && !asr.status.isWorking ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.faintFill)
        )
    }

    @ViewBuilder
    private var localeControl: some View {
        if RenderMode.isPreview {
            // `Menu` is an AppKit popup: ImageRenderer draws it as a placeholder.
            HStack(spacing: 3) {
                Text(SpeechTranscriber.label(for: asrLocale))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .semibold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(SpeechTranscriber.choices, id: \.id) { item in
                    Button {
                        asrLocale = item.id
                    } label: {
                        if asrLocale == item.id {
                            Label(item.label, systemImage: "checkmark")
                        } else {
                            Text(item.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(SpeechTranscriber.label(for: asrLocale))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .semibold))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("识别语言")
        }
    }

    @ViewBuilder
    private var asrBadge: some View {
        switch asr.status {
        case .working:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
                Text("识别中…")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        case .done:
            HStack(spacing: 4) {
                Image(systemName: asr.lastOutcome?.onDevice == true ? "waveform.badge.mic" : "cloud")
                    .font(.system(size: 9))
                Text(asr.lastOutcome?.sourceLabel ?? "已识别")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        case .failed:
            Text("未识别")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .idle:
            if RenderMode.isPreview {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 9))
                    Text("本地识别")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var hintText: String {
        if case .failed(let message) = asr.status { return message }
        if recorder.isRecording { return "正在录音，停下后自动识别。" }
        return "录完自动识别并填入，可以直接改。"
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "音色名称")
            if RenderMode.isPreview {
                // `TextField` is an AppKit field: ImageRenderer draws it as a
                // placeholder rectangle, so the snapshot harness fakes it.
                Text(name.isEmpty ? "例如：我的声音 / 旁白男声" : name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(name.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill)
                    )
            } else {
                TextField("例如：我的声音 / 旁白男声", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill)
                    )
            }
        }
    }

    /// 文字辅助：参考音频定音色，这段文字补充语气/语速/情绪。
    private var assistSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                SectionLabel(text: "文字辅助（可选）")
                Text("叠加在参考音频之上")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            if RenderMode.isPreview {
                Text(assist.isEmpty ? " " : assist)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 44)
            } else {
                TextEditor(text: $assist)
                    .font(.system(size: 12.5))
                    .transparentTextBackground()
                    .frame(height: 44)
                    .overlay(alignment: .topLeading) {
                        if assist.isEmpty {
                            Text("例如：说话慢一点，温柔带笑，像在哄小孩")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("取消") {
                recorder.discard()
                dismiss()
            }
            .quietPill()

            Spacer()

            Button {
                showImporter = true
            } label: {
                Label("改用已有音频", systemImage: "waveform.badge.plus")
            }
            .quietPill()

            Button {
                model.saveRecordedVoice(name: name,
                                        refText: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                        instruction: assist)
                dismiss()
            } label: {
                Label("保存", systemImage: "checkmark")
            }
            .primaryPill()
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
        }
    }

    private var canSave: Bool {
        let hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTranscript && recorder.hasTake && (didStop || recorder.hasExternalTake)
    }

    /// `.fileImporter` keeps this inside the sheet's own presentation; the old
    /// `NSOpenPanel.runModal()` never came up while a sheet modal session was
    /// running, which is why importing looked like a dead button.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            recorder.stopPreview()
            asr.reset()
            transcript = ""
            didStop = false
            // Stage instead of saving straight away: the clip still needs its
            // transcript, which the recogniser fills in for us.
            if !model.stageReferenceClip(from: url) {
                recorder.errorMessage = model.statusLine
            }
        case .failure(let error):
            model.statusLine = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Fills the transcript from the take. Any existing text is replaced because
    /// a new take always means new words.
    private func runTranscription() async {
        guard recorder.hasTake, !recorder.isRecording else { return }
        let samples = recorder.capturedSamples
        let rate = recorder.sampleRate
        guard let outcome = await asr.transcribe(samples: samples,
                                                 sampleRate: rate,
                                                 locale: asrLocale,
                                                 allowNetwork: true) else { return }
        guard !Task.isCancelled else { return }
        transcript = outcome.text
        didStop = true
    }
}
