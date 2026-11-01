import SwiftUI
import AVFoundation
import AppIntents

@main
struct BreezeTTSiOSApp: App {
    @StateObject private var client = RemoteClient()
    @StateObject private var player = AudioBox()

    var body: some Scene {
        WindowGroup {
            RootView(client: client, player: player)
                .preferredColorScheme(nil)
                .tint(.primary)
        }
    }
}

/// Local playback of the WAV the Mac produced (current run + history items).
final class AudioBox: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var player: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var position: Double = 0
    /// Title of the clip currently loaded (history row / fresh generation).
    @Published var loadedTitle = ""
    var lastAudio: Data?

    func play(_ data: Data, title: String) {
        lastAudio = data
        loadedTitle = title
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.prepareToPlay()
        player?.play()
        isPlaying = true
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, let p = self.player else { timer.invalidate(); return }
            self.position = p.duration > 0 ? p.currentTime / p.duration : 0
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
        isPlaying = p.isPlaying
    }

    func seek(to fraction: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = fraction * p.duration
        position = fraction
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        position = 0
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @State private var showSettings = false

    var body: some View {
        Group {
            if client.base != nil && client.state != .disconnected {
                MainTabView(client: client, player: player)
            } else {
                ConnectView(client: client)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteAudioReady)) { note in
            if let data = note.object as? Data { player.play(data, title: "刚生成的语音") }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
        .task {
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let host = env["BREEZE_DEBUG_HOST"], !host.isEmpty {
                client.debugAutoConnect(host: host,
                                        port: Int(env["BREEZE_DEBUG_PORT"] ?? "") ?? 4748)
            }
            #endif
            client.startBrowsing()
        }
        .onDisappear { client.stopBrowsing() }
    }

    // MARK: Main — bottom tab bar: 合成 / 听书 / 对话（设置开启后）

    struct MainTabView: View {
        @ObservedObject var client: RemoteClient
        @ObservedObject var player: AudioBox
        @State private var showSettings = false
        @State private var showVoiceMenu = false
        @State private var showHistory = false
        @State private var tab = 0
        @State private var text = ""
        @State private var abText = ""

        var body: some View {
            VStack(spacing: 0) {
                header
                // 不用原生 TabView：它在 iOS 26 上自带悬浮标签栏，隐藏后仍会留残影，
                // 且 iPad 上会跑成顶部样式。这里用叠放 + 显隐切换，三页状态都保留，
                // 底部只留一个和 Mac 一样的胶囊导航。
                ZStack {
                    ComposerView(client: client, player: player, text: $text)
                        .opacity(tab == 0 ? 1 : 0)
                        .allowsHitTesting(tab == 0)
                    AudiobookContent(client: client, player: player, text: $abText)
                        .opacity(tab == 1 ? 1 : 0)
                        .allowsHitTesting(tab == 1)
                    if client.macChatEnabled {
                        ChatTab(client: client, player: player)
                            .opacity(tab == 2 ? 1 : 0)
                            .allowsHitTesting(tab == 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // iPad 上正文别横到屏幕两端，跟 Mac 一样收成居中的一列
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
            .sheet(isPresented: $showVoiceMenu) { VoiceMenuSheet(client: client) }
            .sheet(isPresented: $showHistory) { HistorySheet(client: client, player: player) }
            .task {
                #if DEBUG
                let env = ProcessInfo.processInfo.environment
                if let raw = env["BREEZE_DEBUG_TAB"], let value = Int(raw) { tab = value }
                if env["BREEZE_DEBUG_SETTINGS"] == "1" { showSettings = true }
                if env["BREEZE_DEBUG_VOICE"] == "1" { showVoiceMenu = true }
                if env["BREEZE_DEBUG_HISTORY"] == "1" { showHistory = true }
                if let sample = env["BREEZE_DEBUG_TEXT"] { text = sample }
                if env["BREEZE_DEBUG_GENERATE"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { client.generate(text: t, instruction: nil) }
                    }
                }
                if let sample = env["BREEZE_DEBUG_AB_TEXT"] { abText = sample }
                if env["BREEZE_DEBUG_AB_ANALYZE"] == "1", abText.count >= 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        client.audiobookAnalyze(text: abText)
                    }
                }
                #endif
            }
        }

        private var header: some View {
            HStack(spacing: 10) {
                Text("Breeze")
                    .font(.system(size: 15, weight: .semibold)).tracking(0.6)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(client.state == .ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                    Text(client.macModel.isEmpty ? "Mac" : client.macModel)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 13))
                }
                .buttonStyle(.plain)

                Button { client.checkStatus(); client.fetchSettings(); client.fetchHistory() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13))
                }
                .buttonStyle(.plain)

                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
        }

        // MARK: - 底部导航（一个胶囊装下：模式切换 + 音色 + 生成）

        private struct Mode {
            var tag: Int
            var title: String
            var icon: String
        }

        private var modes: [Mode] {
            var list = [Mode(tag: 0, title: "合成", icon: "waveform"),
                        Mode(tag: 1, title: "听书", icon: "book")]
            if client.macChatEnabled {
                list.append(Mode(tag: 2, title: "对话", icon: "bubble.left.and.bubble.right"))
            }
            return list
        }

        private var bottomBar: some View {
            HStack(spacing: 4) {
                ForEach(modes, id: \.tag) { mode in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tab = mode.tag }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: mode.icon).font(.system(size: 14, weight: .medium))
                            Text(mode.title).font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(tab == mode.tag ? Color.primary : Color.secondary)
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(tab == mode.tag ? Color.primary.opacity(0.08) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }

                // 右侧动作跟随当前页：合成页是「音色 + 生成」，听书页是那一步该做的事
                if tab == 0 {
                    hairline
                    voiceButton
                    generateButton
                } else if tab == 1 {
                    hairline
                    audiobookButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
        }

        private var hairline: some View {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22)
        }

        private var voiceButton: some View {
            Button { showVoiceMenu = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.wave.2").font(.system(size: 11))
                    Text(client.macVoice.isEmpty ? "音色" : client.macVoice)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(maxWidth: 96)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }

        private var trimmedText: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var canGenerate: Bool {
            client.state != .generating && !trimmedText.isEmpty
        }

        /// 胶囊里的主操作按钮：可用时实心主色 + 反色文字，不可用时降为浅灰。
        private func capAction(_ title: String,
                               icon: String?,
                               enabled: Bool,
                               busy: Bool = false,
                               action: @escaping () -> Void) -> some View {
            Button(action: { if enabled { action() } }) {
                HStack(spacing: 5) {
                    if busy {
                        ProgressView().controlSize(.mini).tint(.primary)
                    } else if let icon {
                        Image(systemName: icon).font(.system(size: 11, weight: .bold))
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .foregroundStyle(busy ? Color.primary : (enabled ? Theme.inverse : Color.secondary))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Capsule().fill(busy ? Color.primary.opacity(0.08)
                                                : Color.primary.opacity(enabled ? 1 : 0.1)))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .animation(.easeOut(duration: 0.2), value: enabled)
        }

        private var generateButton: some View {
            capAction(client.state == .generating ? "合成中" : "生成",
                      icon: client.state == .generating ? nil : "waveform",
                      enabled: canGenerate,
                      busy: client.state == .generating) {
                client.generate(text: trimmedText, instruction: nil)
            }
        }

        // MARK: 听书页的主操作：分析 → 生成 → 下载 → 播放，同一位置推进

        private var trimmedABText: String {
            abText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @ViewBuilder
        private var audiobookButton: some View {
            if client.abAnalyzing {
                capAction("分析中", icon: nil, enabled: false, busy: true) {}
            } else if client.abGenerating {
                capAction("合成 \(Int((client.abProgress * 100).rounded()))%",
                          icon: nil, enabled: false, busy: true) {}
            } else if client.abAudioID != nil {
                // 已经合成了：下载 → 播放
                if client.abDownloadedData == nil {
                    let p = client.abDownloadProgress
                    let downloading = (p ?? 0) < 1
                    capAction(downloading ? "下载 \(Int(((p ?? 0) * 100).rounded()))%" : "下载音频",
                              icon: "arrow.down.circle.fill",
                              enabled: !downloading,
                              busy: downloading) {
                        client.downloadAudiobook()
                    }
                } else {
                    capAction(player.isPlaying ? "暂停" : "播放",
                              icon: player.isPlaying ? "pause.fill" : "play.fill",
                              enabled: true) {
                        if player.player != nil {
                            player.toggle()
                        } else if let data = client.abDownloadedData {
                            player.play(data, title: "听书")
                        }
                    }
                }
            } else if client.abSegments > 0 {
                // 分句完成（人物识别失败走规则解析也算），可以直接合成
                capAction("生成 \(client.abSegments) 段",
                          icon: "waveform.badge.plus",
                          enabled: true) {
                    client.audiobookGenerate()
                }
            } else {
                capAction("分析人物", icon: "text.magnifyingglass",
                          enabled: trimmedABText.count >= 20) {
                    client.audiobookAnalyze(text: trimmedABText)
                }
            }
        }
    }
}

// MARK: - Composer (the writing surface + generate pill + progress + transport)

struct ComposerView: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @Binding var text: String

    var body: some View {
        VStack(spacing: 0) {
            // 与 Mac 端一致：正文直接写在画布上，不套灰底卡片
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("在这里输入要朗读的文本…")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15))
                    .padding(.horizontal, -5)
                    .padding(.vertical, -6)
            }
            .padding(.horizontal, 20).padding(.top, 14)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                // Real progress from the Mac's estimator while it synthesizes.
                if client.state == .generating {
                    GlassProgressiOS(fraction: client.progress ?? 0.04,
                                     label: client.statusText,
                                     remaining: client.remaining)
                        .padding(.horizontal, 20)
                }
                if player.player != nil {
                    TransportBar(player: player)
                        .padding(.horizontal, 20)
                }

                // 合成中进度卡片已经带状态文字了，下面这行只在空闲时显示，避免重复
                if client.state != .generating {
                    Text(client.statusText.isEmpty
                         ? (client.state == .ready ? "Mac 已就绪 · \(client.voiceCatalog.count) 个音色" : "")
                         : client.statusText)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.bottom, 10)
                }
            }
        }
    }
}

