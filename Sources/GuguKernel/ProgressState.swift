import Foundation

/// 跨会话的"软进度":引导已见标记 + 里程碑高水位 + 一点交互计数。
///
/// 它不是成长状态(那是 PetState/state.json),而是承载"可发现性"和"可见奖励回路"
/// 这两件事所需的最小持久化——符合"一切皆文件"(progress.json,纯文本、可审计、可手改)。
package struct ProgressState: Codable {
    package var schemaVersion: Int = 1

    /// 已经展示过的引导提示 id(每条只出一次)。
    package var hintsShown: [String] = []

    /// 已经庆祝过的里程碑 id(高水位,只增不减)。
    package var milestonesReached: [String] = []

    /// 计数器(本地累计,驱动引导/里程碑判定;与 PetState 互补,不重复真值)。
    package var pokeCount: Int = 0
    package var petCount: Int = 0
    package var throwCount: Int = 0
    package var chatCount: Int = 0
    package var movesLearned: Int = 0

    package init() {}

    package static func load() -> ProgressState {
        if let data = try? Data(contentsOf: Paths.progressState),
           let s = try? JSONDecoder().decode(ProgressState.self, from: data) {
            return s
        }
        return ProgressState()
    }

    package func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Paths.progressState, options: .atomic)
        }
    }

    package func hasShownHint(_ id: String) -> Bool { hintsShown.contains(id) }
    package func hasReachedMilestone(_ id: String) -> Bool { milestonesReached.contains(id) }

    package mutating func markHintShown(_ id: String) {
        guard !hintsShown.contains(id) else { return }
        hintsShown.append(id)
    }

    package mutating func markMilestoneReached(_ id: String) {
        guard !milestonesReached.contains(id) else { return }
        milestonesReached.append(id)
    }
}
