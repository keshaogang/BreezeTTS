import Foundation

/// One synthesized unit of an audiobook. `speaker == nil` is narration.
/// `hint` is an optional English voice direction for this line, written by the
/// local LLM (or empty when falling back to the rule parser): the character's
/// base voice stays fixed, only the delivery bends with the emotion.
struct StorySegment: Identifiable, Equatable {
    let id: Int
    let speaker: String?
    let text: String
    var hint: String?
    var isDialogue: Bool { speaker != nil }
}

/// A character the parser found, with editable profile tags. The tags map to a
/// default voice style, which the user can override per character.
///
/// 两套字段刻意分开，别混用：
///   · `age` / `personality`  —— 用来挑内置声线预设（自动模式）。
///   · `ageDesc` / `gender` / `feature` —— 角色档案，只负责“这个人的底色是什么样”，
///     拼成 `baseInstruction` 后在【生成基准参考音色】时用一次。
///
/// 基准音色（ref）一旦生成，正文朗读就只认 ref + 单句情绪提示，
/// 档案不再参与推理，避免人设和音色锚点打架。
struct StoryCharacter: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var age: String          // 儿童/少年/青年/中年/老年
    var personality: String  // 温柔/活泼/沉稳/冷淡/亲和/磁性
    var lines: Int = 0
    var sample: String = ""  // one line of dialogue, shown in the editor

    // MARK: 角色档案（任务 A 自动识别，用户可在高级设置里改）

    /// 年龄描述，例如「二十多岁」「少年」「中年」。
    var ageDesc: String = "青年"
    /// 男 / 女 / 中性。
    var gender: String = "中性"
    /// 音色气质，只写稳定底色，不写情绪与语速。
    var feature: String = ""

    // MARK: 基准参考音色

    /// 基准 ref 音频文件名（位于 `Paths.refs` 下）。nil = 还没生成。
    var refFile: String? = nil
    /// 生成 ref 时读的那句台词，回放时作为 ref_text 一起送进模型。
    var refText: String = ""
    var refSeed: Int = 42
    /// 生成 ref 专用 cfg（和正文 cfg 分开），默认 4.0。
    var refCFG: Double = 4.0
    /// 档案被改过但 ref 还是旧的那一版。
    var refStale: Bool = false

    /// 只用于生成 ref 的一句人设描述；正文合成阶段不再使用。
    var baseInstruction: String {
        let parts = [ageDesc, gender, feature]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "，")
    }

    var hasReference: Bool {
        guard let refFile, !refFile.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: Paths.refs.appendingPathComponent(refFile).path)
    }

    /// 档案 / 基准台词 / seed / cfg 变了，缓存 key 就变了 → 需要重新生成。
    /// （cfg 也算进去：只调 cfg 却拿到旧文件，用户会以为按钮没生效。）
    var referenceKey: String {
        String(format: "%@|%d|%@|%.2f", baseInstruction, refSeed, refText, refCFG)
    }
}

/// Local, rule-based novel parser. No network, no model: quotes mark dialogue,
/// speech verbs beside a quote attribute it to a name, and small keyword
/// tables guess age and personality. Everything stays editable in the UI.
enum StoryParser {

    // MARK: - Segmentation

    static func segments(in raw: String) -> [StorySegment] {
        var result: [StorySegment] = []
        var narrationBuffer = ""

        func flushNarration() {
            let trimmed = narrationBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            narrationBuffer = ""
            guard !trimmed.isEmpty else { return }
            result.append(StorySegment(id: result.count, speaker: nil, text: trimmed))
        }

        for paragraph in raw.components(separatedBy: .newlines) {
            let quotes = Self.quotedRanges(in: paragraph)
            guard !quotes.isEmpty else {
                narrationBuffer += paragraph + "\n"
                continue
            }

            var cursor = paragraph.startIndex
            for range in quotes {
                // Narration between the last quote and this one.
                let before = String(paragraph[cursor..<range.lowerBound])
                narrationBuffer += before
                flushNarration()

                let dialogue = String(paragraph[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "「」『』“”\""))
                    .trimmingCharacters(in: .whitespaces)
                if !dialogue.isEmpty {
                    let speaker = attributeSpeaker(paragraph: paragraph, quoteRange: range)
                    result.append(StorySegment(id: result.count, speaker: speaker, text: dialogue))
                }
                cursor = range.upperBound
            }
            narrationBuffer += String(paragraph[cursor...]) + "\n"
        }
        flushNarration()
        return result
    }

