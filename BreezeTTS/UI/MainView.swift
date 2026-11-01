import AppKit
import SwiftUI

/// The whole app is one writing surface plus a floating toolbar. Voice, model,
/// history and settings live in sheets so the window never turns into a
/// multi-pane dashboard.
struct MainView: View {
    @ObservedObject var model: AppModel

    @State private var sheet: ActiveSheet?
    @State private var showVoiceMenu = false
    /// 对话在主窗口内全屏展开，不走弹层。
    @State private var showChat = false
    @FocusState private var editorFocused: Bool
    @Namespace private var glassNamespace

    enum ActiveSheet: String, Identifiable {
        case voices, history, models, settings, recorder, audiobook
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            if showChat {
                ChatSheet(model: model, onClose: { showChat = false })
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 22)
                        .padding(.top, 16)

                    editor
                        .padding(.horizontal, 32)
                        .padding(.top, 26)

                    footer
                        .padding(.horizontal, 32)
                        .padding(.top, 10)
                        .padding(.bottom, 104)
                }
                .overlay(alignment: .bottom) { toolbar.padding(.bottom, 30) }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showChat)
        .background(WindowConfigurator())
        .task { model.bootstrap() }
        .sheet(item: $sheet) { item in
            switch item {
            case .voices: VoiceSheet(model: model)
            case .history: HistorySheet(model: model)
            case .models: ModelManagerSheet(model: model)
            case .settings: SettingsSheet(model: model)
            case .recorder: RecorderSheet(model: model)
            case .audiobook: AudiobookSheet(model: model)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Breeze")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.primary)
                .padding(.leading, 64)

            Spacer(minLength: 12)

            Button {
                sheet = .models
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.modelReady ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(model.modelLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .glassCapsule()
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button { sheet = .history } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .glassIconButton()

            Button { sheet = .settings } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .glassIconButton()
        }
        .frame(height: 30)
    }

    // MARK: - Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if RenderMode.isPreview {
                TextBlock(text: model.text, size: 17)
            } else {
                TextEditor(text: $model.text)
                    .font(.system(size: 17))
                    .lineSpacing(7)
                    .transparentTextBackground()
                    .focused($editorFocused)
                    .padding(.horizontal, -4)
            }

            if model.text.isEmpty {
                Text("写点什么，或者粘贴一段文字。\n⌘↵ 开始合成。")
                    .font(.system(size: 17))
                    .lineSpacing(7)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerDetail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(estimateHelp)

            Spacer(minLength: 8)

            if model.phase.isBusy || model.playback.isPlaying {
                LevelMeter(level: model.phase.isBusy ? model.player.level : model.playback.level, bars: 18)
                    .frame(height: 16)
            }

            // Live progress for the run in flight, kept thin so the writing
            // surface stays the loudest thing on screen.
            if model.phase == .generating, let progress = model.runProgress {
                SlimProgress(fraction: progress.fraction)
                    .frame(width: 78, height: 3)
                    .help("生成进度")
            }

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .monospacedDigit()
                .truncationMode(.middle)
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Character count plus the estimate: "45 字 · 约 7 秒语音 · 预计 1 分 50 秒".
    private var footerDetail: String {
        guard !model.text.isEmpty else { return " " }
        let chars = "\(model.charCount) 字"
        if model.phase == .generating {
            return chars + " · 已生成 " + String(format: "%.1f", model.audioSeconds) + " 秒"
        }
        guard let estimate = model.forecast else { return chars }
        return "\(chars) · 约 \(estimate.audioLabel)语音 · 预计 \(estimate.totalLabel)"
    }

    private var estimateHelp: String {
        guard let estimate = model.forecast else { return "输入文字后显示时长估算" }
        return "\(estimate.detail) · 本地估算，运行一次后自动按本机速度校准"
    }

    private var statusText: String {
        if case .failed(let message) = model.phase { return message }
        if model.phase == .generating, let progress = model.runProgress {
            return "\(progress.percentLabel) · 还需 \(progress.remainingLabel)"
        }
        return model.statusLine
    }

    // MARK: - Floating toolbar

    private var toolbar: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 5) {
                Button {
                    sheet = .audiobook
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 12, weight: .medium))
                        Text("听书")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("听书模式：粘贴小说，自动分角色朗读")

                // 对话入口：设置里关闭后不显示；点开在主窗口内全屏展开。
                if model.settings.chatEnabled {
                    hairline

                    Button {
                        showChat = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 12, weight: .medium))
                            Text("对话")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("对话：LLM 回复并用语音读出（设置里可关闭）")
                }

                hairline

                Button {
                    showVoiceMenu = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 12, weight: .medium))
                        Text(model.voiceLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if let hint = recommendationHint {
                            Circle()
                                .fill(Color.primary.opacity(0.45))
                                .frame(width: 4, height: 4)
                                .help("推荐：\(hint.style.name) · \(hint.reason)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showVoiceMenu, arrowEdge: .bottom) {
                    VoiceMenu(model: model, isPresented: $showVoiceMenu) {
                        // The popover has to be gone before a sheet can own the
                        // window, otherwise the presentation is swallowed.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            sheet = .voices
                        }
                    }
                }

                hairline

                Button {
                    model.generate()
                } label: {
                    HStack(spacing: 7) {
                        if model.phase == .generating {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "waveform").font(.system(size: 11, weight: .bold))
                        }
                        Text(generateTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            // 文字必须先按自身理想宽度排版，否则在玻璃胶囊里
                            // 会被压缩成一个省略号。
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .foregroundStyle(generateForeground)
                    .frame(minWidth: 84)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(generateFill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canGenerate)
                .help(generateHelp)
                .keyboardShortcut(.return, modifiers: .command)

                // Transport for the clip that is already on disk. It only makes
                // sense once a run has finished, so it stays hidden while busy.
                if model.playback.hasAudio && model.phase != .generating {
                    hairline

                    playbackButton

                    PlaybackTrack(progress: model.playback.progress) { value in
                        model.seekPlayback(to: value)
                    }
                    .frame(width: 56, height: 18)
                    .help("拖动调整进度")

                    Text(model.playback.timeLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                if model.phase.isBusy {
                    glyphButton("stop.fill", help: "停止合成") { model.stop() }
                }

                if !model.generatedSamples.isEmpty {
                    glyphButton("square.and.arrow.down", help: "导出 WAV") { model.exportLast() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassCapsule()
            .glassID("toolbar", in: glassNamespace)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.playback.hasAudio)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var playbackButton: some View {
        Button {
            model.togglePlayback()
        } label: {
            Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.45), lineWidth: 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.playback.isPlaying ? "暂停" : "播放")
    }

    private var canGenerate: Bool {
        // While the audiobook grinds through its segments the main button stays
        // live: a new run simply queues behind the current segment.
        let audiobookRunning = model.phase == .generating && model.audiobookProgress != nil
        return (model.phase != .generating || audiobookRunning)
            && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Percent inside the button is the one number users look for once the run
    /// has started; before that the button just says "生成".
    private var generateTitle: String {
        if model.phase == .generating, model.audiobookProgress != nil {
            return "插队生成（听书继续）"
        }
        guard model.phase == .generating else { return "生成" }
        guard let progress = model.runProgress else { return "合成中" }
        return "合成中 \(progress.percentLabel)"
    }

    private var generateHelp: String {
        guard let estimate = model.forecast else { return "合成语音" }
        if model.phase == .generating, let progress = model.runProgress {
            return "还需约 \(progress.remainingLabel)"
        }
        return "预计 \(estimate.totalLabel) 完成 · \(estimate.detail)"
    }

    /// While a run is live the button is a readout, not an action: it turns into
    /// a quiet chip so the percentage stays legible on the disabled state.
    private var generateFill: Color {
        if model.phase == .generating { return Color.primary.opacity(0.08) }
        return Color.primary.opacity(canGenerate ? 1 : 0.25)
    }

    private var generateForeground: Color {
        if model.phase == .generating { return .primary }
        return canGenerate ? Theme.inverse : .secondary
    }

    /// A quiet dot when the advisor has a better idea than the current style.
    private var recommendationHint: VoiceAdvisor.Pick? {
        guard !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pick = model.suggestedStyle,
              pick.style.id != VoiceStyles.neutral.id,
              pick.style.id != model.activeStyle?.id
        else { return nil }
        return pick
    }

    /// Quiet glyph action that lives inside the toolbar's glass bar; the bar
    /// itself is the only glass surface there, so these use a plain fill.
    private func glyphButton(_ symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.faintFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Slim scrub bar for the finished clip: click or drag anywhere on the track.
struct PlaybackTrack: View {
    var progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let filled = max(3, width * min(1, max(0, progress)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: width, height: 3)
                Capsule()
                    .fill(Color.primary.opacity(0.78))
                    .frame(width: filled, height: 3)
                Circle()
                    .fill(Color.primary)
                    .frame(width: 7, height: 7)
                    .offset(x: min(max(0, filled - 3.5), width - 7))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(min(1, max(0, value.location.x / width)))
                    }
            )
        }
    }
}
