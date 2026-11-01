import SwiftUI

/// 角色声线面板：普通视图只放「这个人听起来是什么样」和那颗生成按钮，
/// 细节（年龄描述、性别、音色特征、ref 台词、seed、cfg）收在高级设置里。
///
/// 文案刻意反复强调一件事：档案只用来生成基准音色；正文朗读由 ref + 单句情绪驱动。
struct RoleEditorSheet: View {
    @ObservedObject var model: AppModel
    let characterID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var ageDesc = ""
    @State private var gender = "中性"
    @State private var feature = ""
    @State private var refText = ""
    @State private var refSeed = 42
    @State private var refCFG: Double = 4.0
    @State private var showAdvanced = false
    @State private var loaded = false

    init(model: AppModel, characterID: UUID, startAdvanced: Bool = false) {
        self.model = model
        self.characterID = characterID
        _showAdvanced = State(initialValue: startAdvanced)
    }

    private var character: StoryCharacter? {
        model.audiobookCharacters.first { $0.id == characterID }
    }

    private var isGenerating: Bool { model.refGeneratingID == characterID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollHost {
                VStack(alignment: .leading, spacing: 16) {
                    if let character {
                        baseCard(character)
                        advancedCard(character)
                        warning
                    } else {
                        Text("这个角色已经不在了")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 600)
        .background(Theme.canvas)
        .onAppear { load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("角色声线")
                    .font(.system(size: 15, weight: .semibold))
                Text(character.map { "\($0.name) · \($0.lines) 句台词" } ?? "角色已移除")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let character, character.hasReference {
                Pill(text: "基准音色已锁定", emphasis: true)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 普通视图

    private func baseCard(_ character: StoryCharacter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if RenderMode.isPreview {
                    // ImageRenderer 画不了 NSTextField，截图里会变成一条黄条。
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("角色名", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .onChange(of: name) { value in
                            model.updateRoleProfile(characterID, name: value)
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))

            Text("基准音色")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                statusPill(character)

                Spacer(minLength: 8)

                if character.hasReference {
                    Button {
                        model.previewRoleReference(characterID)
                    } label: {
                        Label("试听", systemImage: "play.fill")
                    }
                    .quietPill()
                }

                Button {
                    model.generateRoleReference(characterID)
                } label: {
                    Text(isGenerating ? "生成中…" : (character.hasReference ? "重新生成" : "生成基准音色"))
                        .frame(minWidth: 92)
                }
                .quietPill()
                .disabled(isGenerating || model.refGeneratingID != nil)
            }

            if isGenerating || !model.refStatus.isEmpty {
                HStack(spacing: 6) {
                    if isGenerating {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text(model.refStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("基准音色生成后，整本书里这个人的底色就由它锁住；每一句的情绪只改语气，不改音色。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
    }

    private func statusPill(_ character: StoryCharacter) -> some View {
        Group {
            if character.hasReference && character.refStale {
                Pill(text: "档案已改 · 需重生成")
            } else if character.hasReference {
                Pill(text: "已生成", emphasis: true)
            } else {
                Pill(text: "未生成")
            }
        }
    }

    // MARK: - 高级设置

    private func advancedCard(_ character: StoryCharacter) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("高级设置")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("年龄 · 性别 · 音色特征 · ref 台词")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    field("年龄描述", placeholder: "例如：二十多岁") {
                        if RenderMode.isPreview {
                            Text(ageDesc)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("二十多岁", text: $ageDesc)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .onChange(of: ageDesc) { value in
                                    model.updateRoleProfile(characterID, ageDesc: value)
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("性别")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $gender) {
                            ForEach(["男", "女", "中性"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: gender) { value in
                            model.updateRoleProfile(characterID, gender: value)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("音色人物特征")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Group {
                            if RenderMode.isPreview {
                                Text(feature)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .frame(height: 62)
                            } else {
                                TextEditor(text: $feature)
                                    .font(.system(size: 12))
                                    .transparentTextBackground()
                                    .frame(height: 62)
                                    .onChange(of: feature) { value in
                                        model.updateRoleProfile(characterID, feature: value)
                                    }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
                        Text("只写稳定底色（音高、共鸣、气息、口音），不要写情绪和语速。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }

                    field("Ref 基准台词", placeholder: "生成基准音色时读的那句话") {
                        if RenderMode.isPreview {
                            Text(refText)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("今天天气不错，我们边走边说吧。", text: $refText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .onChange(of: refText) { value in
                                    model.updateRoleRefText(characterID, text: value)
                                }
                        }
                    }
                    Text("这句只影响基准音色本身，改完要重新生成才会生效。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Seed")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            if RenderMode.isPreview {
                                Text("\(refSeed)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 92, alignment: .leading)
                            } else {
                                TextField("42", value: $refSeed, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 92)
                                    .onChange(of: refSeed) { value in
                                        model.updateRoleRefSeed(characterID, seed: value)
                                    }
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("生成 ref 的 cfg")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(String(format: "%.1f", refCFG))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Slider(value: $refCFG, in: 2...6, step: 0.1)
                                .tint(Appearance.accent)
                                .onChange(of: refCFG) { value in
                                    model.updateRoleRefCFG(characterID, cfg: value)
                                }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("改成自动推断") {
                            model.resetRoleProfile(characterID)
                            load(force: true)
                        }
                        .quietPill()

                        if character.hasReference {
                            Button("删除基准音色") {
                                model.clearRoleReference(characterID)
                            }
                            .quietPill()
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("档案只用于初次生成基准音色。")
                .font(.system(size: 10.5, weight: .medium))
            Text("朗读正文时，音色由参考音频锁定；每一句的情绪、语速由剧本 AI 解析出的表演指令控制。改上面的内容不会自动重生成，需要点「重新生成」。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Helpers

    private func field<Content: View>(_ title: String,
                                      placeholder: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
        }
    }

    private func load(force: Bool = false) {
        guard force || !loaded, let character else { return }
        loaded = true
        name = character.name
        ageDesc = character.ageDesc
        gender = ["男", "女", "中性"].contains(character.gender) ? character.gender : "中性"
        feature = character.feature
        refText = character.refText.isEmpty ? AppModel.defaultRefText(for: character) : character.refText
        refSeed = character.refSeed
        refCFG = character.refCFG
    }
}
