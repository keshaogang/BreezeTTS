import Foundation

/// One downloadable / importable GGUF weight file.
struct ModelSpec: Identifiable, Hashable {
    let id: String          // stable id, also the file stem
    let fileName: String
    let displayName: String
    let bytes: Int64        // exact size, used for download validation
    let peakBytes: Int64    // rough working set while generating
    let summary: String     // one line shown in the tier row
    let note: String        // longer explanation
    let isExperimental: Bool

    var downloadURL: URL? {
        URL(string: "\(ModelCatalog.remoteBase)/\(fileName)")
    }

    var fileURL: URL { Paths.models.appendingPathComponent(fileName) }

    var installed: Bool {
        Paths.exists(fileURL) && Paths.size(of: fileURL) == bytes
    }

    var installedSize: Int64 {
        Paths.exists(fileURL) ? Paths.size(of: fileURL) : 0
    }

    /// "6.0 GB / 3.6 GB" style label for the UI.
    var sizeLabel: String { bytes.humanGB }
    var peakLabel: String { "峰值 \(peakBytes.humanGB)" }
}

enum ModelCatalog {
    /// HuggingFace is unreachable from some networks, so the mirror is the default.
    static let remoteBase = "https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main"
    static let upstreamBase = "https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main"

    static let referenceVoiceFile = "ref_voice.wav"
    static let referenceVoiceBytes: Int64 = 257_324

    /// Ordered from highest quality / heaviest to lightest.
    static let all: [ModelSpec] = [
        ModelSpec(
            id: "f16",
            fileName: "breeze-tts-2-f16.gguf",
            displayName: "F16 全精度",
            bytes: 6_279_630_784,
            peakBytes: 7_516_192_768,
            summary: "6.3 GB 文件 · 峰值约 7 GB",
            note: "只对「我想跑全量」且内存 ≥ 24 GB 的机器开放。听感上限，但吃内存最多。",
            isExperimental: false
        ),
        ModelSpec(
            id: "q8_0",
            fileName: "breeze-tts-2-q8_0.gguf",
            displayName: "Q8_0 无损近似",
            bytes: 3_568_844_480,
            peakBytes: 4_294_967_296,
            summary: "3.6 GB 文件 · 峰值约 4 GB",
            note: "16 GB 机器的默认上限，几乎听不出与 F16 的差别，是通用推荐档。",
            isExperimental: false
        ),
        ModelSpec(
            id: "q6_k",
            fileName: "breeze-tts-2-q6_k.gguf",
            displayName: "Q6_K 中档",
            bytes: 3_069_969_664,
            peakBytes: 3_758_096_384,
            summary: "3.0 GB 文件 · 峰值约 3.5 GB",
            note: "在体积与音质之间折中，适合同时开很多应用时使用。",
            isExperimental: false
        ),
        ModelSpec(
            id: "q4_k",
            fileName: "breeze-tts-2-q4_k.gguf",
            displayName: "Q4_K 省内存",
            bytes: 2_538_909_376,
            peakBytes: 3_221_225_472,
            summary: "2.5 GB 文件 · 峰值约 3 GB",
            note: "占用最小的一档通用权重，语气细节略降，长时间挂后台最稳。",
            isExperimental: false
        ),
        ModelSpec(
            id: "q8_0_dd2",
            fileName: "breeze-tts-2-q8_0-dd2.gguf",
            displayName: "Q8_0 + DD Q2_K",
            bytes: 3_322_429_120,
            peakBytes: 3_865_470_566,
            summary: "3.3 GB 文件 · 短句提速",
            note: "深度解码器压到 Q2_K 换取速度，短句更快，长文本不建议。",
            isExperimental: true
        ),
        ModelSpec(
            id: "q8_0_dd4",
            fileName: "breeze-tts-2-q8_0-dd4.gguf",
            displayName: "Q8_0 + DD Q4_K",
            bytes: 3_401_072_320,
            peakBytes: 3_951_257_600,
            summary: "3.4 GB 文件 · 短句提速",
            note: "深度解码器 Q4_K 版本，质量略高于 dd2，仍标注为实验档。",
            isExperimental: true
        ),
        ModelSpec(
            id: "q4_k_dd2",
            fileName: "breeze-tts-2-q4_k-dd2.gguf",
            displayName: "Q4_K + DD Q2_K",
            bytes: 2_460_266_176,
            peakBytes: 2_899_783_680,
            summary: "2.5 GB 文件 · 最省内存",
            note: "体积与内存都压到最低，适合小内存机器跑短句。",
            isExperimental: true
        )
    ]

    static func spec(id: String) -> ModelSpec? {
        all.first { $0.id == id }
    }

    static func spec(fileName: String) -> ModelSpec? {
        all.first { $0.fileName == fileName }
    }

    /// Every gguf in the models folder, including ones the user imported by hand.
    static func installedFiles() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return items
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
