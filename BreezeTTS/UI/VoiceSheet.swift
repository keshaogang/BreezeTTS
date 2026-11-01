import SwiftUI
import UniformTypeIdentifiers

/// 音色面板，分成三个界限分明的区域：
/// 1. 新建音色 —— 两条创建路径（文字描述 / 音频克隆），互斥展开；
/// 2. 已有音色 —— 由文字描述生成的音色；
/// 3. 已克隆音色 —— 由参考音频克隆出来的音色。
struct VoiceSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var voices: VoiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var textVoiceName = ""
    /// 新建音色的方式，空 = 两条入口都收着。
    @State private var creating: CreateKind?
    /// 克隆音色的文字辅助编辑状态。
    @State private var editingVoiceID: UUID?
    @State private var editingText = ""

    private enum CreateKind { case text, clone }

    init(model: AppModel, initialEditing: (id: UUID, text: String)? = nil) {
        self.model = model
        self.voices = model.voices
        // 快照工具用它把某一行直接摊开，正常启动时传 nil。
        _editingVoiceID = State(initialValue: initialEditing?.id)
        _editingText = State(initialValue: initialEditing?.text ?? "")
    }

    private var instruction: Binding<String> {
        Binding(get: { model.settings.instruction },
                set: { model.settings.instruction = $0 })
    }

    private var textVoices: [VoiceMeta] { voices.voices.filter { $0.isTextVoice } }
    private var cloneVoices: [VoiceMeta] { voices.voices.filter { !$0.isTextVoice } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollHost {
                VStack(alignment: .leading, spacing: 16) {
                    createZone
                    existingZone
                    clonedZone
                }
                .padding(18)
            }
        }
        .frame(width: 480, height: 640)
        .background(Theme.canvas)
        .sheet(isPresented: $showRecorder) { RecorderSheet(model: model) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard model.stageReferenceClip(from: url) else { return }
            // The recorder sheet needs the take to exist before it opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showRecorder = true
            }
        }
    }

    private var header: some View {
        HStack {
            Text("音色")
                .font(.system(size: 15, weight: .semibold))
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

    /// 分区标题：图标 + 名称 + 说明，让三个区域的边界一眼能分清。
    private func zoneHeader(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    // MARK: - 区域一：新建音色

    private var createZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneHeader(icon: "plus.circle.fill", title: "新建音色", detail: "两条路径，二选一")

            HStack(spacing: 10) {
                createTile(kind: .text,
                           icon: "text.bubble",
                           title: "文字生成",
                           subtitle: "一句话描述想要的音色")
                createTile(kind: .clone,
                           icon: "waveform.badge.mic",
                           title: "音频克隆",
                           subtitle: "录音或导入 5–20 秒")
            }

            switch creating {
            case .text: textVoiceForm
            case .clone: cloneActions
            case nil: EmptyView()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.faintFill)
        )
    }

    private func createTile(kind: CreateKind, icon: String, title: String, subtitle: String) -> some View {
        let active = creating == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                creating = active ? nil : kind
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(active ? .primary : .secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Theme.softFill : Theme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Appearance.accent.opacity(0.55) : Color.primary.opacity(0.06),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 文字生成表单：名称 + 描述 + 保存。
    private var textVoiceForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if RenderMode.isPreview {
                Text(textVoiceName.isEmpty ? "音色名称，如：温柔女声" : textVoiceName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(textVoiceName.isEmpty ? .tertiary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
            } else {
                TextField("音色名称，如：温柔女声", text: $textVoiceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
            }

            if RenderMode.isPreview {
                Text(instruction.wrappedValue)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 58)
                    .padding(10)
            } else {
                TextEditor(text: instruction)
                    .font(.system(size: 12.5))
                    .transparentTextBackground()
                    .frame(height: 58)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
            }

            HStack {
                Text("描述语气、语速、情绪，存成可复用的音色。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    if let saved = model.saveTextVoice(name: textVoiceName,
                                                       instruction: instruction.wrappedValue) {
                        textVoiceName = ""
                        creating = nil
                        model.statusLine = "已保存音色：\(saved.name)"
                    }
                } label: {
                    Label("保存为音色", systemImage: "wand.and.stars")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .quietPill()
                .disabled(!canSaveTextVoice)
                .opacity(canSaveTextVoice ? 1 : 0.4)
            }
        }
    }

    /// 音频克隆：录制或导入两条路。
    private var cloneActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("录一段 5–20 秒的参考音频，或导入现成文件；说话内容会自动识别成文字，保存后即可复刻。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 8) {
                Button {
                    showRecorder = true
                } label: {
                    Label("录制", systemImage: "mic")
                        .frame(maxWidth: .infinity)
                }
                .quietPill()

                Button {
                    showImporter = true
                } label: {
                    Label("导入音频", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .quietPill()
            }
        }
    }

    private var canSaveTextVoice: Bool {
        !textVoiceName.trimmingCharacters(in: .whitespaces).isEmpty
            && !instruction.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 区域二：已有音色（文字音色）

    private var existingZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneHeader(icon: "person.wave.2.fill", title: "已有音色", detail: "\(textVoices.count) 个 · 文字描述生成")

            VStack(spacing: 0) {
                if textVoices.isEmpty {
                    emptyHint("还没有文字音色，用上面的「文字生成」新建一个。")
                } else {
                    ForEach(Array(textVoices.enumerated()), id: \.element.id) { index, voice in
                        if index > 0 { rowDivider }
                        VStack(alignment: .leading, spacing: 6) {
                            row(voice)
                            if editingVoiceID == voice.id {
                                instructionEditor(voice)
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.faintFill)
            )
        }
    }

    // MARK: - 区域三：已克隆音色

    private var clonedZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneHeader(icon: "waveform.circle.fill", title: "已克隆音色", detail: "\(cloneVoices.count) 个 · 参考音频复刻")

            VStack(spacing: 0) {
                if cloneVoices.isEmpty {
                    emptyHint("还没有克隆音色，用上面的「音频克隆」录一段试试。")
                } else {
                    ForEach(Array(cloneVoices.enumerated()), id: \.element.id) { index, voice in
                        if index > 0 { rowDivider }
                        VStack(alignment: .leading, spacing: 6) {
                            row(voice)
                            if editingVoiceID == voice.id {
                                instructionEditor(voice)
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.faintFill)
            )
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 11)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
    }

    // MARK: - Rows

    /// 音色指令编辑器。文字音色的指令就是音色本身，克隆音色的指令是叠加在
    /// 参考音频之上的语气补充，两种都在这里改。
    private func instructionEditor(_ voice: VoiceMeta) -> some View {
        let isText = voice.isTextVoice
        let canSave = !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $editingText)
                .font(.system(size: 12))
                .transparentTextBackground()
                .frame(height: isText ? 56 : 46)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
                .overlay(alignment: .topLeading) {
                    if editingText.isEmpty {
                        Text(isText ? "描述这个音色：性别、年龄、语气、语速、情绪" : "例如：说话慢一点，温柔带笑（叠加在参考音频之上）")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 12)
                            .padding(.leading, 12)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Text(isText ? "这段描述就是这个音色本身，改完立即生效。" : "文字只补充语气，音色仍由参考音频决定。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("取消") {
                    editingVoiceID = nil
                    editingText = ""
                }
                .quietPill()
                Button {
                    voices.setInstruction(voice, instruction: editingText)
                    let updated = voices.voices.first { $0.id == voice.id }
                    if isText {
                        // 正在使用的音色：正文指令跟着换，免得面板与实际脱节。
                        if model.activeTextVoice?.id == voice.id, let updated {
                            model.applyTextVoice(updated)
                        }
                        model.statusLine = "已更新音色「\(voice.name)」"
                    } else {
                        if model.selectedVoiceID == voice.id {
                            model.settings.instruction = updated?.instruction ?? ""
                        }
                        model.statusLine = "已更新「\(voice.name)」的文字辅助"
                    }
                    editingVoiceID = nil
                    editingText = ""
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .quietPill()
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas))
        .padding(.horizontal, 5)
    }

    private func row(_ voice: VoiceMeta) -> some View {
        let selected = voice.isTextVoice
            ? model.activeTextVoice?.id == voice.id
            : model.selectedVoiceID == voice.id
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(selected ? Appearance.accent : Color.secondary.opacity(0.45))

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(voice))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                editingVoiceID = editingVoiceID == voice.id ? nil : voice.id
                editingText = voice.instruction ?? ""
            } label: {
                Image(systemName: voice.instruction?.isEmpty == false
                      ? "pencil.circle.fill" : "pencil.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(voice.isTextVoice ? "编辑音色描述" : "文字辅助：用文字补充语气/语速/情绪")

            Button {
                voices.delete(voice)
                if model.selectedVoiceID == voice.id { model.clearSelection() }
                if editingVoiceID == voice.id { editingVoiceID = nil }
            } label: {
                Image(systemName: "trash").font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Theme.softFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if voice.isTextVoice {
                model.applyTextVoice(voice)
            } else {
                model.selectCloneVoice(voice)
            }
        }
    }

    private func subtitle(_ voice: VoiceMeta) -> String {
        if voice.isTextVoice {
            let wording = (voice.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return wording.isEmpty ? "文字音色" : String(wording.prefix(30))
        }
        let wording = (voice.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !wording.isEmpty { return String(format: "%.1fs · ", voice.durationSeconds) + wording.prefix(20) }
        return String(format: "%.1fs · %@", voice.durationSeconds,
                      voice.refText.isEmpty ? "缺少参考文本" : String(voice.refText.prefix(20)))
    }
}
