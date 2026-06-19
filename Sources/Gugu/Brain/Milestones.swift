import Foundation
import GuguKernel

/// 看得见的成长奖励:在长长的形态进化之间,填上一连串小里程碑,
/// 让"熬到了"立刻有东西看(对应"成长/奖励回路"短板)。
///
/// 里程碑是本地纯规则:跨过某个阈值就庆祝一次(气泡 + 小动画),用高水位保证只庆祝一次。
struct Milestone: Equatable {
    let id: String
    let words: String      // 它说出口的话
    let move: String?      // 可选:庆祝时演的一个动作(命中 MoveLibrary 才会演)
}

enum Milestones {
    /// 一次互动/成长事件后调用:返回这次**新跨越**的里程碑(通常 0 或 1 个)。
    /// 纯函数:根据 progress + petState 计算应达成集合,减去已庆祝的高水位。
    static func newlyReached(progress: ProgressState, state: PetState) -> [Milestone] {
        var reached: [Milestone] = []

        func add(_ id: String, _ words: String, move: String? = nil, when condition: Bool) {
            guard condition, !progress.hasReachedMilestone(id) else { return }
            reached.append(Milestone(id: id, words: words, move: move))
        }

        let interactions = progress.pokeCount + progress.petCount + progress.chatCount

        // 互动总数里程碑
        add("interact_10", L.milestoneInteract10, when: interactions >= 10)
        add("interact_50", L.milestoneInteract50, move: "转圈圈", when: interactions >= 50)

        // 羁绊里程碑(bond 是 PetState 单一真值)
        add("bond_30", L.milestoneBond30, when: state.bond >= 0.3)
        add("bond_50", L.milestoneBond50, move: "鞠躬", when: state.bond >= 0.5)
        add("bond_80", L.milestoneBond80, move: "转圈圈", when: state.bond >= 0.8)

        // 相处天数里程碑
        add("days_3", L.milestoneDays3, when: state.days_together >= 3)
        add("days_7", L.milestoneDays7, move: "鞠躬", when: state.days_together >= 7)
        add("days_30", L.milestoneDays30, move: "翻跟头", when: state.days_together >= 30)

        // 学会动作的里程碑(动作进化产物)
        add("move_1", L.milestoneMove1, when: progress.movesLearned >= 1)
        add("move_3", L.milestoneMove3, move: "翻跟头", when: progress.movesLearned >= 3)

        return reached
    }
}
