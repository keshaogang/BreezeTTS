import Foundation

/// 听书角色档案：任务 A 的落库、基准参考音色的生成与读取。
///
/// 链路刻意拆成两段，别混：
///   1. 基准 ref 链路：档案（年龄/性别/音色特征）→ baseInstruction → 生成一次 ref 音频。
///   2. 正文链路：ref 音频 + ref_text 锁住音色，单句只带情绪提示。
/// 档案改过不会自动重生成 ref，只把 `refStale` 标脏，等用户主动点「重新生成」。
extension AppModel {

    // MARK: - 分析后的收尾

    /// 人物表变了：清掉失效的角色分配、补档案、按开关把面板弹出来。
    func afterCastChanged() {
        let ids = Set(audiobookCharacters.map(\.id))
        audiobookRoles = audiobookRoles.filter { ids.contains($0.key) }

        let missing = audiobookCharacters.filter {
            $0.feature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if settings.storyAutoProfile, !missing.isEmpty {
            fillProfiles(names: missing.map(\.name))
        }
        if settings.storyAutoOpenRole,
           let first = audiobookCharacters.first(where: { !$0.hasReference }) {
            pendingRoleEditorID = first.id
        }
    }

    /// 任务 A（单独一次调用）：给还没有档案的角色补 ageDesc / gender / feature。
    func fillProfiles(names: [String]) {
        guard !names.isEmpty, !profileFilling else { return }
        profileFilling = true
        let context = audiobookText
        let cloud = settings.storyBackend == .cloud ? settings.cloudConfig : nil
        let fallback = settings.storyBackend == .cloud && settings.cloudAPIKey.isEmpty
        if fallback {
            profileFilling = false
            return
        }
        StoryAnalyzer.extractProfiles(names: names, context: context, cloud: cloud) { [weak self] profiles in
            guard let self else { return }
            self.profileFilling = false
            guard !profiles.isEmpty else { return }
            for (index, character) in self.audiobookCharacters.enumerated() {
                guard let profile = profiles[character.name] else { continue }
                let ageDesc = profile["ageDesc"] ?? ""
                let feature = profile["feature"] ?? ""
                if !ageDesc.isEmpty { self.audiobookCharacters[index].ageDesc = ageDesc }
                if let gender = profile["gender"], !gender.isEmpty {
                    self.audiobookCharacters[index].gender = gender
                }
                if !feature.isEmpty { self.audiobookCharacters[index].feature = feature }
                self.audiobookCharacters[index].refStale = self.audiobookCharacters[index].hasReference
            }
            self.audiobookStatus = "已为 \(profiles.count) 个角色补全人设 · 可以逐个生成基准音色"
        }
    }

    // MARK: - 档案编辑

    func updateRoleProfile(_ id: UUID,
                           name: String? = nil,
                           ageDesc: String? = nil,
                           gender: String? = nil,
                           feature: String? = nil) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            audiobookCharacters[index].name = name.trimmingCharacters(in: .whitespaces)
        }
        if let ageDesc { audiobookCharacters[index].ageDesc = ageDesc }
        if let gender { audiobookCharacters[index].gender = gender }
        if let feature { audiobookCharacters[index].feature = feature }
        audiobookCharacters[index].refStale = audiobookCharacters[index].hasReference
    }

    func updateRoleRefText(_ id: UUID, text: String) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        audiobookCharacters[index].refText = text
        audiobookCharacters[index].refStale = audiobookCharacters[index].hasReference
    }

    func updateRoleRefSeed(_ id: UUID, seed: Int) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        audiobookCharacters[index].refSeed = seed
        audiobookCharacters[index].refStale = audiobookCharacters[index].hasReference
    }

    func updateRoleRefCFG(_ id: UUID, cfg: Double) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        audiobookCharacters[index].refCFG = min(6, max(2, cfg))
        audiobookCharacters[index].refStale = audiobookCharacters[index].hasReference
    }

    /// 把档案恢复成「按年龄性格标签推断」的保守值，不动已经生成的 ref。
    func resetRoleProfile(_ id: UUID) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        let character = audiobookCharacters[index]
        audiobookCharacters[index].ageDesc = StoryParser.ageDescription(character.age)
        audiobookCharacters[index].gender = "中性"
        audiobookCharacters[index].feature = StoryParser.featureDescription(character.personality)
        audiobookCharacters[index].refStale = character.hasReference
    }

    // MARK: - 基准参考音色

    /// 生成默认基准台词：短、平稳、不夹情绪，适合当锚点。
    static func defaultRefText(for character: StoryCharacter) -> String {
        "今天天气不错，我们边走边说吧。"
    }

    func roleRefURL(_ character: StoryCharacter) -> URL? {
        guard let file = character.refFile, !file.isEmpty else { return nil }
        let url = Paths.refs.appendingPathComponent(file)
        return Paths.exists(url) ? url : nil
    }

    /// 读回 ref 采样（重采样到引擎采样率），供正文合成直接喂给模型。
    func referenceSamples(for character: StoryCharacter) -> (samples: [Float], sampleRate: Double)? {
        guard let url = roleRefURL(character),
              let loaded = ExportService.readSamples(at: url) else { return nil }
        let target = SpeechEngine.shared.sampleRate
        let samples = loaded.sampleRate == target
            ? loaded.samples
            : ExportService.resample(loaded.samples, from: loaded.sampleRate, to: target)
        return (samples, target)
    }

    /// 生成（或重新生成）某个角色的基准音色。
    ///
    /// 缓存 key = baseInstruction + seed + refText：同样的 key 已经生成过就直接复用，
    /// 不让用户白等一遍推理。
    func generateRoleReference(_ id: UUID) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        guard refGeneratingID == nil else {
            refStatus = "正在生成另一个角色的基准音色，等它跑完"
            return
        }
        guard modelReady || isModelLoaded else {
            refStatus = "先加载语音模型，再生成基准音色"
            return
        }

        var character = audiobookCharacters[index]
        if character.feature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            character.feature = StoryParser.featureDescription(character.personality)
            audiobookCharacters[index].feature = character.feature
        }
        if character.refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            character.refText = Self.defaultRefText(for: character)
            audiobookCharacters[index].refText = character.refText
        }
        let key = character.referenceKey
        let fileName = "ref-\(Self.stableHash(key)).wav"
        let target = Paths.refs.appendingPathComponent(fileName)

        // 同 key 已有缓存 → 直接绑定，不再推理。
        if Paths.exists(target), Paths.size(of: target) > 1024 {
            audiobookCharacters[index].refFile = fileName
            audiobookCharacters[index].refStale = false
            refStatus = "\(character.name) 的基准音色已存在，直接复用"
            return
        }

        var params = settings.genParams()
        params.instruction = character.baseInstruction
        params.seed = character.refSeed
        params.cfgScale = Float(character.refCFG)

        refGeneratingID = id
        refStatus = "正在生成 \(character.name) 的基准音色…"
        let temp = Paths.cache.appendingPathComponent("ref-\(UUID().uuidString).wav")

        SpeechEngine.shared.generateToWAV(text: character.refText,
                                          params: params,
                                          refAudio: nil,
                                          refText: nil,
                                          outURL: temp) { [weak self] result in
            guard let self else { return }
            self.refGeneratingID = nil
            switch result {
            case .success:
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temp, to: target)
                    if let index = self.audiobookCharacters.firstIndex(where: { $0.id == id }) {
                        self.audiobookCharacters[index].refFile = fileName
                        self.audiobookCharacters[index].refStale = false
                    }
                    self.refStatus = "\(character.name) 的基准音色已生成 · 正文朗读会以它为锚点"
                } catch {
                    self.refStatus = "保存基准音色失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: temp)
                self.refStatus = "生成失败：\(error.localizedDescription)"
            }
        }
    }

    /// 试听已有 ref。
    func previewRoleReference(_ id: UUID) {
        guard let character = audiobookCharacters.first(where: { $0.id == id }),
              let url = roleRefURL(character) else {
            refStatus = "还没有基准音色"
            return
        }
        playback.play(url: url)
    }

    func clearRoleReference(_ id: UUID) {
        guard let index = audiobookCharacters.firstIndex(where: { $0.id == id }) else { return }
        if let file = audiobookCharacters[index].refFile {
            try? FileManager.default.removeItem(at: Paths.refs.appendingPathComponent(file))
        }
        audiobookCharacters[index].refFile = nil
        audiobookCharacters[index].refStale = false
        refStatus = "已删除 \(audiobookCharacters[index].name) 的基准音色"
    }

    /// 稳定哈希（Swift 的 hashValue 每次启动都变，不能拿来当文件名）。
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
