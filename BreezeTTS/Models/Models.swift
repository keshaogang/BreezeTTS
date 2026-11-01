import Foundation

/// Values handed to the C ABI. `0` on a sampling field means "keep the GGUF default",
/// which is why the defaults here are zero rather than something friendly.
struct GenParams: Equatable {
    var instruction: String = "Speak clearly and naturally."
    var seed: Int = 42
    var cfgScale: Float = 1.0
    var maxNewTokens: Int = 0
    var splitChars: Int = 0
    var temperature: Float = 0.0
    var topK: Int = 0
    var topP: Float = 0.0
    var repetitionPenalty: Float = 0.0

    var samplingSummary: String {
        var parts: [String] = []
        parts.append("cfg \(String(format: "%.2f", cfgScale))")
        if temperature > 0 { parts.append("T \(String(format: "%.2f", temperature))") }
        if topK > 0 { parts.append("top-k \(topK)") }
        if topP > 0 { parts.append("top-p \(String(format: "%.2f", topP))") }
        if repetitionPenalty > 0 { parts.append("rp \(String(format: "%.2f", repetitionPenalty))") }
        return parts.joined(separator: " · ")
    }
}

/// A saved reference voice for cloning. `refText` must be the exact transcript.
struct VoiceMeta: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var audioPath: String
    var refText: String
    var durationSeconds: Double
    /// Non-nil for a text-described voice (no reference audio); the wording is
    /// used verbatim as the style instruction. Optional so older JSON files
    /// without the field still decode.
    var instruction: String? = nil

    /// Text voices carry no clip; the instruction *is* the voice.
    var isTextVoice: Bool { audioPath.isEmpty }

    var url: URL { URL(fileURLWithPath: audioPath) }
}

struct HistoryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var text: String
    var instruction: String
    var modelID: String
    var voiceName: String?
    var durationSeconds: Double
    var wavPath: String?
    var seed: Int
    /// Wall-clock seconds the run took, when it was recorded. Older entries
    /// predate the estimate feature and simply have nil.
    var computeSeconds: Double? = nil

    var url: URL? { wavPath.map { URL(fileURLWithPath: $0) } }

    var title: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 34 ? String(trimmed.prefix(34)) + "…" : trimmed
    }

    var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: createdAt)
    }

    var durationLabel: String {
        String(format: "%.1fs", durationSeconds)
    }
}
