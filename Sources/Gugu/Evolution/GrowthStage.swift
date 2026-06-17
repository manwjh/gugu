import Foundation

enum GrowthStage: String, CaseIterable, Codable {
    case hatchling
    case fledgling
    case adult
    case spirit

    init(rawStage: String) {
        self = GrowthStage(rawValue: rawStage) ?? .hatchling
    }

    @MainActor
    var displayName: String {
        switch self {
        case .hatchling: return L.stageHatchling
        case .fledgling: return L.stageFledgling
        case .adult: return L.stageAdult
        case .spirit: return L.stageSpirit
        }
    }

    @MainActor
    var shortName: String {
        switch self {
        case .hatchling: return L.stageShortHatchling
        case .fledgling: return L.stageShortFledgling
        case .adult: return L.stageShortAdult
        case .spirit: return L.stageShortSpirit
        }
    }

    var order: Int {
        GrowthStage.allCases.firstIndex(of: self) ?? 0
    }

    var speechGuidance: String {
        switch self {
        case .hatchling: return L.speechGuidanceHatchling
        case .fledgling: return L.speechGuidanceFledgling
        case .adult: return L.speechGuidanceAdult
        case .spirit: return L.speechGuidanceSpirit
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