// MARK: - Glass progress (mirrors the Mac's GlassProgress card)

struct GlassProgressiOS: View {
    var fraction: Double
    var label: String
    var remaining: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                Text(label.isEmpty ? "Mac 合成中" : label)
                    .font(.system(size: 11.5)).lineLimit(1)
                Spacer()
                Text(remainingLabel)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.primary.opacity(0.75))
                        .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial))
        .animation(.easeOut(duration: 0.3), value: fraction)
    }

    private var remainingLabel: String {
        guard let remaining, remaining > 0.5 else {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return "\(Int((fraction * 100).rounded()))% · 剩 \(Int(remaining.rounded()))s"
    }
}

// MARK: - Transport (scrub + play, like the Mac transport row)

struct TransportBar: View {
    @ObservedObject var player: AudioBox

    var body: some View {
        VStack(spacing: 6) {
            if !player.loadedTitle.isEmpty {
                Text(player.loadedTitle)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }
}

// MARK: - Voice menu (the Mac's VoiceMenu, remote edition)

struct VoiceMenuSheet: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Mac 当前音色") {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text(client.macVoice.isEmpty ? "默认" : client.macVoice)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("使用中").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if !client.voiceCatalog.isEmpty {
                    Section("全部音色（\(client.voiceCatalog.count)）") {
                        ForEach(client.voiceCatalog) { voice in
                            Button {
                                client.applyVoice(voice)
                            } label: {
                                HStack {
                                    Image(systemName: voice.isClone ? "waveform.circle" : "wand.and.stars")
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voice.name).font(.system(size: 14))
                                        Text(voice.isClone ? "录音克隆" : "文字生成")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if voice.name == client.macVoice {
                                        Image(systemName: "checkmark").font(.system(size: 12))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Section {
                        Text("正在读取 Mac 的音色列表…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("音色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
        }
        .onAppear { client.fetchSettings() }
    }
}

// MARK: - Settings (mirrors Mac settings + pairing)

struct SettingsSheet: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    LabeledRow(title: "Mac 地址", value: client.base?.host ?? "-")
                    LabeledRow(title: "状态", value: client.statusText.isEmpty ? "已连接" : client.statusText)
                    HStack {
                        TextField("配对码（外网必填）", text: $pairing)
                            .font(.system(size: 13))
                        Button("保存") { client.setToken(pairing) }
                            .font(.system(size: 13, weight: .medium))
                            .disabled(pairing.isEmpty)
                    }
                }
                Section("播放（与 Mac 设置同步）") {
                    Toggle(isOn: Binding(get: { client.macStreaming }, set: { client.applyStreaming($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("边生成边播放")
                            Text("关（默认）= 整段一次解码更快；开 = 流式但更慢")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("当前声线指令（Mac 端）") {
                    Text(client.macInstruction.isEmpty ? "（默认：Speak clearly and naturally.）" : client.macInstruction)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        client.disconnect()
                        dismiss()
                    } label: {
                        Text("断开连接")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
        }
        .onAppear { pairing = UserDefaults.standard.string(forKey: "remote.token") ?? ""; client.fetchSettings() }
    }
}

struct LabeledRow: View {
    var title: String
    var value: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - History (play / open / download everything the Mac made)

struct HistorySheet: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @Environment(\.dismiss) private var dismiss
    @State private var loadingID: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if client.historyItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("还没有生成记录").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(client.historyItems) { item in
                        HStack(spacing: 12) {
                            Button {
                                guard loadingID == nil else { return }
                                loadingID = item.id
                                client.fetchHistoryAudio(id: item.id) { data in
                                    loadingID = nil
                                    if let data { player.play(data, title: item.title) }
                                }
                            } label: {
                                Image(systemName: loadingID == item.id ? "hourglass" : "play.circle.fill")
                                    .font(.system(size: 26))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 13.5)).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(item.date)
                                    Text("·")
                                    Text(String(format: "%.1fs", item.duration))
                                    if !item.voice.isEmpty {
                                        Text("·")
                                        Text(item.voice)
                                    }
                                }
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.hasAudio {
                                Button {
                                    client.fetchHistoryAudio(id: item.id) { data in
                                        guard let data else { return }
                                        let url = FileManager.default.temporaryDirectory
                                            .appendingPathComponent("breeze-\(item.id).wav")
                                        try? data.write(to: url)
                                        shareURL = url
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("历史（与 Mac 同步）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
            .refreshable { client.fetchHistory() }
            .sheet(item: Binding(get: { shareURL.map(ShareDoc.init) },
                                 set: { _ in shareURL = nil })) { doc in
                ActivityShareSheet(items: [doc.url])
            }
        }
        .onAppear { client.fetchHistory() }
    }
}

struct ShareDoc: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Audiobook (听书, remote edition: paste → analyze → generate)

/// 听书主内容：供底部 Tab 与弹层共用。
struct AudiobookContent: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @Binding var text: String

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if client.abCharacters.isEmpty && !client.abAnalyzing && !client.abGenerating {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("粘贴小说正文，至少 20 个字…")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 15)
                                    .padding(.top, 17)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $text)
                                .scrollContentBackground(.hidden)
                                .font(.system(size: 14))
                                .frame(minHeight: 180)
                                .padding(10)
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint))
                        Text("贴好后点底部「分析人物」。整本小说可以直接贴（或发 .txt 到 Mac 端）。Mac 会先识别人物并锁定每人声线，再逐句标注情绪——同一角色全文音色一致。分析引擎用 Mac 设置里的本地/云端配置。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }

                    if !client.abStatus.isEmpty {
                        Text(client.abStatus)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                    if client.abAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在分析人物与情绪（长文需要一会儿）…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }

                    if !client.abCharacters.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("人物（\(client.abCharacters.count)）· 声线已锁定")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(client.abCharacters) { c in
                                HStack {
                                    Text(c.name).font(.system(size: 13, weight: .medium))
                                    Text("\(c.age) · \(c.personality)")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                                    Spacer()
                                    Text("\(c.lines) 句").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint))
                    }

                    if client.abGenerating {
                        GlassProgressiOS(fraction: max(0.03, client.abProgress),
                                         label: client.abStatus,
                                         remaining: nil)
                    }

                    // Finished: download with live progress, then play / save.
                    if client.abAudioID != nil && !client.abGenerating {
                        if let p = client.abDownloadProgress, p < 1 {
                            GlassProgressiOS(fraction: max(0.03, p),
                                             label: "正在下载听书音频…",
                                             remaining: nil)
                        } else if client.abDownloadedData == nil {
                            Text("音频已合成好，点底部「下载音频」存到本机（\(client.clock(client.abAudioDuration))）")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        } else {
                            audiobookPlayer
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("听书")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: shareBinding) {
                if let item = shareItem {
                    ActivityShareSheet(items: [item])
                }
            }
            .onAppear { client.startAudiobookWatching() }
            .onDisappear { client.stopAudiobookWatching() }
        }

    /// Downloaded book: scrub bar with live position, play/pause, share/save.
    private var audiobookPlayer: some View {
        let dur = player.player?.duration ?? client.abAudioDuration
        let now = dur > 0 ? (player.position * dur) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if player.player != nil {
                        player.toggle()
                    } else if let data = client.abDownloadedData {
                        player.play(data, title: "听书")
                    }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: Binding(
                        get: { player.position },
                        set: { player.seek(to: $0) }))
                    HStack {
                        Text(client.clock(now))
                        Spacer()
                        Text(client.clock(dur))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button {
                    if let url = client.audiobookFileURL() {
                        showShare(url)
                    }
                } label: {
                    Label("保存 / 分享", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("已下载 · 可存到「文件」或其他 App")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.faint))
    }

    @State private var shareItem: URL?

    private func showShare(_ url: URL) {
        shareItem = url
    }

    private var shareBinding: Binding<Bool> {
        Binding(get: { shareItem != nil },
                set: { if !$0 { shareItem = nil } })
    }
}

// MARK: - Chat（对话 Tab，Mac 端 LLM 计算，回复自动用语音读出）

struct ChatTab: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if client.chatMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("和 Breeze 聊天")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("回复会自动用 Mac 的语音模型读出来。对话模型用 Mac 设置里的云端 API 或本地模型。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(client.chatMessages) { message in
                            ChatBubble(entry: message) {
                                if !message.isUser { client.speakChatReply(message.text) }
                            }
                            .id(message.id)
                        }
                        if client.chatThinking {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Mac 正在思考…")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 6)
                        }
                        if !client.chatError.isEmpty {
                            Text(client.chatError)
                                .font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: client.chatMessages.count) { _ in
                    if let last = client.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("说点什么…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.chatThinking)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.fetchChatHistory() }
    }

    private func send() {
        let text = draft
        draft = ""
        client.sendChat(text) { reply in
            // 回复自动朗读：走 Mac 合成管线，完成后自动播放。
            if let reply, !reply.isEmpty {
                client.speakChatReply(reply)
            }
        }
    }
}

private struct ChatBubble: View {
    let entry: RemoteClient.ChatEntry
    var onSpeak: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if entry.isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 13.5))
                if !entry.isUser {
                    Button(action: onSpeak) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(entry.isUser ? Color.primary.opacity(0.14) : Theme.faint))
            if !entry.isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Connect（首启引导：扫码绑定优先）

struct ConnectView: View {
    @ObservedObject var client: RemoteClient
    @State private var manualHost = ""
    @State private var token = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 4) {
                        Text("Breeze Remote")
                            .font(.system(size: 22, weight: .bold))
                        Text("Mac 负责全部计算，iPhone 发送命令、同步设置、收听与下载")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    if let failed = failureText {
                        Text(failed)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    // 引导第一步：扫码绑定。
                    Button {
                        showScanner = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 22, weight: .medium))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("扫码绑定 Mac")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Mac 端设置 → iPhone 连接 → 显示二维码")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12))
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("或：同一 Wi-Fi 下自动发现")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if client.servers.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在搜索 Mac…（首次会请求本地网络权限，请允许）")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        ForEach(client.servers) { mac in
                            Button { client.connect(to: mac) } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(mac.id).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11))
                                }
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("不在同一网络？填 Mac 的地址（公网 IP / 域名 / 内网穿透）")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("例如 12.34.56.78 或 mac.example.com:4747", text: $manualHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.faint))
                        TextField("配对码（Mac 设置里查看，外网必填）", text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.faint))
                        Button {
                            let parts = manualHost.split(separator: ":")
                            let port = parts.count == 2 ? Int(parts[1]) ?? 4747 : 4747
                            let host = String(parts.first ?? "")
                            client.setToken(token)
                            client.connectDirect(host: host, port: port)
                        } label: {
                            Text("连接").frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(manualHost.isEmpty)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint.opacity(0.6)))

                    if client.state == .connecting {
                        ProgressView()
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerSheet(client: client, isPresented: $showScanner)
        }
    }

    private var failureText: String? {
        if case .failed(let message) = client.state { return message }
        return nil
    }
}

