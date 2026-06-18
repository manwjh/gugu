import Foundation

/// idle 时的"自娱自乐"行为选择——抽成纯逻辑,便于测试,也便于按心情调制。
///
/// 对应"行为多样性/意外感"短板:原来 idle 池子小且与心情无关。现在:
/// - 池子更大(伸懒腰、东张西望、打量光标、理毛、啄、扑翅、蹦、偶尔演一个学会的动作)
/// - 受 affect 调制:精力低 → 更可能发呆/蹲着;精力高、心情好 → 更可能蹦跳/演动作
/// - 有学会的动作时,低概率"自己玩一下"刚学会的本事(让进化成果自然冒出来)
enum IdleBehavior: Equatable {
    case wander         // 小幅走动
    case groom          // 理毛
    case peck           // 啄
    case tiltHead       // 歪头
    case glanceCursor   // 瞟一眼光标
    case flap           // 扑两下翅膀
    case stretch        // 伸懒腰(新)
    case lookAround     // 东张西望(新)
    case hop            // 原地蹦一下(新)
    case hum            // 心情好时自己哼两句,飘个音符(新)
    case playMove(String) // 自己演一个学会/内置的动作(新)
    case standStill     // 就站着,当一只鸟
}

enum IdleSelector {
    /// 选一个 idle 行为。纯函数:给定一次掷骰 [0,1)、心情标量、可选的动作名,返回行为。
    ///
    /// - roll: 外部传入的随机数(测试可注入,生产用 Double.random)。
    /// - energy/valence: 来自 Affect 的当下心情(0…1 / -1…1)。
    /// - availableMove: 当前可"自己玩"的一个动作名(nil 表示没有可玩的)。
    static func choose(roll: Double, energy: Double, valence: Double, availableMove: String?) -> IdleBehavior {
        // 精力很低:大概率发呆/小动作,不蹦不跳。
        if energy < 0.3 {
            switch roll {
            case ..<0.35: return .standStill
            case ..<0.55: return .groom
            case ..<0.70: return .tiltHead
            case ..<0.85: return .peck
            default:      return .stretch
            }
        }

        // 精力高且心情好:更活泼,且更可能自己玩一个动作。
        let lively = energy > 0.6 && valence > 0.2
        if lively, let move = availableMove, roll < 0.14 {
            return .playMove(move)
        }
        // 心情很好时,偶尔自己哼两句(roll 0.14–0.20,不与上面的 playMove 判定区间重叠)。
        if lively && valence > 0.4 && roll >= 0.14 && roll < 0.20 {
            return .hum
        }

        switch roll {
        case ..<0.24: return .wander
        case ..<0.38: return .groom
        case ..<0.48: return .peck
        case ..<0.56: return .tiltHead
        case ..<0.64: return .glanceCursor
        case ..<0.72: return .lookAround
        case ..<0.80: return .flap
        case ..<0.87: return lively ? .hop : .stretch
        case ..<0.93: return .stretch
        default:      return .standStill
        }
    }
}
