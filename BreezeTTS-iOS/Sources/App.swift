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
        .task { client.startBrowsing() }
        .onDisappear { client.stopBrowsing() }
    }

    // MARK: Main — bottom tab bar: 合成 / 听书 / 对话（设置开启后）

    struct MainTabView: View {
        @ObservedObject var client: RemoteClient
        @ObservedObject var player: AudioBox
        @State private var showSettings = false

        var body: some View {
            VStack(spacing: 0) {
                header
                TabView {
                    ComposerView(client: client, player: player)
                        .tabItem { Label("合成", systemImage: "waveform") }
                    NavigationStack { AudiobookContent(client: client, player: player) }
                        .tabItem { Label("听书", systemImage: "book") }
                    if client.macChatEnabled {
                        ChatTab(client: client, player: player)
                            .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                    }
                }
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
            .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
        }
    }
}

// MARK: - Composer (the writing surface + generate pill + progress + transport)

struct ComposerView: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var player: AudioBox
    @State private var text = ""
    @State private var showVoiceMenu = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { showVoiceMenu = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.badge.plus").font(.system(size: 11))
                        Text(client.macVoice.isEmpty ? "选择音色" : client.macVoice)
                            .font(.system(size: 11.5)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { showHistory = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                        Text("历史").font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 6)

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 15))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.faint))
                .padding(.horizontal, 20).padding(.top, 10)

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
                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    client.generate(text: trimmed, instruction: nil)
                } label: {
                    HStack {
                        Image(systemName: client.state == .generating ? "hourglass" : "waveform")
                        Text(client.state == .generating ? "Mac 合成中" : "生成语音")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.primary.opacity(client.state == .generating || text.isEmpty ? 0.04 : 0.1)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(client.state == .generating || text.isEmpty)
                .padding(.horizontal, 20)

                Text(client.statusText.isEmpty
                     ? (client.state == .ready ? "Mac 已就绪 · \(client.voiceCatalog.count) 个音色" : "")
                     : client.statusText)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $showVoiceMenu) { VoiceMenuSheet(client: client) }
        .sheet(isPresented: $showHistory) { HistorySheet(client: client, player: player) }
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
    @State private var text = ""

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if client.abCharacters.isEmpty && !client.abAnalyzing && !client.abGenerating {
                        TextEditor(text: $text)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 14))
                            .frame(minHeight: 180)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.faint))
                        Button {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard trimmed.count >= 20 else { return }
                            client.audiobookAnalyze(text: trimmed)
                        } label: {
                            Label("发送到 Mac 分析人物", systemImage: "text.magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        Text("整本小说贴进来（或发 .txt 到 Mac 端）。Mac 会先识别人物并锁定每人声线，再逐句标注情绪——同一角色全文音色一致。分析引擎用 Mac 设置里的本地/云端配置。")
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

                        if !client.abGenerating {
                            Button {
                                client.audiobookGenerate()
                            } label: {
                                Label("生成听书音频（\(client.abSegments) 段）", systemImage: "waveform.badge.plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .disabled(client.abSegments == 0)
                        }
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
                            Button {
                                client.downloadAudiobook()
                            } label: {
                                Label("下载听书音频（\(client.clock(client.abAudioDuration))）",
                                      systemImage: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
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
            previewLayer.videoGravity = .resizeAspectFill
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