// MARK: - QR 扫码绑定

struct QRScannerSheet: View {
    @ObservedObject var client: RemoteClient
    @Binding var isPresented: Bool
    @State private var denied = false
    /// scanning = 找码中；connecting = 已识别正在握手；failed = 显示原因可重扫。
    @State private var connectPhase: ScanPhase = .scanning

    enum ScanPhase: Equatable {
        case scanning
        case connecting
        case failed(String)
    }

    var body: some View {
        ZStack {
            QRScannerView { payload in
                handle(payload)
            }
            .ignoresSafeArea()
            .onAppear {
                QRScannerView.requestPermission { granted in denied = !granted }
            }
            .onChange(of: client.state) { newState in
                switch newState {
                case .ready:
                    isPresented = false
                case .failed(let message):
                    connectPhase = .failed(message)
                default:
                    break
                }
            }

            VStack {
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
                Spacer()
                VStack(spacing: 8) {
                    // 状态卡片：相机权限 / 扫码中 / 连接中 / 失败原因。
                    switch connectPhase {
                    case .connecting:
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("已识别，正在连接 Mac…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    case .failed(let message):
                        VStack(spacing: 10) {
                            Text(message)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            Button {
                                connectPhase = .scanning
                            } label: {
                                Text("重新扫描")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(.white))
                            }
                            .buttonStyle(.plain)
                        }
                    default:
                        Text(denied ? "相机权限被拒绝：请在设置 → BreezeTTS 里允许相机" : "对准 Mac 屏幕上的绑定二维码")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("Mac 端：设置 → iPhone 连接 → 显示二维码")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(16)
                .frame(maxWidth: 320)
                .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.55)))
                .padding(.bottom, 60)
            }
        }
    }

    private func handle(_ payload: String) {
        guard connectPhase == .scanning else { return }
        let ok = client.connectWithPairPayload(payload)
        if ok {
            // 解析成功进入连接中；结果由 client.state 驱动（成功关页、失败显示原因）。
            connectPhase = .connecting
        } else {
            // 内容无效：短暂展示后允许重扫。
            connectPhase = .failed("二维码内容无效，请扫 Mac 端「绑定二维码」")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if connectPhase != .connecting { connectPhase = .scanning }
            }
        }
    }
}

