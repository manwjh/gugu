import Foundation

/// 连击戳的递进反应——纯逻辑,便于测试。
///
/// 对应"物理触感花样到顶快"的短板:同样是戳,连着快戳和偶尔戳一下,反应应该不一样。
/// 在一个滑动时间窗内累计连击数,映射到递进的反应等级(从"嗯?"到头晕、躲开)。
enum PokeReaction: Equatable {
    case mild       // 1–2 下:轻轻一跳
    case annoyed    // 3–4 下:有点烦,扭头
    case dizzy      // 5–7 下:被戳晕了,转圈/摇晃
    case flee       // ≥8 下:受不了,躲开

    var speech: String? {
        switch self {
        case .mild:    return nil
        case .annoyed: return L.pokeAnnoyed
        case .dizzy:   return L.pokeDizzy
        case .flee:    return L.pokeFlee
        }
    }
}

/// 连击计数器:在 `window` 秒内的连续戳算作一串连击。
struct PokeCombo {
    /// 连击有效时间窗(秒)。两次戳间隔超过它,连击清零重来。
    var window: TimeInterval = 1.6
    private(set) var count: Int = 0
    private var lastPokeAt: Date = .distantPast

    init(window: TimeInterval = 1.6) {
        self.window = window
    }

    /// 记录一次戳,返回当前连击数。`now` 可注入便于测试。
    mutating func registerPoke(now: Date = Date()) -> Int {
        if now.timeIntervalSince(lastPokeAt) <= window {
            count += 1
        } else {
            count = 1
        }
        lastPokeAt = now
        return count
    }

    /// 把连击数映射到反应等级。
    static func reaction(for count: Int) -> PokeReaction {
        switch count {
        case ..<3:  return .mild
        case 3...4: return .annoyed
        case 5...7: return .dizzy
        default:    return .flee
        }
    }
}
