import SwiftUI

/// Sampling knobs and runtime switches. Zero means "keep the GGUF default",
/// which mirrors how the C API treats the request struct.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollHost {
                VStack(alignment: .leading, spacing: 22) {
                    runtimeSection
                    appearanceSection
                    pairingSection
                    chatSection
                    storySection
                    samplingSection
                    advancedSection
                    exportSection
                    aboutSection
                }
                .padding(22)
            }
        }
        .frame(width: 520, height: 640)
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                Text("采样参数留 0 表示沿用模型内置默认值")
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

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "运行时")
            toggle("优先使用 GPU", detail: "ggml 在 Apple 平台走 Metal，失败自动回退 CPU",
                   isOn: $settings.useGPU)
            toggle("边生成边播放", detail: "默认关：整段一次解码更快，结束后自动播放；开启则边合成边出声，但更慢",
                   isOn: $settings.streamPlayback)
            toggle("允许 iPhone 遥控", detail: "同一 Wi-Fi 下的 iPhone 可发送文本并取回音频（Bonjour 自动发现）",
                   isOn: $settings.remoteServer)
            toggle("每次随机种子", detail: "关闭则固定种子，同文本可复现同一段音频",
                   isOn: $settings.randomSeed)
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "外观")

            if Appearance.supportsLiquidGlass {
                toggle("液态玻璃效果",
                       detail: "关闭后改用毛玻璃材质；macOS 26 以下没有液态玻璃，自动就是毛玻璃",
                       isOn: $settings.useLiquidGlass)
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("液态玻璃效果").font(.system(size: 12.5, weight: .medium))
                        Text("当前系统 \(DeviceInfo.osVersionString) 不支持，已使用毛玻璃材质")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: "不可用")
                }
            }

            toggle("强调色跟随系统",
                   detail: "按钮、开关与选中态使用「系统设置 → 外观 → 强调色」的颜色；关掉则回到黑白单色",
                   isOn: $settings.followSystemAccent)
        }
    }

    // MARK: - 导出位置

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "导出位置")
            KeyValueRow(key: "保存到", value: settings.exportFolder.path)
            HStack(spacing: 8) {
                Button("选择文件夹…") { chooseExportFolder() }
                    .quietPill()
                Button("恢复默认") { settings.exportDirectory = nil }
                    .quietPill()
                    .disabled(settings.exportDirectory == nil)
                    .opacity(settings.exportDirectory == nil ? 0.4 : 1)
                Button("打开") { NSWorkspace.shared.open(settings.exportFolder) }
                    .quietPill()
                Spacer()
            }
            Text("每次生成完成后，音频会自动存到这里；点右上角「导出」也可以另存到别处。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择生成音频的保存文件夹"
        panel.directoryURL = settings.exportFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.exportDirectory = url.path
            model.statusLine = "音频将保存到 \(url.lastPathComponent)"
        }
    }

    // MARK: - 听书分析引擎

    // MARK: - iPhone 扫码绑定

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "iPhone 连接")
            PairingCard(model: model)
        }
    }

    // MARK: - 对话

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "对话")
            toggle("开启对话功能", detail: "开启后 Mac 底栏和 iPhone 底栏都会出现「对话」入口；关闭即完全隐藏",
                   isOn: $settings.chatEnabled)
            if settings.chatEnabled {
                Picker("", selection: $settings.chatBackend) {
                    Text("云端 API").tag(StoryBackend.cloud)
                    Text("本地模型").tag(StoryBackend.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.chatBackend == .cloud
                     ? "用「听书分析」里填的 OpenAI 兼容接口（\(settings.cloudAPIModel.isEmpty ? "未填模型名" : settings.cloudAPIModel)）"
                     : (StoryAnalyzer.available
                        ? "本地 Qwen 1.5B，离线可用，无需联网"
                        : "未安装本地模型（设置 → 听书分析 → 本地模型），回退云端或不可用"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                toggle("回复自动朗读", detail: "每次回复后用当前音色合成并播放",
                       isOn: $settings.chatSpeak)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
    }

    private var storySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "听书分析")

            Picker("", selection: $settings.storyBackend) {
                Text("本地模型").tag(StoryBackend.local)
                Text("云端 API").tag(StoryBackend.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.storyBackend {
            case .local:
                Text(StoryAnalyzer.available
                     ? "本地 Qwen 1.5B 已就绪 · 仅在分析时加载，合成时不占内存"
                     : "未找到本地分析模型或 llama 组件，将回退规则解析")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StoryAnalyzer.available ? .secondary : .tertiary)
                Text("声线两阶段：先识别人物并锁定每人声线，再逐句只标情绪——同一角色全文音色一致。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

            case .cloud:
                Group {
                    field("接口地址（OpenAI 兼容）", text: $settings.cloudAPIBase,
                          hint: "如 https://api.deepseek.com/v1 / https://api.siliconflow.cn/v1")
                    field("API Key", text: $settings.cloudAPIKey, secure: true,
                          hint: "留空则回退本地模型或规则解析")
                    field("模型名", text: $settings.cloudAPIModel,
                          hint: "如 deepseek-chat / Qwen/Qwen2.5-7B-Instruct / gpt-4o-mini")
                }
                Text("选云端后小说分析全部走 API，本地不启动任何模型，零内存占用。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Divider().opacity(0.5).padding(.vertical, 2)

            Toggle("自动识别新角色人设", isOn: $settings.storyAutoProfile)
                .toggleStyle(.switch)
                .tint(Appearance.accent)
                .font(.system(size: 11.5))
            Text("分析时顺手提取年龄、性别、音色特征，预填进角色面板。关掉后新建角色全部空白。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Toggle("识别到新角色自动打开角色面板", isOn: $settings.storyAutoOpenRole)
                .toggleStyle(.switch)
                .tint(Appearance.accent)
                .font(.system(size: 11.5))
            Text("只对还没有基准音色的角色生效，方便一识别完就把声线定下来。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.faintFill))
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false,
                       hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5, weight: .medium))
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            Text(hint)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "采样")

            slider("CFG 强度", value: $settings.cfgScale, range: 1.0...2.5, step: 0.05,
                   hint: "1.0 关闭二次推理，最快")
            slider("温度 T", value: $settings.temperature, range: 0...1.5, step: 0.05,
                   hint: "0 用模型默认")
            slider("Top-P", value: $settings.topP, range: 0...1, step: 0.01,
                   hint: "0 用模型默认")
            slider("重复惩罚", value: $settings.repetitionPenalty, range: 0...1.6, step: 0.02,
                   hint: "0 用模型默认")

            HStack(spacing: 10) {
                stepper("Top-K", value: $settings.topK, range: 0...200, step: 5)
                stepper("帧上限", value: $settings.maxNewTokens, range: 0...1500, step: 50)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "长文本")
            stepper("分段字数", value: $settings.splitChars, range: -1...1200, step: 50)
            Text("0 = 默认 600 字；负数表示整段一次生成，超过一分钟音质会退化。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "数据位置")
            KeyValueRow(key: "模型", value: Paths.models.path)
            KeyValueRow(key: "导出", value: Paths.exports.path)
            KeyValueRow(key: "音色", value: Paths.voices.path)

            HStack(spacing: 8) {
                Button("打开数据目录") { Paths.reveal(Paths.appSupport) }
                    .quietPill()
                Button("重新运行引导") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        model.restartOnboarding()
                    }
                }
                .quietPill()
                Spacer()
            }

            Text("Breeze-TTS-2.cpp · arm64 · macOS \(DeviceInfo.osVersionString)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text("仅供个人学习、研究与自用")
                    .font(.system(size: 11, weight: .medium))
                Text("请勿用于违法用途，或未经授权克隆他人声音；公开发布 AI 生成音频请依法标识，生成内容由你自行负责。本项目按「现状」提供，不附带任何担保。若认为本项目侵犯你的权益，请通过仓库 Issues 告知，核实后及时下架。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.faintFill))
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(Appearance.accent)
    }


    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).tint(Appearance.accent)
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func stepper(_ title: String, value: Binding<Int>,
                         range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.faintFill)
        )
    }
}
