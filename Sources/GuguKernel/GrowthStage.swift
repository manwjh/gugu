import Foundation

package enum GrowthStage: String, CaseIterable, Codable {
    case hatchling
    case fledgling
    case adult
    case spirit

    package init(rawStage: String) {
        self = GrowthStage(rawValue: rawStage) ?? .hatchling
    }

    @MainActor
    package var displayName: String {
        switch self {
        case .hatchling: return L.stageHatchling
        case .fledgling: return L.stageFledgling
        case .adult: return L.stageAdult
        case .spirit: return L.stageSpirit
        }
    }

    @MainActor
    package var shortName: String {
        switch self {
        case .hatchling: return L.stageShortHatchling
        case .fledgling: return L.stageShortFledgling
        case .adult: return L.stageShortAdult
        case .spirit: return L.stageShortSpirit
        }
    }

    package var order: Int {
        GrowthStage.allCases.firstIndex(of: self) ?? 0
    }

    package var speechGuidance: String {
        switch self {
        case .hatchling: return L.speechGuidanceHatchling
        case .fledgling: return L.speechGuidanceFledgling
        case .adult: return L.speechGuidanceAdult
        case .spirit: return L.speechGuidanceSpirit
        }
    }

    package var visualScale: CGFloat {
        switch self {
        case .hatchling: return 0.78
        case .fledgling: return 0.90
        case .adult: return 1.0
        case .spirit: return 1.07
        }
    }

    package var budgetMultiplier: Double {
        switch self {
        case .hatchling: return 0.35
        case .fledgling: return 0.70
        case .adult: return 1.0
        case .spirit: return 1.45
        }
    }

    package static func adjustedDailyTokens(base: Int, stage: GrowthStage) -> Int {
        max(1_000, Int(Double(base) * stage.budgetMultiplier))
    }
}
