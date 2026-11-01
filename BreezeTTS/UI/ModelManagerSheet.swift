import SwiftUI
import UniformTypeIdentifiers

/// Model manager: strategy presets, every tier, download with byte-level
/// validation, manual import and overrides.
struct ModelManagerSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var downloader: ModelDownloader
    @State private var pending: ModelSpec?
    @State private var showImporter = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        self.downloader = model.downloader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollHost {
                VStack(alignment: .leading, spacing: 22) {
                    strategySection
                    tiersSection
                    customSection
                }
                .padding(22)
            }
        }
        .frame(width: 620, height: 620)
        .background(Theme.canvas)
        .alert("切换档位", isPresented: Binding(get: { pending != nil },
                                             set: { if !$0 { pending = nil } }),
               presenting: pending) { spec in
            Button("取消", role: .cancel) { pending = nil }
            Button("切换") {
                model.selectTier(spec.id)
                pending = nil
                dismiss()
            }
        } message: { spec in
            Text("将使用「\(spec.displayName)」。文件 \(spec.bytes.humanGB)，切换后会重新加载权重（需要几秒）。")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importModel(from: url)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("模型")
                    .font(.system(size: 15, weight: .semibold))
                Text(DeviceInfo.machineSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Paths.reveal(Paths.models) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Strategy

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "策略")
            HStack(spacing: 8) {
                ForEach(ModelStrategy.allCases) { strategy in
                    segment(strategy)
                }
            }
            Text("16 GB 及以下的机器不会推荐超过 6 GB 的权重；F16 只在内存 ≥ 24 GB 时开放。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func segment(_ strategy: ModelStrategy) -> some View {
        let active = model.settings.strategy == strategy
        return Button {
            model.settings.strategy = strategy
            model.settings.overrideTierID = nil
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: strategy.symbol).font(.system(size: 10.5, weight: .semibold))
                    Text(strategy.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                Text(strategy.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(active ? Theme.softFill : Theme.faintFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(active ? Appearance.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tiers

    private var tiersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "全部档位")
            ForEach(ModelCatalog.all) { spec in
                tierRow(spec)
            }
        }
    }

    private func tierRow(_ spec: ModelSpec) -> some View {
        let state = downloader.state(for: spec)
        let recommended = model.settings.recommendedSpec.id == spec.id
        let active = model.settings.resolvedSpec.id == spec.id
        let warning = model.settings.selection.warning(for: spec)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(spec.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                if recommended { Pill(text: "推荐", emphasis: true) }
                if active { Pill(text: "使用中") }
                if spec.isExperimental { Pill(text: "实验") }
                Spacer(minLength: 0)
                Text(spec.bytes.humanGB)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(spec.note)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning {
                Text(warning).font(.system(size: 10)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if state.isDownloading {
                    ProgressView(value: state.fraction)
                        .progressViewStyle(.linear)
                        .tint(Appearance.accent)
                        .frame(width: 150)
                    Text(progressText(state))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("暂停") { model.cancelDownload(spec) }.quietPill()
                } else if spec.installed {
                    Pill(text: "已安装")
                    Button("删除") { model.deleteModel(spec) }.quietPill()
                    if !active {
                        Button("使用") { pending = spec }.quietPill()
                    }
                } else {
                    Button(state.receivedBytes > 0 ? "继续" : "下载") { model.download(spec) }.quietPill()
                    if state.receivedBytes > 0 {
                        Text(state.receivedBytes.humanBytes)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(spec.peakLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if let error = state.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(active ? Theme.softFill : Theme.faintFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(active ? Appearance.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Custom

    private func progressText(_ state: ModelDownloader.TaskState) -> String {
        if state.isSearching { return "搜索新源…" }
        if state.isConnecting {
            return state.sourceLabel.isEmpty ? "连接中…" : "连接 \(state.sourceLabel)…"
        }
        if state.fraction > 0.995, state.totalBytes > state.receivedBytes {
            return "收尾中"
        }
        var parts = ["\(Int(state.fraction * 100))%"]
        if state.bytesPerSecond > 1_000 { parts.append(state.bytesPerSecond.humanSpeed) }
        if state.parallel > 1 { parts.append("\(state.parallel) 路") }
        return parts.joined(separator: " · ")
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "自定义")
            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 .gguf", systemImage: "plus")
                }
                .quietPill()

                if let custom = model.settings.customModelPath {
                    Text(URL(fileURLWithPath: custom).lastPathComponent)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("取消自定义") {
                        model.settings.customModelPath = nil
                    }
                    .quietPill()
                }
                Spacer(minLength: 0)
            }
            Text("导入的文件会复制到模型目录并优先使用。超出内存约束只提示、不禁止。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
