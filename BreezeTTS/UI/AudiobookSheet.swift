import SwiftUI
import UniformTypeIdentifiers

/// 听书模式：粘贴/拖入小说 → 本地解析人物与旁白 → 逐角色配置声线 → 整本合成。
struct AudiobookSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var voices: VoiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var roleTarget: RoleEditTarget?

    /// `.sheet(item:)` 需要 Identifiable，UUID 本身不满足。
    struct RoleEditTarget: Identifiable { let id: UUID }

    init(model: AppModel) {
        self.model = model
        self.voices = model.voices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollHost {
                VStack(alignment: .leading, spacing: 16) {
                    if model.audiobookSegments.isEmpty {
                        inputSection
                    } else {
                        charactersSection
                        segmentsSummary
                        generateSection
                        resetRow
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.canvas)
        .sheet(item: $roleTarget) { target in
            RoleEditorSheet(model: model, characterID: target.id)
        }
        .onChange(of: model.pendingRoleEditorID) { value in
            guard let value else { return }
            roleTarget = RoleEditTarget(id: value)
            model.pendingRoleEditorID = nil
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.plainText, .utf8PlainText, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let text = try? String(contentsOf: url, encoding: .utf8) {
                model.audiobookText = text
                model.analyzeStory()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("听书模式")
                    .font(.system(size: 15, weight: .semibold))
                Text("粘贴或拖入小说，自动识别旁白与人物对话")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Step 1: get the text

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if RenderMode.isPreview {
                Text(model.audiobookText)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 240)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill))
            } else {
                TextEditor(text: $model.audiobookText)
                    .font(.system(size: 12))
                    .transparentTextBackground()
                    .frame(height: 240)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill))
                    .overlay(
                        Group {
                            if model.audiobookText.isEmpty {
                                Text("把小说粘贴到这里，或直接把 .txt 拖进窗口\n\n支持 「」『』“” 引号对话，说话人靠上下文推断，识别结果都可以手动改")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                    )
            }

            HStack(spacing: 8) {
                Button {
                    model.analyzeStory()
                } label: {
                    Label("识别人物与旁白", systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .quietPill()
                .disabled(model.audiobookText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                .opacity(model.audiobookText.isEmpty ? 0.4 : 1)

                Button {
                    showFilePicker = true
                } label: {
                    Label("打开 txt", systemImage: "doc")
                }
                .quietPill()
            }

            if !model.audiobookStatus.isEmpty {
                Text(model.audiobookStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
        .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        model.audiobookText = text
                        model.analyzeStory()
                    }
                }
                return true
            }
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text else { return }
                DispatchQueue.main.async {
                    model.audiobookText = text
                    model.analyzeStory()
                }
            }
            return true
        }
    }

    // MARK: - Step 2: characters

    private var charactersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "人物声线")
                Spacer(minLength: 0)
                if model.profileFilling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("正在推断人设…")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if model.audiobookCharacters.isEmpty {
                Text("没有识别出带名字的对话，整篇将按旁白声线朗读。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(model.audiobookCharacters) { character in
                CharacterRow(model: model, voices: voices.voices, character: character) {
                    roleTarget = RoleEditTarget(id: character.id)
                }
            }

            narrationRow
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
    }

    /// Narration gets a fixed row so its voice is adjustable too.
    private var narrationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("旁白")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            voiceMenu(roleID: "narration",
                      styles: [VoiceStyles.style(id: "steady") ?? VoiceStyles.neutral] + VoiceStyles.all,
                      currentLabel: "沉稳旁白（默认）")
        }
    }

    // MARK: - Step 3: run

    private var segmentsSummary: some View {
        let dialogues = model.audiobookSegments.filter(\.isDialogue).count
        return VStack(alignment: .leading, spacing: 6) {
            Text("共 \(model.audiobookSegments.count) 段 · 对话 \(dialogues) · 旁白 \(model.audiobookSegments.count - dialogues)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            // Per-line preview with the emotion hint the model wrote, so the
            // user can see what will bend before committing to the run.
            ForEach(model.audiobookSegments.prefix(10)) { segment in
                HStack(alignment: .top, spacing: 6) {
                    Text(segment.speaker ?? "旁白")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(segment.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let hint = segment.hint {
                            Text("提示词：\(hint)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if model.audiobookSegments.count > 10 {
                Text("…其余 \(model.audiobookSegments.count - 10) 段按同样规则处理")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.audiobookProgress {
                GlassProgress(fraction: progress,
                              title: model.audiobookStatus,
                              detail: progressDetail,
                              icon: "waveform.badge.magnifyingglass") {
                    model.cancelAudiobook()
                }
            } else {
                Button {
                    model.generateAudiobook()
                } label: {
                    Label("生成听书音频", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .quietPill()
                .disabled(model.modelReady == false && model.isModelLoaded == false)

                if !model.audiobookStatus.isEmpty {
                    Text(model.audiobookStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if model.audiobookAudioID != nil && model.audiobookProgress == nil {
                finishedTransport
            }
        }
    }

    /// Real-time playback preview for the finished book + local save.
    private var finishedTransport: some View {
        HStack(spacing: 10) {
            Button {
                model.playback.toggle()
            } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .glassIconButton(size: 28)
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                PlaybackTrack(progress: model.playback.progress) { fraction in
                    model.playback.seek(toProgress: fraction)
                }
                .frame(height: 12)
                Text("听书 · \(model.playback.timeLabel)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                saveAudiobookLocally()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .glassIconButton(size: 28)
            .buttonStyle(.plain)
            .help("保存听书到本地")
        }
    }

    private func saveAudiobookLocally() {
        guard let url = model.playback.currentURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BreezeTTS-听书-\(Int(Date().timeIntervalSince1970)).wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            model.audiobookStatus = "已保存到 \(target.path)"
        } catch {
            model.audiobookStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private var totalSegments: Int { model.audiobookSegments.count }

    private var progressDetail: String {
        var detail = "第 \(currentSegment) 段 / 共 \(totalSegments) 段"
        if let remaining = model.audiobookRemaining, remaining > 1 {
            detail += " · 预计还需 \(DurationText.short(remaining))"
        }
        return detail
    }

    private var currentSegment: Int {
        guard let progress = model.audiobookProgress else { return 0 }
        return min(totalSegments, max(1, Int((progress * Double(totalSegments)).rounded())))
    }

    private var resetRow: some View {
        Button {
            model.audiobookSegments = []
            model.audiobookCharacters = []
            model.audiobookProgress = nil
            model.audiobookStatus = ""
        } label: {
            Text("换一段文本")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Voice picker

    private func voiceMenu(roleID: String,
                           styles: [VoiceStyle],
                           currentLabel: String) -> some View {
        Menu {
            Section("声线预设") {
                ForEach(styles) { style in
                    Button(style.name) {
                        model.setAudiobookRole(roleID: roleID, style: style)
                    }
                }
            }
            if !voices.voices.isEmpty {
                Section("我的音色") {
                    ForEach(voices.voices) { voice in
                        Button(voice.name) {
                            model.setAudiobookRole(roleID: roleID, voice: voice)
                        }
                    }
                }
            }
            Button("自动（按年龄性格）") {
                model.setAudiobookRole(roleID: roleID, auto: true)
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.canvas))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One editable character: 名字 + 档案摘要 + 基准音色状态 + 声线选择。
/// 点整行打开角色面板（普通视图 / 高级设置都在里面）。
private struct CharacterRow: View {
    @ObservedObject var model: AppModel
    let voices: [VoiceMeta]
    let character: StoryCharacter
    var onEdit: () -> Void

    private var role: AppModel.RoleAssignment { model.audiobookRoles[character.id] ?? .init() }

    private var currentVoiceLabel: String {
        switch role.mode {
        case .auto: return character.hasReference ? "基准音色" : "自动 · \(autoPresetName)"
        case .style: return VoiceStyles.style(id: role.styleID)?.name ?? "自动"
        case .voice:
            return voices.first { $0.id == role.voiceID }?.name ?? "自动"
        }
    }

    private var autoPresetName: String {
        VoiceStyles.style(id: StoryParser.presetID(age: character.age,
                                                   personality: character.personality))?.name ?? "中性"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(character.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text("\(character.lines) 句")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开角色声线面板")

                Spacer(minLength: 6)

                refBadge
                voiceMenu
            }

            HStack(spacing: 6) {
                tagMenu(label: character.age, icon: "hourglass", options: StoryParser.ageTags) { tag in
                    model.setAudiobookAge(character.id, tag: tag)
                }
                tagMenu(label: character.personality, icon: "theatermasks", options: StoryParser.personalityTags) { tag in
                    model.setAudiobookPersonality(character.id, tag: tag)
                }
                if !character.sample.isEmpty {
                    Text(character.sample)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if !character.baseInstruction.isEmpty {
                Text("\(character.ageDesc) · \(character.gender) · \(character.feature)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas))
    }

    @ViewBuilder
    private var refBadge: some View {
        if model.refGeneratingID == character.id {
            HStack(spacing: 3) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text("生成中")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else if character.hasReference {
            Pill(text: character.refStale ? "基准音色待更新" : "基准音色")
        }
    }

    private var voiceMenu: some View {
        Menu {
            Section("声线预设") {
                ForEach(VoiceStyles.all) { style in
                    Button(style.name) { model.setAudiobookRole(character.id, style: style) }
                }
            }
            if !voices.isEmpty {
                Section("我的音色") {
                    ForEach(voices) { voice in
                        Button(voice.name) { model.setAudiobookRole(character.id, voice: voice) }
                    }
                }
            }
            Button("自动（按年龄性格）") { model.setAudiobookRole(character.id, auto: true) }
        } label: {
            HStack(spacing: 4) {
                Text(currentVoiceLabel)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.faintFill))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func tagMenu(label: String, icon: String, options: [String],
                         onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { onSelect(option) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8.5))
                Text(label)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.faintFill))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
