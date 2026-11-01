import Foundation

/// A style preset. It only rewrites the engine's `instruction` prompt, so it can
/// be applied instantly — no reference clip, no extra weights.
///
/// Styles stack on top of a cloned voice: the clone decides *who* speaks, the
/// style decides *how*.
struct VoiceStyle: Identifiable, Equatable {
    let id: String
    let name: String
    /// One short line the menu shows under the name.
    let summary: String
    /// English prompt handed to the engine.
    let instruction: String
    let symbol: String
    /// Words that make this style the obvious pick.
    let keywords: [String]
    let longFormBoost: Double
    let shortFormBoost: Double
    let exclaimBoost: Double
    let ellipsisBoost: Double
    let digitBoost: Double

    static func == (lhs: VoiceStyle, rhs: VoiceStyle) -> Bool { lhs.id == rhs.id }
}

enum VoiceStyles {
    /// The engine default: no styling at all.
    static let neutral = VoiceStyle(
        id: "neutral",
        name: "中性自然",
        summary: "不加修饰的默认声线",
        instruction: "Speak clearly and naturally.",
        symbol: "waveform",
        keywords: [],
        longFormBoost: 0, shortFormBoost: 0,
        exclaimBoost: 0, ellipsisBoost: 0, digitBoost: 0)

    static let all: [VoiceStyle] = [
        VoiceStyle(
            id: "warm",
            name: "温柔低语",
            summary: "语速偏慢，气声多一点",
            instruction: "Speak softly and warmly, a little slower than usual, with a gentle smile in the voice.",
            symbol: "heart",
            keywords: ["晚安", "亲爱的", "想你", "喜欢", "爱你", "温柔", "宝贝", "思念",
                       "抱抱", "别怕", "陪你", "心疼", "乖", "拥抱", "慢慢来"],
            longFormBoost: 0.3, shortFormBoost: 0.3,
            exclaimBoost: 0, ellipsisBoost: 0.6, digitBoost: 0),

        VoiceStyle(
            id: "steady",
            name: "沉稳旁白",
            summary: "中低音，纪录片旁白",
            instruction: "Use a calm, low-pitched narration voice at a steady pace, with short breaths between sentences.",
            symbol: "waveform.path",
            keywords: ["纪录片", "历史", "从前", "那一年", "记忆", "城市", "山河", "岁月",
                       "土地", "时代", "河流", "群山", "归来", "讲述"],
            longFormBoost: 1.6, shortFormBoost: -0.3,
            exclaimBoost: 0, ellipsisBoost: 0.3, digitBoost: 0),

        VoiceStyle(
            id: "news",
            name: "新闻播报",
            summary: "吐字清晰，节奏利落",
            instruction: "Read like a news anchor: crisp articulation, even rhythm, neutral tone, no emotion.",
            symbol: "newspaper",
            keywords: ["记者", "报道", "消息", "宣布", "会议", "数据", "同比", "增长", "通知",
                       "公告", "截至", "今日", "发布", "据统计", "政策", "来自", "方面"],
            longFormBoost: 0.7, shortFormBoost: 0.1,
            exclaimBoost: 0, ellipsisBoost: 0, digitBoost: 0.12),

        VoiceStyle(
            id: "lively",
            name: "活泼轻快",
            summary: "音调偏高，语气有活力",
            instruction: "Speak with bright energy and a slightly higher pitch, cheerful and quick.",
            symbol: "sparkles",
            keywords: ["哈哈", "太棒", "好耶", "冲", "姐妹", "宝子", "快来", "真香", "绝了",
                       "可爱", "开心", "好想", "心动", "上分"],
            longFormBoost: -0.4, shortFormBoost: 0.9,
            exclaimBoost: 0.8, ellipsisBoost: 0, digitBoost: 0),

        VoiceStyle(
            id: "cinematic",
            name: "磁性预告",
            summary: "低沉克制，留白多",
            instruction: "Deliver in a low, restrained cinematic trailer voice, slow with deliberate pauses.",
            symbol: "film",
            keywords: ["深夜", "传说", "秘密", "消失", "真相", "恐惧", "黑暗", "命运", "尽头",
                       "无人", "寂静", "沉睡", "苏醒", "倒数"],
            longFormBoost: 0.9, shortFormBoost: -0.2,
            exclaimBoost: 0, ellipsisBoost: 1.0, digitBoost: 0),

        VoiceStyle(
            id: "teacher",
            name: "亲和讲解",
            summary: "耐心、解释性强",
            instruction: "Explain patiently like a friendly teacher: clear, warm, unhurried, with small pauses between ideas.",
            symbol: "book",
            keywords: ["首先", "其次", "接下来", "原理", "步骤", "教程", "其实", "也就是说",
                       "举个例子", "为什么", "如何", "方法", "理解", "注意", "总结"],
            longFormBoost: 0.8, shortFormBoost: 0,
            exclaimBoost: 0, ellipsisBoost: 0.2, digitBoost: 0),

        VoiceStyle(
            id: "promo",
            name: "卖点解说",
            summary: "热情有推力，强调关键词",
            instruction: "Sell it: energetic, confident, punchy emphasis on key words, like a product launch host.",
            symbol: "megaphone",
            keywords: ["限时", "优惠", "立减", "抢购", "新品", "首发", "只要", "到手", "福利",
                       "折扣", "秒杀", "下单", "包邮", "仅需"],
            longFormBoost: 0, shortFormBoost: 0.3,
            exclaimBoost: 0.7, ellipsisBoost: 0, digitBoost: 0.1),

        VoiceStyle(
            id: "kid",
            name: "童声故事",
            summary: "轻快、表情丰富",
            instruction: "Tell it like a bedtime story for children: playful, expressive, light and bouncy.",
            symbol: "teddybear",
            keywords: ["小朋友", "故事", "从前有", "小熊", "森林", "公主", "恐龙", "兔子",
                       "魔法", "月亮", "星星", "城堡", "冒险"],
            longFormBoost: 0.5, shortFormBoost: 0.5,
            exclaimBoost: 0.4, ellipsisBoost: 0, digitBoost: 0),
    ]

