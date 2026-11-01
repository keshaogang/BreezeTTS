import Combine
import Foundation

/// Persisted preferences. Everything the user can tune lives here so the UI
/// never owns state directly.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var strategy: ModelStrategy { didSet { defaults.set(strategy.rawValue, forKey: Keys.strategy) } }
    /// nil 表示跟随策略推荐
    @Published var overrideTierID: String? { didSet { defaults.set(overrideTierID, forKey: Keys.override) } }
    @Published var customModelPath: String? { didSet { defaults.set(customModelPath, forKey: Keys.customPath) } }
    @Published var useGPU: Bool { didSet { defaults.set(useGPU, forKey: Keys.useGPU) } }

    @Published var instruction: String { didSet { defaults.set(instruction, forKey: Keys.instruction) } }
    /// The hand-written instruction that a preset replaced, so the menu can offer
    /// it back instead of silently losing the user's wording.
    @Published var instructionBackup: String? { didSet { defaults.set(instructionBackup, forKey: Keys.instructionBackup) } }
    @Published var seed: Int { didSet { defaults.set(seed, forKey: Keys.seed) } }
    @Published var randomSeed: Bool { didSet { defaults.set(randomSeed, forKey: Keys.randomSeed) } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: Keys.temperature) } }
    @Published var topK: Int { didSet { defaults.set(topK, forKey: Keys.topK) } }
    @Published var topP: Double { didSet { defaults.set(topP, forKey: Keys.topP) } }
    @Published var repetitionPenalty: Double { didSet { defaults.set(repetitionPenalty, forKey: Keys.repPenalty) } }
    @Published var cfgScale: Double { didSet { defaults.set(cfgScale, forKey: Keys.cfgScale) } }
    @Published var maxNewTokens: Int { didSet { defaults.set(maxNewTokens, forKey: Keys.maxFrames) } }
    @Published var splitChars: Int { didSet { defaults.set(splitChars, forKey: Keys.splitChars) } }

    /// 边生成边播放。关闭（默认）= 整段一次解码，更快，结束时自动播放；
    /// 打开 = 流式，边合成边出声，但端到端更慢。
    @Published var streamPlayback: Bool { didSet { defaults.set(streamPlayback, forKey: Keys.streamPlayback) } }
    /// Allow the iPhone companion app to drive synthesis over the LAN.
    @Published var remoteServer: Bool { didSet { defaults.set(remoteServer, forKey: Keys.remoteServer) } }
    /// Set once the guided first-run setup has been finished.
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }

    /// macOS 26+ 的液态玻璃。关掉后统一用毛玻璃材质，12–15 上本来就只有毛玻璃。
    @Published var useLiquidGlass: Bool {
        didSet {
            defaults.set(useLiquidGlass, forKey: Keys.useLiquidGlass)
            Appearance.liquidGlassEnabled = useLiquidGlass
        }
    }
    /// 强调色跟随系统「外观 → 强调色」。关掉则回到黑白单色。
    @Published var followSystemAccent: Bool {
        didSet {
            defaults.set(followSystemAccent, forKey: Keys.followSystemAccent)
            Appearance.followSystemAccent = followSystemAccent
        }
    }
    /// 生成音频的保存位置；nil 表示用默认的 App 数据目录。
    @Published var exportDirectory: String? { didSet { defaults.set(exportDirectory, forKey: Keys.exportDirectory) } }

    /// 听书文本分析引擎：本地小模型（占内存）或云端 API（零本地开销）。
    @Published var storyBackend: StoryBackend { didSet { defaults.set(storyBackend.rawValue, forKey: Keys.storyBackend) } }
    /// OpenAI 兼容接口地址（可填 DeepSeek / 硅基流动 / 官方等）。
    @Published var cloudAPIBase: String { didSet { defaults.set(cloudAPIBase, forKey: Keys.cloudBase) } }
    @Published var cloudAPIKey: String { didSet { defaults.set(cloudAPIKey, forKey: Keys.cloudKey) } }
    @Published var cloudAPIModel: String { didSet { defaults.set(cloudAPIModel, forKey: Keys.cloudModel) } }

    /// 对话功能总开关：关闭后 Mac/iOS 底栏都不显示对话入口。
    @Published var chatEnabled: Bool { didSet { defaults.set(chatEnabled, forKey: Keys.chatEnabled) } }
    /// 对话 LLM：本地 llama.cpp（Qwen 1.5B）或云端 OpenAI 兼容 API。
    @Published var chatBackend: StoryBackend { didSet { defaults.set(chatBackend.rawValue, forKey: Keys.chatBackend) } }
    /// 回复后自动用语音模型朗读。
    @Published var chatSpeak: Bool { didSet { defaults.set(chatSpeak, forKey: Keys.chatSpeak) } }

    // MARK: 听书角色档案

    /// 分析时自动为新角色推断年龄 / 性别 / 音色特征，预填进角色面板。
    /// 关掉后角色面板是空的，全部由用户自己填。
    @Published var storyAutoProfile: Bool { didSet { defaults.set(storyAutoProfile, forKey: Keys.storyAutoProfile) } }
    /// 识别到还没有基准音色的角色时，自动把角色面板弹出来。
    @Published var storyAutoOpenRole: Bool { didSet { defaults.set(storyAutoOpenRole, forKey: Keys.storyAutoOpenRole) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawStrategy = defaults.string(forKey: Keys.strategy) ?? ModelStrategy.auto.rawValue
        self.strategy = ModelStrategy(rawValue: rawStrategy) ?? .auto
        self.overrideTierID = defaults.string(forKey: Keys.override)
        self.customModelPath = defaults.string(forKey: Keys.customPath)
        self.useGPU = defaults.object(forKey: Keys.useGPU) as? Bool ?? true

        self.instruction = defaults.string(forKey: Keys.instruction) ?? AppSettings.defaultInstruction
        self.instructionBackup = defaults.string(forKey: Keys.instructionBackup)
        self.seed = defaults.object(forKey: Keys.seed) as? Int ?? 42
        self.randomSeed = defaults.object(forKey: Keys.randomSeed) as? Bool ?? false
        self.temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.0
        self.topK = defaults.object(forKey: Keys.topK) as? Int ?? 0
        self.topP = defaults.object(forKey: Keys.topP) as? Double ?? 0.0
        self.repetitionPenalty = defaults.object(forKey: Keys.repPenalty) as? Double ?? 0.0
        self.cfgScale = defaults.object(forKey: Keys.cfgScale) as? Double ?? 1.0
        self.maxNewTokens = defaults.object(forKey: Keys.maxFrames) as? Int ?? 0
        self.splitChars = defaults.object(forKey: Keys.splitChars) as? Int ?? 0
        self.streamPlayback = defaults.object(forKey: Keys.streamPlayback) as? Bool ?? false
        self.remoteServer = defaults.object(forKey: Keys.remoteServer) as? Bool ?? true
        self.onboarded = defaults.object(forKey: Keys.onboarded) as? Bool ?? false
        let glass = defaults.object(forKey: Keys.useLiquidGlass) as? Bool ?? true
        let accent = defaults.object(forKey: Keys.followSystemAccent) as? Bool ?? true
        self.useLiquidGlass = glass
        self.followSystemAccent = accent
        self.exportDirectory = defaults.string(forKey: Keys.exportDirectory)
        Appearance.liquidGlassEnabled = glass
        Appearance.followSystemAccent = accent
        self.storyBackend = StoryBackend(rawValue: defaults.string(forKey: Keys.storyBackend) ?? "") ?? .local
        self.cloudAPIBase = defaults.string(forKey: Keys.cloudBase) ?? "https://api.deepseek.com/v1"
        self.cloudAPIKey = defaults.string(forKey: Keys.cloudKey) ?? ""
        self.cloudAPIModel = defaults.string(forKey: Keys.cloudModel) ?? "deepseek-chat"
        self.chatEnabled = defaults.object(forKey: Keys.chatEnabled) as? Bool ?? true
        self.chatBackend = StoryBackend(rawValue: defaults.string(forKey: Keys.chatBackend) ?? "") ?? .cloud
        self.chatSpeak = defaults.object(forKey: Keys.chatSpeak) as? Bool ?? true
        self.storyAutoProfile = defaults.object(forKey: Keys.storyAutoProfile) as? Bool ?? true
        self.storyAutoOpenRole = defaults.object(forKey: Keys.storyAutoOpenRole) as? Bool ?? false
    }

    /// 听书分析云端配置；key 为空视为未配置。
    var cloudConfig: StoryAnalyzer.CloudConfig? {
        guard !cloudAPIKey.isEmpty else { return nil }
        return StoryAnalyzer.CloudConfig(baseURL: cloudAPIBase,
                                         apiKey: cloudAPIKey,
                                         model: cloudAPIModel)
    }

    /// 生成音频落到哪个文件夹。
    var exportFolder: URL {
        guard let path = exportDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return Paths.exports }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 出厂默认音色：成年女性、中文普通话、自然口语（不带播音腔）。
    static let defaultInstruction = "一位成年女性，中文普通话，声音温柔自然，语速适中，吐字清晰，像面对面聊天一样放松，不要播音腔。"

    var selection: ModelSelection {
        ModelSelection(strategy: strategy, memoryGB: DeviceInfo.memoryGB)
    }

    /// 云端模型是否大概率支持图片输入（按模型名特征判断）。
    /// OpenAI 兼容接口没有「能力查询」端点，只能按命名惯例推断；
    /// 命中任一视觉特征词才在对话里显示图片按钮。
    var cloudSupportsVision: Bool {
        let name = cloudAPIModel.lowercased()
        guard !name.isEmpty else { return false }
        let visionMarkers = [
            "gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4-mini",
            "vision", "vlm", "-vl", "vl-", "4v", "omni",
            "gemini", "claude", "pixtral", "llama-4", "llama4",
            "doubao-1.5-vision", "doubao-vision", "seed-1.6", "seed-1.8",
            "hunyuan-vision", "step-1v", "step-3", "yi-vision",
            "kimi-latest", "moonshot-v1-8k-vision", "moonshot-v1-32k-vision",
            "ernie-4.5-vl", "glm-4v", "glm-5v", "grok-4", "grok-vision",
        ]
        return visionMarkers.contains { name.contains($0) }
    }

    /// 推荐档（未考虑覆盖）
    var recommendedSpec: ModelSpec { selection.recommendedSpec }

    /// 最终生效
    var resolvedSpec: ModelSpec {
        ModelCatalog.spec(id: selection.resolvedID(overrideID: overrideTierID)) ?? recommendedSpec
    }

    func genParams() -> GenParams {
        GenParams(
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            seed: randomSeed ? Int.random(in: 0...Int(Int32.max)) : seed,
            cfgScale: Float(cfgScale),
            maxNewTokens: maxNewTokens,
            splitChars: splitChars,
            temperature: Float(temperature),
            topK: topK,
            topP: Float(topP),
            repetitionPenalty: Float(repetitionPenalty)
        )
    }

    private enum Keys {
        static let strategy = "model.strategy"
        static let override = "model.override"
        static let customPath = "model.customPath"
        static let useGPU = "engine.useGPU"
        static let instruction = "gen.instruction"
        static let instructionBackup = "gen.instruction.backup"
        static let seed = "gen.seed"
        static let randomSeed = "gen.randomSeed"
        static let temperature = "gen.temperature"
        static let topK = "gen.topK"
        static let topP = "gen.topP"
        static let repPenalty = "gen.repPenalty"
        static let cfgScale = "gen.cfgScale"
        static let maxFrames = "gen.maxNewTokens"
        static let splitChars = "gen.splitChars"
        static let streamPlayback = "playback.streamWhileGenerating"
        static let remoteServer = "remote.server"
        static let onboarded = "app.onboarded"
        static let useLiquidGlass = "appearance.liquidGlass"
        static let followSystemAccent = "appearance.systemAccent"
        static let exportDirectory = "export.directory"
        static let storyBackend = "story.backend"
        static let cloudBase = "story.cloud.base"
        static let cloudKey = "story.cloud.key"
        static let cloudModel = "story.cloud.model"
        static let chatEnabled = "chat.enabled"
        static let chatBackend = "chat.backend"
        static let chatSpeak = "chat.speak"
        static let storyAutoProfile = "story.autoProfile"
        static let storyAutoOpenRole = "story.autoOpenRole"
    }
}

/// 听书文本分析引擎。云端 = OpenAI 兼容 chat completions，零本地内存；
/// 本地 = llama.cpp 子进程 + Qwen 1.5B，离线可用。
enum StoryBackend: String {
    case local, cloud
}
