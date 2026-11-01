import Foundation

/// The three strategies from the spec. `auto` is「听你的」and is the default.
enum ModelStrategy: String, CaseIterable, Identifiable, Codable {
    case memorySaver
    case fullPower
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memorySaver: return "我想省内存"
        case .fullPower:   return "我想跑全量"
        case .auto:        return "听你的"
        }
    }

    var subtitle: String {
        switch self {
        case .memorySaver: return "只要 Q4_K，后台常驻不抢内存"
        case .fullPower:   return "内存够就上 F16 / Q8_0"
        case .auto:        return "按机型自动挑一档"
        }
    }

    var symbol: String {
        switch self {
        case .memorySaver: return "leaf"
        case .fullPower:   return "bolt.fill"
        case .auto:        return "sparkles"
        }
    }
}

/// Pure decision logic for「三策略 + 自定义覆盖」，与 UI 无关，便于单测。
struct ModelSelection {
    let strategy: ModelStrategy
    let memoryGB: Int

    /// > 6 GB 的文件在 16 GB 及以下的机器上一律不推荐。
    static let hardSizeCeilingBytes: Int64 = 6_000_000_000
    static let heavyMemoryThresholdGB = 16
    static let fullPowerThresholdGB = 24

    /// 推荐档位。overrides 不参与，这是策略给出的「建议值」。
    var recommendedID: String {
        switch strategy {
        case .memorySaver:
            return "q4_k"
        case .fullPower:
            return memoryGB >= ModelSelection.fullPowerThresholdGB ? "f16" : "q8_0"
        case .auto:
            if memoryGB <= 8 { return "q4_k" }
            if memoryGB < ModelSelection.fullPowerThresholdGB { return "q8_0" }
            return "q8_0"
        }
    }

    var recommendedSpec: ModelSpec {
        ModelCatalog.spec(id: recommendedID) ?? ModelCatalog.all[1]
    }

    /// 是否允许把该档位当成「推荐」推给用户（红线判断）。
    func isRecommendedAllowed(_ spec: ModelSpec) -> Bool {
        if spec.id == "f16" {
            return strategy == .fullPower && memoryGB >= ModelSelection.fullPowerThresholdGB
        }
        if memoryGB <= ModelSelection.heavyMemoryThresholdGB && spec.bytes > ModelSelection.hardSizeCeilingBytes {
            return false
        }
        return true
    }

    /// 手动覆盖时不禁止，只提示。
    func warning(for spec: ModelSpec) -> String? {
        if spec.id == "f16" {
            if strategy != .fullPower {
                return "F16 仅在「我想跑全量」下开放"
            }
            if memoryGB < ModelSelection.fullPowerThresholdGB {
                return "需更大内存（建议 ≥ 24 GB，本机 \(memoryGB) GB）"
            }
            return nil
        }
        if memoryGB <= ModelSelection.heavyMemoryThresholdGB && spec.bytes > ModelSelection.hardSizeCeilingBytes {
            return "需更大内存（本机 \(memoryGB) GB）"
        }
        if spec.isExperimental {
            return "实验档：长文本不建议"
        }
        if spec.peakBytes > Int64(memoryGB) * 1_073_741_824 * 8 / 10 {
            return "峰值接近本机内存上限"
        }
        return nil
    }

    /// 最终生效的档位：用户在设置里的覆盖优先，其次才是策略推荐。
    func resolvedID(overrideID: String?) -> String {
        if let overrideID, let spec = ModelCatalog.spec(id: overrideID) {
            if spec.id == "f16" && !isRecommendedAllowed(spec) { return recommendedID }
            return spec.id
        }
        return recommendedID
    }
}

/// 用户显式选择的自定义模型（手动导入的 .gguf 也算）。
struct CustomModelChoice: Codable, Hashable {
    var displayName: String
    var path: String
    var bytes: Int64
}
