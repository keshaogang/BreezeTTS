import Foundation
import Combine

/// 对话功能：消息会话 + LLM 后端（本地 llama.cpp / 云端 OpenAI 兼容）+
/// 回复的语音朗读。文本回答在后台队列计算，朗读走合成引擎队列，
/// 与听书/普通生成互不打断（按段粒度排队）。
final class ChatService: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: String        // "user" | "assistant"
        let text: String
        let time: Date
        /// 用户附带的图片（JPEG 压缩后），仅视觉模型可用。
        var imageData: Data? = nil
        var isUser: Bool { role == "user" }

        static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
    }

    @Published var messages: [Message] = []
    @Published var thinking = false
    @Published var errorText = ""
    /// 正在合成语音的回复 id（UI 上显示小喇叭动画）。
    @Published var speakingMessageID: UUID?
    /// 朗读合成进度 0…1（nil = 空闲）。供对话界面画语音进度条。
    @Published var speakProgress: Double?
    /// 待发送的图片（输入框上方预览）。
    @Published var pendingImage: Data?

    /// 由 AppModel 注入：用当前音色合成一段文本并自动播放。
    /// progress 回调随合成实时报 0…1，completion 在播放结束/失败后调用。
    var speakHandler: ((String, @escaping (Double) -> Void, @escaping () -> Void) -> Void)?

    /// iOS 端拉取会话用（经 RemoteServer）。
    var historyProvider: () -> [[String: Any]] {
        { self.messages.suffix(80).map {
            ["role": $0.role, "text": $0.text,
             "time": Int($0.time.timeIntervalSince1970)] as [String: Any]
        } }
    }

    var systemPrompt: String {
        "你是 BreezeTTS 内置的语音助手。回答保持简洁自然、口语化，" +
        "一般不超过三句话，方便朗读。遇到需要长内容的请求（写代码、写文章）时再展开。"
    }

    /// 发送一条消息（可附图，视觉模型专用）。完成后若开启朗读，用 TTS 播出回复。
    func send(_ raw: String, imageData: Data? = nil, settings: AppSettings) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || imageData != nil, !thinking else { return }

        messages.append(Message(role: "user", text: text.isEmpty ? "（图片）" : text,
                                time: Date(), imageData: imageData))
        pendingImage = nil
        thinking = true
        errorText = ""

        let history = messages.suffix(20).map { (role: $0.role, text: $0.text, image: $0.imageData) }
        let backend = settings.chatBackend
        let cloud = settings.cloudConfig

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reply: Result<String, StoryAnalyzer.AnalyzerError>
            switch backend {
            case .cloud:
                if let cloud {
                    var msgs: [[String: Any]] = [["role": "system", "content": self?.systemPrompt ?? ""]]
                    for turn in history.dropLast() {
                        msgs.append(["role": turn.role, "content": turn.text])
                    }
                    // 最后一条用户消息：带图时用 OpenAI 视觉 content 数组。
                    if let last = history.last {
                        if let jpeg = last.image {
                            msgs.append(["role": "user", "content": [
                                ["type": "text", "text": last.text],
                                ["type": "image_url", "image_url":
                                    ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                            ]])
                        } else {
                            msgs.append(["role": "user", "content": last.text])
                        }
                    }
                    reply = StoryAnalyzer.cloudChat(config: cloud, messages: msgs, maxTokens: 800)
                } else if StoryAnalyzer.available {
                    reply = StoryAnalyzer.localChat(history: history.map { (role: $0.role, text: $0.text) },
                                                    system: self?.systemPrompt ?? "")
                } else {
                    reply = .failure(.init(message: "未配置云端 API Key，也未安装本地模型（设置 → 对话）"))
                }
            case .local:
                if StoryAnalyzer.available {
                    reply = StoryAnalyzer.localChat(history: history.map { (role: $0.role, text: $0.text) },
                                                    system: self?.systemPrompt ?? "")
                } else if let cloud {
                    var msgs: [[String: Any]] = [["role": "system", "content": self?.systemPrompt ?? ""]]
                    for turn in history.dropLast() {
                        msgs.append(["role": turn.role, "content": turn.text])
                    }
                    if let last = history.last {
                        if let jpeg = last.image {
                            msgs.append(["role": "user", "content": [
                                ["type": "text", "text": last.text],
                                ["type": "image_url", "image_url":
                                    ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                            ]])
                        } else {
                            msgs.append(["role": "user", "content": last.text])
                        }
                    }
                    reply = StoryAnalyzer.cloudChat(config: cloud, messages: msgs, maxTokens: 800)
                } else {
                    reply = .failure(.init(message: "未找到本地对话模型，也未配置云端 API"))
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.thinking = false
                switch reply {
                case .success(let answer):
                    let cleaned = answer
                        .replacingOccurrences(of: "assistant：", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = Message(role: "assistant", text: cleaned, time: Date())
                    self.messages.append(message)
                    self.errorText = ""
                    if settings.chatSpeak {
                        self.speak(message)
                    }
                case .failure(let error):
                    self.errorText = error.message
                }
            }
        }
    }

    /// 用 TTS 朗读某条回复（走合成引擎队列，不 cancel 正在跑的生成）。
    func speak(_ message: Message) {
        guard !message.text.isEmpty else { return }
        speakingMessageID = message.id
        speakProgress = 0
        speakHandler?(message.text, { [weak self] fraction in
            DispatchQueue.main.async { self?.speakProgress = fraction }
        }) { [weak self] in
            DispatchQueue.main.async {
                self?.speakingMessageID = nil
                self?.speakProgress = nil
            }
        }
    }

    func clear() {
        messages.removeAll()
        errorText = ""
    }
}
