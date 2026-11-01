import AppKit
import SwiftUI

/// 对话视图：气泡会话 + 输入框，回复自动（或点击）用语音模型朗读。
/// 两种呈现：弹层（固定尺寸）或主窗口内全屏（onClose 由 MainView 传入）。
struct ChatSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var chat: ChatService
    @ObservedObject private var settings: AppSettings
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showVoiceMenu = false
    @State private var showVoiceManager = false

    init(model: AppModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.chat = model.chat
        self.settings = model.settings
        self.onClose = onClose
    }

    /// 全屏时消息流和输入框收在中间一栏，宽度跟写作区一致。
    private var contentWidth: CGFloat? { onClose == nil ? nil : 720 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            emptyState
                        }
                        ForEach(chat.messages) { message in
                            Bubble(message: message,
                                   speaking: chat.speakingMessageID == message.id,
                                   speechProgress: chat.speakingMessageID == message.id
                                       ? chat.speakProgress : nil,
                                   onSpeak: { chat.speak(message) })
                                .id(message.id)
                        }
                        if chat.thinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(chatBackendLabel + " 正在思考…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 6)
                        }
                        if !chat.errorText.isEmpty {
                            Text(chat.errorText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: chat.messages.count) { _ in
                    if let last = chat.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // 待发送图片预览。
            if chat.pendingImage != nil {
                pendingImageRow
            }

            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .sheet(isPresented: $showVoiceManager) {
            VoiceSheet(model: model)
        }
    }

    private var chatBackendLabel: String {
        settings.chatBackend == .cloud
            ? (settings.cloudAPIModel.isEmpty ? "云端模型" : settings.cloudAPIModel)
            : "本地模型"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("对话")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(chatBackendLabel) · \(settings.chatSpeak ? "回复自动朗读" : "回复不朗读")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                chat.clear()
            } label: {
                Image(systemName: "eraser")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
            .help("清空会话")
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
            .help("返回")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("和 Breeze 聊天")
                .font(.system(size: 16, weight: .semibold))
            Text("回复会用当前音色读出来。引擎在 Mac 设置里选：本地模型（Qwen 1.5B，离线）或云端 API（设置 → 听书分析里填的接口）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var pendingImageRow: some View {
        HStack(spacing: 10) {
            if let data = chat.pendingImage,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.hairline))
                Text("将随下一条消息一起发送")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    chat.pendingImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除图片")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: contentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            // 音色按钮：与首页同款交互——点开浮层菜单，可进入音色管理。
            Button {
                showVoiceMenu = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 11, weight: .medium))
                    Text(model.voiceLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.faintFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showVoiceMenu, arrowEdge: .bottom) {
                VoiceMenu(model: model, isPresented: $showVoiceMenu) {
                    // 浮层完全收起后再弹管理面板，否则展示会被吞掉。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        showVoiceManager = true
                    }
                }
            }
            .fixedSize()
            .help("选择朗读音色（与主界面同步）")

            // 图片按钮：只有云端视觉模型才显示。
            if model.chatVisionAvailable {
                Button {
                    pickImage()
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.faintFill))
                }
                .buttonStyle(.plain)
                .disabled(chat.pendingImage != nil)
                .help("添加图片（当前模型支持识别图片）")
            }

            if #available(macOS 13.0, *) {
                TextField("说点什么…（↵ 发送）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill))
                    .onSubmit(send)
            } else {
                // 12 上没有多行 TextField，单行输入也能正常聊天。
                TextField("说点什么…（↵ 发送）", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill))
                    .onSubmit(send)
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       && chat.pendingImage == nil) || chat.thinking)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: contentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.message = "选择要发送给 AI 的图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chat.pendingImage = Self.compressedJPEG(at: url)
    }

    /// 压缩到视觉接口友好的大小：最长边 1120px、JPEG 0.85（约 <400KB base64）。
    static func compressedJPEG(at url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
              var tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let maxSide: CGFloat = 1120
        let longSide = max(rep.pixelsWide, rep.pixelsHigh)
        var scaled = rep
        if CGFloat(longSide) > maxSide {
            let ratio = maxSide / CGFloat(longSide)
            let newSize = NSSize(width: CGFloat(rep.pixelsWide) * ratio,
                                 height: CGFloat(rep.pixelsHigh) * ratio)
            let newRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: Int(newSize.width),
                                          pixelsHigh: Int(newSize.height),
                                          bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .calibratedRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)
            if let newRep, let ctx = NSGraphicsContext(bitmapImageRep: newRep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                rep.draw(in: NSRect(origin: .zero, size: newSize))
                NSGraphicsContext.restoreGraphicsState()
                scaled = newRep
            }
        }
        tiff = Data()
        return scaled.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func send() {
        let text = draft
        let image = chat.pendingImage
        draft = ""
        chat.pendingImage = nil
        chat.send(text, imageData: image, settings: settings)
    }
}

/// 一条消息气泡。自己的消息靠右实底，助手靠左玻璃底；助手带朗读按钮；
/// 正在合成语音的回复下方显示短进度条。
private struct Bubble: View {
    let message: ChatService.Message
    var speaking: Bool
    var speechProgress: Double?
    var onSpeak: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                if let jpeg = message.imageData, let nsImage = NSImage(data: jpeg) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15)))
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                }
                if !message.isUser {
                    Button(action: onSpeak) {
                        Image(systemName: speaking ? "waveform.circle.fill" : "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(speaking ? Color.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("朗读这条回复")

                    // 语音合成进度：短条 + 百分比，贴在正在朗读的回复下方。
                    if let progress = speechProgress {
                        HStack(spacing: 6) {
                            SlimProgress(fraction: max(0.04, progress))
                                .frame(width: 120, height: 3)
                            Text("语音 \(Int((progress * 100).rounded()))%")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.isUser ? Color.primary.opacity(0.14) : Theme.faintFill)
            )
            if !message.isUser { Spacer(minLength: 60) }
        }
    }
}
