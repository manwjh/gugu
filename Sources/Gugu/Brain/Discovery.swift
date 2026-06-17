import Foundation

/// 隐藏机制的渐进披露:咕咕在合适的时机,用自己的口吻,一次只透露一个玩法。
///
/// 设计原则(对应"可发现性"短板):
/// - **零成本**:全本地规则,不烧 token。
/// - **不打扰**:每条提示一生只出一次;每次启动至多在恰当时机吐一条;有节奏门控。
/// - **择机**:按"主人还没做过的事"挑提示——你还没摸过我,我才会提"可以摸我"。
/// - **留白**:大部分时候返回 nil(什么都不提),活物感不靠话痨。
struct DiscoveryHint: Equatable {
    let id: String
    let text: String
}

enum Discovery {
    /// 全部提示,按优先级从高到低。第一条"未展示过且条件满足"的会被选中。
    /// 条件:`unlessDid` 计数为 0 时才提示(主人还没体验过这件事)。
    private struct Rule {
        let id: String
        let text: () -> String
        let isRelevant: (ProgressState) -> Bool
    }

    private static let rules: [Rule] = [
        // 最基础的两个直接互动先教(戳、摸)。
        Rule(id: "poke", text: { L.hintPoke }, isRelevant: { $0.pokeCount == 0 }),
        Rule(id: "pet", text: { L.hintPet }, isRelevant: { $0.petCount == 0 && $0.pokeCount > 0 }),
        // 教它学动作——这是新的"共同能动性"钩子,值得显式引导。
        Rule(id: "learn", text: { L.hintLearn },
             isRelevant: { $0.movesLearned == 0 && ($0.pokeCount + $0.petCount) >= 2 }),
        // 聊天入口。
        Rule(id: "chat", text: { L.hintChat },
             isRelevant: { $0.chatCount == 0 && ($0.pokeCount + $0.petCount) >= 3 }),
    ]

    /// 选下一条要展示的提示;没有合适的就返回 nil。
    /// 纯函数,便于测试:只读 state,不写盘。
    static func nextHint(_ state: ProgressState) -> DiscoveryHint? {
        for rule in rules where !state.hasShownHint(rule.id) && rule.isRelevant(state) {
            return DiscoveryHint(id: rule.id, text: rule.text())
        }
        return nil
    }
}
