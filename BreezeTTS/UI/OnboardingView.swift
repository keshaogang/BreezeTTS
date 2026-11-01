import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-run setup. The main window stays locked until a model is on disk, so a
/// user can never land in the composer with nothing to synthesise with.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var downloader: ModelDownloader

    @State private var step: Step
    @State private var chosenID: String
    @State private var showImporter = false
    @Namespace private var glassNamespace

    enum Step: Int {
        case welcome, model, pair, ready
    }

    init(model: AppModel, step: Step = .welcome) {
        self.model = model
        self.downloader = model.downloader
        let recommended = model.settings.recommendedSpec.id
        _chosenID = State(initialValue: recommended)
        _step = State(initialValue: step)
    }

    private var chosenSpec: ModelSpec {
        ModelCatalog.spec(id: chosenID) ?? model.settings.recommendedSpec
    }

    private var choices: [ModelSpec] {
        var list = [model.settings.recommendedSpec]
        if let light = ModelCatalog.spec(id: "q4_k"), light.id != list[0].id {
            list.append(light)
        }
        return list
    }

    private var ready: Bool { model.modelReady || chosenSpec.installed }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                card
                    .frame(width: 520)

                Spacer(minLength: 24)

                dots
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WindowConfigurator())
        .frame(minWidth: 760, minHeight: 560)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importModel(from: url)
            }
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 28) {
            content
            actions
        }
        .padding(34)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassCard(cornerRadius: 30)
        .glassID("onboarding-card", in: glassNamespace)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .model: modelStep
        case .pair: pairStep
        case .ready: readyStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            mark(symbol: "waveform")
            Text("Breeze")
                .font(.system(size: 34, weight: .semibold))
                .tracking(-0.5)
            Text("本地语音合成。模型跑在这台 Mac 上，文本不出本机。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
            Text("接下来三步：选一个模型、等它下载完，再把 iPhone 连上（这一步可以跳过）。")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择模型")
                .font(.system(size: 24, weight: .semibold))
            Text("已按这台机器的 \(DeviceInfo.memoryGB) GB 内存挑好推荐档位，换轻一点也行。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(choices) { spec in
                    choiceRow(spec)
                }
            }

            downloadArea

            Button {
                showImporter = true
            } label: {
                Text("已有 .gguf 文件？导入")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func choiceRow(_ spec: ModelSpec) -> some View {
        let selected = spec.id == chosenID
        return Button {
            // 已下载的也要能点：用户可能想用本地现成的那个，之前拦住了导致
            // 只能在没下载的档位之间来回选。
            chosenID = spec.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Appearance.accent : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if spec.id == model.settings.recommendedSpec.id {
                            Pill(text: "推荐", emphasis: true)
                        }
                        if spec.installed {
                            Pill(text: "已下载")
                        }
                    }
                    Text(spec.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Theme.softFill : Theme.faintFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Appearance.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var downloadArea: some View {
        let state = downloader.state(for: chosenSpec)
        VStack(alignment: .leading, spacing: 8) {
            if chosenSpec.installed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    Text("\(chosenSpec.displayName) 已就绪")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary)
            } else if state.isDownloading {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.linear)
                    .tint(Appearance.accent)
                if state.isSearching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("原有下载源都不可用，正在自动搜索新源…")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else if state.isConnecting {
                    // 一个字节都没到：可能正在连 CDN，也可能被网络卡住了。
                    // 明确告诉用户在等什么，别让人对着 0% 干等。
                    HStack(spacing: 6) {
                        Text(state.sourceLabel.isEmpty ? "正在连接模型服务器…"
                             : "正在连接 \(state.sourceLabel)…")
                        if state.attempt > 0 {
                            Text("· 已切换第 \(state.attempt + 1) 个源")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text(progressLine(state))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    chosenID = chosenSpec.id
                    model.download(chosenSpec)
                } label: {
                    Text(state.receivedBytes > 0 ? "继续下载" : "下载模型")
                        .frame(minWidth: 120)
                }
                .primaryPill()

                if let error = state.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("复制下载链接") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(downloader.directLink(for: chosenSpec), forType: .string)
                                model.statusLine = "链接已复制，可用浏览器或下载工具下好后再「导入 .gguf」"
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Appearance.accent)

                            Button("从本地导入") { showImporter = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Appearance.accent)
                        }
                    }
                }
            }
        }
    }

    /// "37% · 942 MB / 2.4 GB · 3.1 MB/s · 剩余 12 分钟"
    private func progressLine(_ state: ModelDownloader.TaskState) -> String {
        // 最后几十 MB 常常只剩一两个连接在跑，先说明「在做收尾」，
        // 免得用户看到 100% 却迟迟不结束。
        let left = state.totalBytes - state.receivedBytes
        if state.isDownloading, state.fraction > 0.995, left > 0 {
            return "收尾中 · 还剩 \(left.humanBytes)"
        }
        var parts = [
            "\(Int(state.fraction * 100))%",
            "\(state.receivedBytes.humanBytes) / \(chosenSpec.bytes.humanBytes)"
        ]
        if state.bytesPerSecond > 1_000 {
            parts.append(state.bytesPerSecond.humanSpeed)
        }
        if let eta = state.etaSeconds {
            parts.append("剩余 \(eta.humanDuration)")
        }
        if state.parallel > 1 {
            parts.append("\(state.parallel) 路并行")
        }
        if !state.sourceLabel.isEmpty {
            parts.append(state.sourceLabel)
        }
        return parts.joined(separator: " · ")
    }

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            PairingCard(model: model, compact: true)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("这一步可以跳过：不配手机，Mac 上的功能也是完整的。")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var readyStep: some View {        VStack(alignment: .leading, spacing: 18) {
            mark(symbol: "checkmark")
            Text("准备好了")
                .font(.system(size: 24, weight: .semibold))
            Text("模型已在这台 Mac 上，随时可以开始。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 9) {
                KeyValueRow(key: "模型", value: model.modelLabel)
                KeyValueRow(key: "引擎", value: model.settings.useGPU ? "Metal（自动回退 CPU）" : "仅 CPU")
                KeyValueRow(key: "采样率", value: "\(Int(SpeechEngine.shared.sampleRate)) Hz")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.faintFill)
            )
        }
    }

    private func mark(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 46, height: 46)
            .background(Circle().fill(Color.primary))
            .foregroundStyle(Theme.inverse)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                } label: {
                    Text("返回")
                }
                .quietPill()
            }

            Spacer(minLength: 0)

            Button {
                advance()
            } label: {
                Text(primaryTitle)
                    .frame(minWidth: 92)
            }
            .primaryPill()
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1 : 0.4)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "开始"
        case .model: return "继续"
        case .pair: return "继续"
        case .ready: return "进入 Breeze"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome, .pair: return true
        case .model, .ready: return ready
        }
    }

    private func advance() {
        switch step {
        case .welcome:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { step = .model }
        case .model:
            guard ready else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { step = .pair }
        case .pair:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { step = .ready }
        case .ready:
            model.completeOnboarding()
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index == step.rawValue ? Color.primary : Color.primary.opacity(0.18))
                    .frame(width: index == step.rawValue ? 16 : 5, height: 5)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
    }
}
