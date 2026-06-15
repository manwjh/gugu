import Foundation

enum GrowthStage: String, CaseIterable, Codable {
    case hatchling
    case fledgling
    case adult
    case spirit

    init(rawStage: String) {
        self = GrowthStage(rawValue: rawStage) ?? .hatchling
    }

    var displayName: String {
        switch self {
        case .hatchling: return "幼鸟"
        case .fledgling: return "雏鸟"
        case .adult: return "成鸟"
        case .spirit: return "灵鸟"
        }
    }

    var shortName: String {
        switch self {
        case .hatchling: return "幼"
        case .fledgling: return "雏"
        case .adult: return "成"
        case .spirit: return "灵"
        }
    }

    var order: Int {
        GrowthStage.allCases.firstIndex(of: self) ?? 0
    }

    var speechGuidance: String {
        switch self {
        case .hatchling:
            return "你现在还是幼鸟:多用很短的词、拟声和动作回应;复杂事情可以听懂,但说出来要笨拙一点。"
        case .fledgling:
            return "你现在是雏鸟:能说短句,会表达观察,但仍然保持小鸟式的直接和有限记忆。"
        case .adult:
            return "你现在是成鸟:能正常短句对话,有稳定性格,会主动关心但不过度打扰。"
        case .spirit:
            return "你现在是灵鸟:可以偶尔有自己的观点和玩笑,但仍必须诚实、短句、基于真实观察。"
        }
    }

    var visualScale: CGFloat {
        switch self {
        case .hatchling: return 0.78
        case .fledgling: return 0.90
        case .adult: return 1.0
        case .spirit: return 1.07
        }
    }

    var budgetMultiplier: Double {
        switch self {
        case .hatchling: return 0.35
        case .fledgling: return 0.70
        case .adult: return 1.0
        case .spirit: return 1.45
        }
    }

    static func adjustedDailyTokens(base: Int, stage: GrowthStage) -> Int {
        max(1_000, Int(Double(base) * stage.budgetMultiplier))
    }
}
