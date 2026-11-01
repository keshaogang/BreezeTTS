import Foundation

/// JSON-backed stores for history and saved reference voices. Both are small, so
/// a whole-file rewrite per change is fine.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    private let limit = 200

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: Paths.historyFile, options: .atomic)
        }
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        if let url = item.url {
            try? FileManager.default.removeItem(at: url)
        }
        persist()
    }

    func clear() {
        for item in items {
            if let url = item.url { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll()
        persist()
    }
}

final class VoiceStore: ObservableObject {
    @Published private(set) var voices: [VoiceMeta] = []

    /// 随包分发的预置音色只灌一次，用户删掉后不会复活。
    private static let presetSeedKey = "voices.presetsSeeded.v1"

    init() {
        load()
        seedPresetsIfNeeded()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.voicesFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        voices = (try? decoder.decode([VoiceMeta].self, from: data)) ?? []
    }

    /// 全新的 Mac（音色文件还不存在）拿不到本机的音色，这里把内置的几条
    /// 文字音色写进去，免得别人装完只有一个默认音色可用。
    private func seedPresetsIfNeeded() {
        guard voices.isEmpty else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.presetSeedKey) else { return }
        defaults.set(true, forKey: Self.presetSeedKey)

        guard let url = Bundle.main.url(forResource: "preset-voices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([PresetVoice].self, from: data),
              !presets.isEmpty else { return }

        for preset in presets {
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let wording = preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !wording.isEmpty else { continue }
            voices.append(VoiceMeta(id: UUID(),
                                    name: name,
                                    createdAt: Date(),
                                    audioPath: "",
                                    refText: "",
                                    durationSeconds: 0,
                                    instruction: wording))
        }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(voices) {
            try? data.write(to: Paths.voicesFile, options: .atomic)
        }
    }

    @discardableResult
    func add(name: String, samples: [Float], sampleRate: Double, refText: String,
             instruction: String = "") throws -> VoiceMeta {
        Paths.ensureDirectories()
        let id = UUID()
        let url = Paths.voices.appendingPathComponent("\(id.uuidString).wav")
        try ExportService.writeWAV(samples: samples, sampleRate: sampleRate, to: url)
        let meta = VoiceMeta(id: id,
                             name: name,
                             createdAt: Date(),
                             audioPath: url.path,
                             refText: refText,
                             durationSeconds: Double(samples.count) / sampleRate,
                             instruction: instruction)
        voices.insert(meta, at: 0)
        persist()
        return meta
    }

    /// A voice defined purely by wording: no clip on disk, `instruction` set.
    @discardableResult
    func addTextVoice(name: String, instruction: String) -> VoiceMeta {
        let meta = VoiceMeta(id: UUID(),
                             name: name,
                             createdAt: Date(),
                             audioPath: "",
                             refText: "",
                             durationSeconds: 0,
                             instruction: instruction)
        voices.insert(meta, at: 0)
        persist()
        return meta
    }

    func rename(_ voice: VoiceMeta, to name: String) {
        guard let index = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[index].name = name
        persist()
    }

    /// 克隆音色的文字辅助描述（语气/语速/情绪），叠加在参考音频之上。
    func setInstruction(_ voice: VoiceMeta, instruction: String) {
        guard let index = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[index].instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func delete(_ voice: VoiceMeta) {
        voices.removeAll { $0.id == voice.id }
        // Text voices have no file; removing nothing must not error out loud.
        if !voice.isTextVoice {
            try? FileManager.default.removeItem(at: voice.url)
        }
        persist()
    }
}

/// `Resources/preset-voices.json` 里的一条预置音色：只有名字和描述，
/// 装到新机器时按需生成 VoiceMeta。
private struct PresetVoice: Decodable {
    var name: String
    var instruction: String
}