    static func style(id: String) -> VoiceStyle? {
        if id == neutral.id { return neutral }
        return all.first { $0.id == id }
    }

    /// The preset whose instruction is currently in effect, or nil when the user
    /// typed their own wording.
    static func match(instruction: String) -> VoiceStyle? {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return neutral }
        return ([neutral] + all).first {
            $0.instruction.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}

/// Scores the presets against whatever is currently in the editor. Pure string
/// heuristics on purpose: no model, no network, answers instantly as you type.
enum VoiceAdvisor {
    struct Pick: Identifiable {
        let style: VoiceStyle
        let score: Double
        let reason: String

        var id: String { style.id }
    }

    static func recommend(for text: String, limit: Int = 3) -> [Pick] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let stats = Stats(text: trimmed)
        let haystack = trimmed.lowercased()

        var picks: [Pick] = []
        for style in VoiceStyles.all {
            var score = 0.0
            var hits: [String] = []
            for keyword in style.keywords where haystack.contains(keyword.lowercased()) {
                score += 2.0
                hits.append(keyword)
            }
            if stats.length > 240 { score += style.longFormBoost }
            if stats.length < 60 { score += style.shortFormBoost }
            score += Double(min(stats.exclaims, 4)) * style.exclaimBoost
            score += Double(min(stats.ellipsis, 3)) * style.ellipsisBoost
            score += Double(min(stats.digits, 12)) * style.digitBoost

            // Length and "it's a short line" bias the ranking, but they are not a
            // reason on their own — without one of these cues the menu stays
            // honest and offers the neutral voice instead of guessing.
            let hasCue = !hits.isEmpty
                || stats.exclaims >= 2
                || stats.ellipsis >= 1
                || stats.digits > 6
                || stats.length > 240
            guard hasCue, score > 0.4 else { continue }

            picks.append(Pick(style: style, score: score,
                              reason: reason(style: style, hits: hits, stats: stats)))
        }

        picks.sort { $0.score > $1.score }
        guard let top = picks.first else {
            return [Pick(style: VoiceStyles.neutral, score: 0, reason: "没有明显线索，用默认声线")]
        }
        // A keyword hit is worth far more than a length or punctuation nudge:
        // keep only the answers that are in the same league as the winner.
        let floor = max(0.4, top.score * 0.35)
        picks = picks.filter { $0.score >= floor }
        if picks.count < 2, !picks.contains(where: { $0.style.id == VoiceStyles.neutral.id }) {
            picks.append(Pick(style: VoiceStyles.neutral, score: 0, reason: "回到默认声线"))
        }
        return Array(picks.prefix(limit))
    }

    private static func reason(style: VoiceStyle, hits: [String], stats: Stats) -> String {
        if !hits.isEmpty {
            let quoted = hits.prefix(2).map { "「\($0)」" }.joined()
            return "提到\(quoted)"
        }
        if stats.length > 240 { return "长文本，适合叙述" }
        if stats.exclaims >= 2 { return "感叹句多，情绪饱满" }
        if stats.ellipsis >= 1 { return "有停顿感，适合慢速" }
        if stats.digits > 6 { return "含数据，适合播报" }
        // No distinguishing cue: say what the style itself is for rather than
        // inventing a reason.
        return style.summary
    }

    private struct Stats {
        let length: Int
        let exclaims: Int
        let ellipsis: Int
        let digits: Int

        init(text: String) {
            length = text.count
            exclaims = text.reduce(0) { $0 + (($1 == "!" || $1 == "！") ? 1 : 0) }
            digits = text.unicodeScalars.reduce(0) {
                $0 + ((0x30...0x39).contains($1.value) ? 1 : 0)
            }
            let dots = text.reduce(0) { $0 + (($1 == "…") ? 1 : 0) }
            let triples = max(0, text.components(separatedBy: "...").count - 1)
            ellipsis = dots + triples
        }
    }
}