    /// Quoted spans: CJK corner brackets first, then curly/straight double quotes.
    private static func quotedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let cornerPairs: [[Character]] = [["「", "」"], ["『", "』"]]
        for pair in cornerPairs {
            var open: String.Index?
            for i in text.indices where text[i] == pair[0] || text[i] == pair[1] {
                if text[i] == pair[0] {
                    if open == nil { open = i }
                } else if let start = open {
                    ranges.append(start..<text.index(after: i))
                    open = nil
                }
            }
        }
        if ranges.isEmpty {
            // Curly / straight double quotes, paired in order.
            let delims: [Character] = ["“", "”", "\""]
            var open: String.Index?
            for i in text.indices where delims.contains(text[i]) {
                if open == nil {
                    open = i
                } else if text.distance(from: open!, to: i) > 1 {
                    ranges.append(open!..<text.index(after: i))
                    open = nil
                }
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: - Speaker attribution

    private static let speechVerbs = ["说道", "说", "道", "问道", "问", "喊道", "喊", "叫道",
                                      "回答", "答道", "笑道", "骂道", "骂", "嘀咕", "低声道",
                                      "轻声道", "开口", "吩咐", "大喊", "惊呼", "嘟囔",
                                      "反驳", "催促", "叹道", "念叨", "嘀咕道", "叹了口气"]

    private static let pronouns: Set<String> = ["他", "她", "它", "我", "你", "您", "他们", "她们",
                                                "两人", "三人", "众人", "大家", "对方", "那人",
                                                "这个人", "那个人", "谁", "爸爸", "妈妈"]

    /// Looks for `<name><verb>` just before the quote (「…」前) or just after
    /// (「…」他说). Falls back to nil → the UI lists it as 未识别.
    private static func attributeSpeaker(paragraph: String, quoteRange: Range<String.Index>) -> String? {
        let maxLookback = 24
        let beforeStart = paragraph.index(quoteRange.lowerBound, offsetBy: -maxLookback,
                                          limitedBy: paragraph.startIndex) ?? paragraph.startIndex
        let before = String(paragraph[beforeStart..<quoteRange.lowerBound])

        let afterEnd = paragraph.index(quoteRange.upperBound, offsetBy: maxLookback,
                                       limitedBy: paragraph.endIndex) ?? paragraph.endIndex
        let after = String(paragraph[quoteRange.upperBound..<afterEnd])

        for context in [before, after] {
            for verb in speechVerbs {
                guard let verbRange = context.range(of: verb) else { continue }
                let name = String(context[..<verbRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                if let cleaned = cleanName(name) { return cleaned }
            }
        }
        // 「名字：」 pattern directly before the quote.
        if before.hasSuffix("：") || before.hasSuffix(":") {
            let stem = String(before.dropLast()).trimmingCharacters(in: .whitespaces)
            if let cleaned = cleanName(stem) { return cleaned }
        }
        return nil
    }

    private static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        // Drop leading connectives like "，" pieces or "只听""只见".
        for prefix in ["只听", "只见", "接着", "然后", "这时", "突然", "于是", "但是", "但", "而"] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        guard (2...6).contains(name.count), name.allSatisfy({ $0.isCJKNameCharacter }),
              !pronouns.contains(name) else { return nil }
        return name
    }

    // MARK: - Characters

    /// 年龄关键词 → 标签，按优先级排列（"老者"先于"人"）。
    private static let ageKeywords: [(String, String)] = [
        ("老者", "老年"), ("老头", "老年"), ("老奶奶", "老年"), ("老奶奶", "老年"),
        ("老人家", "老年"), ("老人", "老年"), ("长老", "老年"), ("爷爷", "老年"), ("奶奶", "老年"),
        ("中年", "中年"), ("大叔", "中年"), ("大婶", "中年"), ("叔叔", "中年"), ("阿姨", "中年"),
        ("青年", "青年"), ("少年", "少年"), ("少女", "少年"), ("姑娘", "青年"),
        ("小伙", "青年"), ("先生", "青年"), ("小姐", "青年"), ("女人", "青年"), ("男人", "青年"),
        ("孩童", "儿童"), ("孩子", "儿童"), ("小孩", "儿童"), ("童", "儿童"), ("娃娃", "儿童"),
    ]

    private static let personalityKeywords: [(String, String)] = [
        ("冷冷", "冷淡"), ("冷淡", "冷淡"), ("冰冷", "冷淡"), ("严厉", "冷淡"), ("冷声道", "冷淡"),
        ("温柔", "温柔"), ("轻声", "温柔"), ("柔和", "温柔"), ("慈祥", "温柔"), ("温声道", "温柔"),
        ("兴奋", "活泼"), ("开心", "活泼"), ("笑道", "活泼"), ("欢快", "活泼"), ("调皮", "活泼"),
        ("大笑", "活泼"), ("活泼", "活泼"),
        ("沉稳", "沉稳"), ("低沉", "沉稳"), ("严肃", "沉稳"), ("缓缓道", "沉稳"), ("沉声道", "沉稳"),
        ("慈爱", "亲和"), ("和蔼", "亲和"), ("耐心", "亲和"), ("亲和", "亲和"),
        ("磁性", "磁性"), ("低语", "磁性"), ("深沉", "磁性"),
    ]

    static func characters(from segments: [StorySegment], fullText: String) -> [StoryCharacter] {
        var order: [String] = []
        var info: [String: (lines: Int, sample: String, age: String?, personality: String?)] = [:]

        for segment in segments where segment.isDialogue {
            guard let speaker = segment.speaker else { continue }
            if info[speaker] == nil {
                info[speaker] = (0, "", nil, nil)
                order.append(speaker)
            }
            info[speaker]!.lines += 1
            if info[speaker]!.sample.isEmpty {
                info[speaker]!.sample = String(segment.text.prefix(24))
            }
        }

        // Profiles: scan the full text once per keyword (small tables, cheap).
        var ages: [String: String] = [:]
        for (keyword, tag) in ageKeywords {
            if fullText.contains(keyword) {
                // Attribute to names that appear within a few chars of the keyword.
                for name in order where fullText.contains(name) {
                    if ages[name] == nil, let range = fullText.range(of: keyword) {
                        let start = fullText.index(range.lowerBound, offsetBy: -8,
                                                   limitedBy: fullText.startIndex) ?? fullText.startIndex
                        let end = fullText.index(range.upperBound, offsetBy: 8,
                                                 limitedBy: fullText.endIndex) ?? fullText.endIndex
                        if fullText[start..<end].contains(name) { ages[name] = tag }
                    }
                }
            }
        }
        var personalities: [String: String] = [:]
        for segment in segments where segment.isDialogue {
            guard let speaker = segment.speaker, personalities[speaker] == nil else { continue }
            for (keyword, tag) in personalityKeywords
            where fullText.contains(keyword) && segment.text.contains(keyword) {
                personalities[speaker] = tag
                break
            }
        }

        return order.compactMap { name in
            guard let entry = info[name] else { return nil }
            let age = ages[name] ?? defaultAge(for: name)
            let personality = personalities[name] ?? "沉稳"
            return StoryCharacter(name: name,
                                  age: age,
                                  personality: personality,
                                  lines: entry.lines,
                                  sample: entry.sample,
                                  ageDesc: StoryParser.ageDescription(age),
                                  gender: "中性",
                                  feature: StoryParser.featureDescription(personality))
        }
        .sorted { $0.lines > $1.lines }
    }

    /// 没有 LLM 时的保守人设：只按标签给中性描述，不编造。
    static func ageDescription(_ tag: String) -> String {
        switch tag {
        case "儿童": return "孩童"
        case "少年": return "少年"
        case "青年": return "青年"
        case "中年": return "中年"
        case "老年": return "老年"
        default: return "青年"
        }
    }

    static func featureDescription(_ personality: String) -> String {
        switch personality {
        case "温柔": return "柔和温暖的中音，气息平稳，带一点笑意"
        case "活泼": return "明亮轻快的音色，语速偏快，尾音上扬"
        case "沉稳": return "自然干净的中低音，咬字清晰，语调平稳"
        case "冷淡": return "偏冷的中音，气声少，尾音收得干脆"
        case "亲和": return "亲切自然的中音，像日常聊天，不用播音腔"
        case "磁性": return "低沉有磁性的中低音，共鸣靠后"
        default: return "自然干净的音色"
        }
    }

    /// No keyword matched: give a neutral default so the editor is never empty.
    private static func defaultAge(for name: String) -> String { "青年" }

    static var ageTags: [String] { ["儿童", "少年", "青年", "中年", "老年"] }
    static var personalityTags: [String] { ["温柔", "活泼", "沉稳", "冷淡", "亲和", "磁性"] }

    /// Best preset for a (age, personality) pair, used until the user overrides.
    static func presetID(age: String, personality: String) -> String {
        switch personality {
        case "温柔": return "warm"
        case "活泼": return "lively"
        case "沉稳": return "steady"
        case "冷淡": return "cinematic"
        case "亲和": return "teacher"
        case "磁性": return "cinematic"
        default: break
        }
        switch age {
        case "儿童": return "kid"
        case "少年": return "lively"
        case "中年": return "cinematic"
        case "老年": return "steady"
        default: return "teacher"
        }
    }
}

private extension Character {
    /// A permissive CJK name character check: Han, latin letters, middle dot.
    var isCJKNameCharacter: Bool {
        isLetter && !isWhitespace
    }
}