/// AVCaptureMetadataOutput 包装：识别 QR 后回调一次内容字符串。
struct QRScannerView: UIViewRepresentable {
    var onQRCode: (String) -> Void

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        view.onQRCode = onQRCode
        view.start()
        return view
    }

    func updateUIView(_ uiView: ScannerPreviewView, context: Context) {
        uiView.onQRCode = onQRCode
    }

    final class ScannerPreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var onQRCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var configured = false
        private let queue = DispatchQueue(label: "breeze.qr")

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func start() {
            // The preview layer is the view's own layer; bind it once on the main
            // thread or the camera feed never shows up (black screen, no scan).
            previewLayer.videoGravity = .resizeAspectFill
            if previewLayer.session !== session {
                previewLayer.session = session
            }
            queue.async { [weak self] in
                guard let self else { return }
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device) else { return }
                if !self.configured {
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    let output = AVCaptureMetadataOutput()
                    if self.session.canAddOutput(output) {
                        self.session.addOutput(output)
                        output.setMetadataObjectsDelegate(self, queue: .main)
                        output.metadataObjectTypes = [.qr]
                    }
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }

        func stop() {
            queue.async { [weak self] in
                if let self, self.session.isRunning { self.session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr, let value = object.stringValue else { return }
            onQRCode?(value)
        }
    }
}

// MARK: - Theme (matches the Mac design system: monochrome, adaptive)

enum Theme {
    static var canvas: Color { Color(uiColor: .systemBackground) }
    static var faint: Color { Color.primary.opacity(0.05) }
    /// 实心主色按钮上的反色文字
    static var inverse: Color { Color(uiColor: .systemBackground) }
}

// MARK: - Shortcuts（快捷指令）

/// Shortcuts entry: text in, audio file out. Uses the saved Mac connection.
struct GenerateSpeechIntent: AppIntent {
    static var title: LocalizedStringResource = "生成语音（BreezeTTS）"
    static var description = IntentDescription("把文本发送到 Mac 合成，返回音频文件")

    @Parameter(title: "文本")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("把 \(\.$text) 合成为语音") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let base = RemoteClient.sharedBase else {
            throw NSError(domain: "BreezeTTS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先打开 BreezeTTS 连接 Mac"])
        }
        var request = URLRequest(url: base.appendingPathComponent("generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        if !RemoteClient.sharedToken.isEmpty {
            request.setValue(RemoteClient.sharedToken, forHTTPHeaderField: "X-Breeze-Token")
        }
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            throw NSError(domain: "BreezeTTS", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "发送失败"])
        }
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let (jobData, _) = try await URLSession.shared.data(for: URLRequest(url: base.appendingPathComponent("job/\(id)")))
            let state = ((try? JSONSerialization.jsonObject(with: jobData)) as? [String: Any])?["state"] as? String ?? "running"
            if state == "done" { break }
            if state == "failed" {
                throw NSError(domain: "BreezeTTS", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Mac 端合成失败"])
            }
        }
        let (audio, response) = try await URLSession.shared.data(for: URLRequest(url: base.appendingPathComponent("audio/\(id)")))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "BreezeTTS", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "取回音频失败"])
        }
        return .result(value: IntentFile(data: audio, filename: "speech.wav", type: .wav))
    }
}
