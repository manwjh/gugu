import AppKit

/// 统一的"此刻在发生什么"快照——把六路感知收口到一处,消除碎片化:
/// 视觉 / 语音 / 文字输入 / 鼠标 / 二维世界(咕咕自身) / 电脑本体。
///
/// 与 EventBus 互补:EventBus 是**事件流**(发生过什么、给做梦蒸馏);
/// Perception 是**当前状态快照**(此刻什么为真、给反射和心跳做连贯推理)。
///
/// 事件型字段由各感官回调推送(看到笑/听到话/物品出现…),
/// 环境型字段由 GuguApp 周期 tick 刷新(前台 App/节奏/鼠标/咕咕位置/时段/电量)。
/// 瞬时字段带时间戳,过期自动视为"无"。
@MainActor
final class Perception {
    static let shared = Perception()

    // MARK: 视觉
    private(set) var ownerVisible = false
    private var faceExpr: (v: String, t: Date)?       // 笑/惊讶/困
    private var gesture: (v: String, t: Date)?
    private var objects: [String: Date] = [:]         // 物品中文名 -> 最近看见时间
    /// 手的水平位置(0=左 1=右,**主人视角**,已镜像);供"跟随手"等共享坐标交互用。
    private(set) var handX: CGFloat?
    private var handSeen = Date.distantPast

    // MARK: 语音 / 文字
    private(set) var listening = false
    private(set) var speaking = false
    private(set) var chatOpen = false
    private var lastUserText: (v: String, via: String, t: Date)?   // 最近一句(语音/打字)

    // MARK: 鼠标 / 二维世界 / 电脑本体(tick 刷新)
    private(set) var mouseNearGugu = false
    private(set) var guguState = "idle"
    private(set) var guguInRoom = false
    private(set) var frontApp = ""
    private(set) var rhythm = ""
    private(set) var lowPower = false
    private(set) var energy = 0.7
    private(set) var valence = 0.0

    // MARK: - 感官推送(事件型)

    func setOwnerVisible(_ v: Bool) { ownerVisible = v }
    func sawExpression(_ e: String) { faceExpr = (e, Date()) }
    func sawGesture(_ g: String) { gesture = (g, Date()) }
    func sawObject(_ label: String) { objects[label] = Date() }
    func sawHand(x: CGFloat?) { handX = x; handSeen = Date() }
    func heardOrTyped(_ text: String, via: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lastUserText = (String(t.prefix(40)), via, Date())
    }
    func setListening(_ b: Bool) { listening = b }
    func setSpeaking(_ b: Bool) { speaking = b }
    func setChatOpen(_ b: Bool) { chatOpen = b }

    // MARK: - 环境刷新(GuguApp 周期调用)

    func tickAmbient(mouseNearGugu: Bool, guguState: String, guguInRoom: Bool,
                     frontApp: String, rhythm: String, lowPower: Bool,
                     energy: Double, valence: Double) {
        self.mouseNearGugu = mouseNearGugu
        self.guguState = guguState
        self.guguInRoom = guguInRoom
        self.frontApp = frontApp
        self.rhythm = rhythm
        self.lowPower = lowPower
        self.energy = energy
        self.valence = valence
    }

    // MARK: - 派生

    /// 当前手势(若新鲜)。供"指挥/跟随"等实时交互直接读,免走事件流。
    func freshGesture(within: TimeInterval = 1.0) -> String? {
        guard let g = gesture, Date().timeIntervalSince(g.t) < within else { return nil }
        return g.v
    }

    var handFresh: Bool { Date().timeIntervalSince(handSeen) < 0.6 }

    private static func timeOfDay(_ now: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<11: return "早上"
        case 11..<14: return "中午"
        case 14..<18: return "下午"
        case 18..<23: return "晚上"
        default: return "深夜"
        }
    }

    /// 给脑子(心跳)的一段连贯"此刻"描述——一致快照,而非散落的事件行。
    func summaryForBrain(now: Date = Date()) -> String {
        var bits: [String] = []
        bits.append(Perception.timeOfDay(now))
        if !frontApp.isEmpty { bits.append("前台 \(frontApp)") }
        if !rhythm.isEmpty { bits.append(rhythm) }

        // 视觉(摄像头开时才有)
        if ownerVisible {
            var see = "看得见主人"
            if let e = faceExpr, now.timeIntervalSince(e.t) < 8 {
                see += "(\(["smile": "在笑", "surprised": "有点惊讶", "sleepy": "有点困"][e.v] ?? e.v))"
            }
            bits.append(see)
        }
        let nearby = objects.filter { now.timeIntervalSince($0.value) < 12 }.keys.sorted()
        if !nearby.isEmpty { bits.append("附近有\(nearby.joined(separator: "、"))") }
        if let g = gesture, now.timeIntervalSince(g.t) < 4 { bits.append("刚比了个手势") }

        // 语音/文字
        if let u = lastUserText, now.timeIntervalSince(u.t) < 30 {
            bits.append("主人刚\(u.via)说「\(u.v)」")
        }
        if listening { bits.append("正在听") }

        // 鼠标 / 世界
        if mouseNearGugu { bits.append("鼠标在你附近") }
        if guguInRoom { bits.append("你在小窝里") }
        if lowPower { bits.append("电脑省电模式") }

        return "此刻:" + bits.joined(separator: "；") + "。"
    }
}
