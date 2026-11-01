import Foundation

/// Two-stage story analysis shared by the local LLM and cloud APIs:
///
///   Stage 1 (cast)      — decide WHO is in the story and lock each speaker's
///                         base timbre description once. This is the only step
///                         allowed to talk about voices.
///   Stage 2 (delivery)  — walk the text chunk by chunk and write ONLY an
///                         emotion/pacing hint per line. The timbre stays
///                         locked, so a character sounds identical at minute
///                         2 and minute 20; only the mood bends.
///
/// Engines:
///   - local  : llama.cpp subprocess + Qwen2.5-1.5B Q4 (one-shot, exits after)
///   - cloud  : any OpenAI-compatible /chat/completions endpoint — zero local
///              memory; the llama process is never started.
enum StoryAnalyzer {
    struct AnalyzerError: Error { let message: String }

    struct Outcome {
        var segments: [StorySegment]
        var characters: [StoryCharacter]
    }

    /// OpenAI-compatible cloud endpoint description.
    struct CloudConfig {
        var baseURL: String   // e.g. https://api.deepseek.com/v1
        var apiKey: String
        var model: String     // e.g. deepseek-chat
    }

    // MARK: - Local toolchain locations

    static func binaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("llama-bin/llama"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("llama"),
            // Dev builds running from DerivedData.
            Bundle.main.executableURL?
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("../../../Vendor/llama-bin/llama"),
        ]
        for case let url? in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    static func modelURL() -> URL? {
        let url = Paths.models.appendingPathComponent("qwen2.5-1.5b-instruct-q4_k_m.gguf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var available: Bool { binaryURL() != nil && modelURL() != nil }

    // MARK: - Entry point

    /// Analyzes a story. `cloud` wins when non-nil (user picked 云端 in
    /// settings); the local model is never touched on that path.
    static func analyze(text: String,
                        cloud: CloudConfig?,
                        progress: @escaping (String) -> Void = { _ in },
                        completion: @escaping (Result<Outcome, AnalyzerError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<Outcome, AnalyzerError>
            if let cloud {
                result = analyzeCloud(text: text, config: cloud, progress: progress)
                if case .failure = result, available {
                    // Cloud failed → fall back to the local model silently.
                    progress("云端分析失败，回退本地模型…")
                    result = analyzeLocal(text: text, progress: progress)
                }
            } else {
                result = analyzeLocal(text: text, progress: progress)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Shared two-stage pipeline

    /// Chunk size for stage 2 walks. Small enough for the 1.5B model to keep
    /// track of the cast, large enough to not spam requests.
    private static let stage2ChunkSize = 4500
    /// Stage 1 only reads the opening — that's where characters are introduced.
    private static let stage1SampleSize = 6000

    private static func chunks(of text: String, size: Int) -> [String] {
        var out: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[index..<end]))
            index = end
        }
        return out.isEmpty ? [""] : out
    }

    /// Runs stage 1 (cast) then stage 2 (per-chunk delivery hints) through the
    /// given chat backend. `chat(system, user, maxTokens)` returns raw text.
    private static func runTwoStages(text: String,
                                     progress: @escaping (String) -> Void,
                                     chat: (String, String, Int) -> Result<String, AnalyzerError>) -> Result<Outcome, AnalyzerError> {
        // ---- Stage 1: cast + locked timbres -------------------------------
        progress("阶段 1/2 · 识别人物与锁定声线…")
        let castUser = "小说开头：\n\(text.prefix(stage1SampleSize))"
        let castJSON: String
        switch chat(stage1System, castUser, 1600) {
        case .success(let raw):
            guard let json = extractJSON(from: raw),
                  (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil else {
                return .failure(AnalyzerError(message: "人物识别输出无法解析"))
            }
            castJSON = json
        case .failure(let error):
            return .failure(error)
        }
        guard let castObject = try? JSONSerialization.jsonObject(with: Data(castJSON.utf8)) as? [String: Any] else {
            return .failure(AnalyzerError(message: "人物表解析失败"))
        }

        // ---- Stage 2: per-chunk delivery hints ----------------------------
        let pieces = chunks(of: text, size: stage2ChunkSize)
        var characters = parseCharacters(from: castObject)
        var segments: [StorySegment] = []

        for (index, piece) in pieces.enumerated() {
            progress(pieces.count > 1
                     ? "阶段 2/2 · 逐句标注情绪（第 \(index + 1)/\(pieces.count) 块）…"
                     : "阶段 2/2 · 逐句标注情绪…")
            let user = "人物表：\n\(castJSON)\n\n小说片段：\n\(piece)"
            let parsed: [[String: Any]]?
            switch chat(stage2System, user, 3800) {
            case .success(let raw):
                parsed = extractJSON(from: raw)
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["segments"] as? [[String: Any]]
            case .failure:
                parsed = nil
            }
            if let parsed, !parsed.isEmpty {
                appendSegments(parsed, into: &segments)
            } else {
                // One chunk failed → rule-parse just that chunk so the book
                // still reads through instead of erroring out.
                appendRaw(text: piece, into: &segments)
            }
        }
        guard !segments.isEmpty else {
            return .failure(AnalyzerError(message: "模型没有返回分段"))
        }

        for index in characters.indices {
            let name = characters[index].name
            let lines = segments.filter { $0.speaker == name }
            characters[index].lines = lines.count
            characters[index].sample = lines.first.map { String($0.text.prefix(24)) } ?? ""
        }
        return .success(Outcome(segments: segments, characters: characters))
    }

    // MARK: - Local engine

    static func analyzeSync(text: String) -> Result<Outcome, AnalyzerError> {
        analyzeLocal(text: text, progress: { _ in })
    }

    static func analyzeLocal(text: String,
                             progress: @escaping (String) -> Void) -> Result<Outcome, AnalyzerError> {
        guard let binary = binaryURL() else { return .failure(AnalyzerError(message: "找不到 llama-cli")) }
        guard let model = modelURL() else { return .failure(AnalyzerError(message: "未下载分析模型")) }

        return runTwoStages(text: text, progress: progress) { system, user, maxTokens in
            llamaChat(binary: binary, model: model, system: system, user: user, maxTokens: maxTokens)
        }
    }

    private static func llamaChat(binary: URL, model: URL, system: String, user: String,
                                  maxTokens: Int) -> Result<String, AnalyzerError> {
        let process = Process()
        process.executableURL = binary
        // New llama.cpp splits the CLI into subcommands; `cli` is the chat one.
        process.arguments = [
            "cli",
            "-m", model.path,
            "-sys", system,
            "-p", user,
            "-n", String(maxTokens),
            "--temp", "0.2",
            "-ngl", "99",
            "--simple-io",
            "-st",
        ]
        return runLlama(process: process, timeout: 420)
    }

    /// Shared subprocess runner: waits, terminates on timeout, reads stdout.
    static func runLlama(process: Process, timeout: Double) -> Result<String, AnalyzerError> {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(AnalyzerError(message: "无法启动分析进程：\(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            return .failure(AnalyzerError(message: "分析超时"))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return .failure(AnalyzerError(message: "模型没有输出"))
        }
        return .success(output)
    }

    // MARK: - Chat（对话功能复用两个引擎）

    /// Local LLM chat turn. History is folded into the user turn — the 1.5B
    /// model runs one-shot per message, so no KV cache survives between turns.
    static func localChat(history: [(role: String, text: String)],
                          system: String, maxTokens: Int = 600) -> Result<String, AnalyzerError> {
        guard let binary = binaryURL() else { return .failure(AnalyzerError(message: "找不到 llama-cli")) }
        guard let model = modelURL() else { return .failure(AnalyzerError(message: "未下载本地模型")) }
        var transcript = ""
        for turn in history.dropLast() {
            let who = turn.role == "assistant" ? "助手" : "用户"
            transcript += "\(who)：\(turn.text)\n"
        }
        if let last = history.last {
            transcript += "用户：\(last.text)\n助手："
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "cli", "-m", model.path,
            "-sys", system,
            "-p", transcript,
            "-n", String(maxTokens),
            "--temp", "0.7",
            "-ngl", "99",
            "--simple-io", "-st",
        ]
        return runLlama(process: process, timeout: 180)
    }

    // MARK: - Cloud engine (OpenAI-compatible)

    private static func analyzeCloud(text: String,
                                     config: CloudConfig,
                                     progress: @escaping (String) -> Void) -> Result<Outcome, AnalyzerError> {
        runTwoStages(text: text, progress: progress) { system, user, maxTokens in
            cloudChat(config: config, system: system, user: user, maxTokens: maxTokens)
        }
    }

    /// Synchronous chat completion; runs on a background queue only.
    static func cloudChat(config: CloudConfig, system: String, user: String,
                          maxTokens: Int) -> Result<String, AnalyzerError> {
        cloudChat(config: config,
                  messages: [["role": "system", "content": system],
                             ["role": "user", "content": user]],
                  maxTokens: maxTokens)
    }

    /// Full-history chat completion (the对话 conversation uses this).
    /// content 可以是纯字符串，也可以是 OpenAI 视觉格式的数组
    ///（[{type:"text"...},{type:"image_url", image_url:{url:"data:..."}}]）。
    static func cloudChat(config: CloudConfig, messages: [[String: Any]],
                          maxTokens: Int = 800) -> Result<String, AnalyzerError> {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            return .failure(AnalyzerError(message: "API 地址无效"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": 0.7,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var payload: (data: Data, response: URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { payload = (data, response) }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 180) == .success,
              let payload, let http = payload.response as? HTTPURLResponse else {
            return .failure(AnalyzerError(message: "云端请求超时"))
        }
        guard http.statusCode == 200 else {
            let detail = String(data: payload.data, encoding: .utf8)?.prefix(160) ?? ""
            return .failure(AnalyzerError(message: "云端返回 \(http.statusCode)：\(detail)"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            return .failure(AnalyzerError(message: "云端响应格式异常"))
        }
        return .success(content)
    }

    // MARK: - Prompts

    /// Stage 1 — cast + 角色档案（任务 A）。这里写下的 ageDesc / gender / feature
    /// 只用来生成该角色的基准参考音色，正文朗读阶段不再出现。
    private static let stage1System = """
    你是小说人物档案提取器。读小说开头，找出所有会说话的角色，输出严格 JSON（不要输出任何其他文字）：
    {"characters":[{"name":"名字","age":"儿童|少年|青年|中年|老年","personality":"温柔|活泼|沉稳|冷淡|亲和|磁性","ageDesc":"年龄描述，如：二十多岁、少年、中年、老年","gender":"男|女|中性","feature":"音色气质特征，一句话"}]}
    规则：
    1. 只列确有台词或明确出场的角色；不超过 8 个，主角在前。
    2. ageDesc 简短；gender 只能是 男 / 女 / 中性。
    3. feature 只写稳定的底色音色质感（音高、共鸣、气息、口音），不要写情绪、语速这类临时表演信息。
    4. 原文信息不足就保守推测，不要编造复杂特征。
    """

    /// Stage 2 — delivery only. Timbre is locked by the cast table; the model
    /// may not touch voices, so line 1 and line 400 of a character sound alike.
    private static let stage2System = """
    你是小说朗读编排助手。人物表和每个人的声线已经确定并锁定，你不能再描述或改变声线。
    按原文顺序逐句切分给定片段，为每句只写情绪与语速提示（如：低沉悲伤，语速慢），不得涉及音色、年龄、性别。
    输出严格 JSON（不要输出任何其他文字）：
    {"segments":[{"speaker":"人物表中的名字或null表示旁白","text":"原文这一句","voice":"情绪与语速提示，不超过12个词"}]}
    规则：segments 必须按原文顺序覆盖给定片段全文；每段不合并；旁白 speaker 为 null；说话人只能用人物表里的名字。
    """

    // MARK: - Parsing

    private static func extractJSON(from output: String) -> String? {
        // Chat mode echoes the turns and may wrap the answer in a ```json
        // fence — prefer the fence, then fall back to the outermost braces
        // after the last echo marker.
        if let fenceStart = output.range(of: "```json"),
           let fenceEnd = output[fenceStart.upperBound...].range(of: "```") {
            return String(output[fenceStart.upperBound..<fenceEnd.lowerBound])
        }
        if let marker = output.range(of: "assistant", options: .backwards) {
            let tail = output[marker.upperBound...]
            if let start = tail.firstIndex(of: "{"), let end = tail.lastIndex(of: "}"), start < end {
                return String(tail[start...end])
            }
        }
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end {
            return String(output[start...end])
        }
        return nil
    }

    private static func parseCharacters(from object: [String: Any]) -> [StoryCharacter] {
        var characters: [StoryCharacter] = []
        if let rawCharacters = object["characters"] as? [[String: Any]] {
            for raw in rawCharacters {
                guard let name = raw["name"] as? String, !name.isEmpty else { continue }
                let age = raw["age"] as? String ?? "青年"
                let personality = raw["personality"] as? String ?? "沉稳"
                // 兼容旧模型输出：没有 feature 时退回 voice 字段。
                let feature = (raw["feature"] as? String)
                    ?? (raw["voice"] as? String)
                    ?? StoryParser.featureDescription(personality)
                characters.append(StoryCharacter(name: name,
                                                 age: age,
                                                 personality: personality,
                                                 lines: 0,
                                                 sample: "",
                                                 ageDesc: raw["ageDesc"] as? String
                                                    ?? StoryParser.ageDescription(age),
                                                 gender: normalizeGender(raw["gender"] as? String),
                                                 feature: feature))
            }
        }
        return characters
    }

    private static func normalizeGender(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("男") { return "男" }
        if text.contains("女") { return "女" }
        return "中性"
    }

    // MARK: - 任务 A（单独调用）：给后来才出场的角色补档案

    /// 只做「角色档案提取」，和剧本分句（任务 B）是两次独立调用。
    /// `names` 里每个角色都会拿到 ageDesc / gender / feature，返回的数组保持原顺序。
    static func extractProfiles(names: [String],
                                context: String,
                                cloud: CloudConfig?,
                                completion: @escaping ([String: [String: String]]) -> Void) {
        guard !names.isEmpty else { completion([:]); return }
        let system = """
        你是有声书角色档案提取器。输入小说上下文和角色名称，只输出严格 JSON，不要任何多余文字：
        {"characters":[{"name":"角色名","ageDesc":"年龄描述，如：二十多岁、少年、中年、老年","gender":"男|女|中性","feature":"音色气质特征，一句话"}]}
        规则：
        1. 依据上下文推断，信息不足就合理推测，不要编造复杂特征。
        2. feature 只写稳定底色音色质感（音高、共鸣、气息），不要写情绪、语速。
        3. feature 控制在 20 字以内。
        """
        let user = "角色：\(names.joined(separator: "、"))\n小说上下文：\n\(context.prefix(3000))"

        DispatchQueue.global(qos: .userInitiated).async {
            let chat: (String, String, Int) -> Result<String, AnalyzerError>
            if let cloud {
                chat = { system, user, maxTokens in
                    cloudChat(config: cloud, system: system, user: user, maxTokens: maxTokens)
                }
            } else if let binary = binaryURL(), let model = modelURL() {
                chat = { system, user, maxTokens in
                    llamaChat(binary: binary, model: model, system: system, user: user, maxTokens: maxTokens)
                }
            } else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            var result: [String: [String: String]] = [:]
            if case .success(let raw) = chat(system, user, 900),
               let json = extractJSON(from: raw),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let list = object["characters"] as? [[String: Any]] {
                for item in list {
                    guard let name = item["name"] as? String, !name.isEmpty else { continue }
                    result[name] = [
                        "ageDesc": item["ageDesc"] as? String ?? "",
                        "gender": normalizeGender(item["gender"] as? String),
                        "feature": item["feature"] as? String ?? "",
                    ]
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Appends LLM-parsed segments, renumbering ids and admitting speakers that
    /// are missing from the cast table (e.g. a voice that only appears later).
    private static func appendSegments(_ rawSegments: [[String: Any]], into segments: inout [StorySegment]) {
        for raw in rawSegments {
            let body = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let speaker = raw["speaker"] as? String
            let hint = raw["voice"] as? String
            segments.append(StorySegment(id: segments.count,
                                         speaker: speaker,
                                         text: body,
                                         hint: (hint?.isEmpty ?? true) ? nil : hint))
        }
    }

    /// Rule-based fallback for a single chunk (keeps the book readable when a
    /// chunk's model output fails to parse).
    private static func appendRaw(text: String, into segments: inout [StorySegment]) {
        for piece in StoryParser.segments(in: text) {
            segments.append(StorySegment(id: segments.count,
                                         speaker: piece.speaker,
                                         text: piece.text,
                                         hint: piece.hint))
        }
    }
}
