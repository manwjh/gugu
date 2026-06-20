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
package final class Perception {
    package static let shared = Perception()

    // MARK: 视觉(全部出自 VisionSensor 每帧连续快照 VisionFrame,语义已平滑)
    private var _ownerVisible = false
    private var lastVisionFrame = Date.distantPast
    private var faceExpr: (v: String, t: Date)?       // 笑/惊讶/困(中性时清空)
    private var objects: [String: Date] = [:]         // 物品中文名 -> 最近看见时间
    /// 手的水平位置(0=左 1=右,**主人视角**,已镜像);供"跟随手"等共享坐标交互用。
    package private(set) var handX: CGFloat?
    private var handSeen = Date.distantPast
    /// 摄像头关闭/无帧时视觉即视为"无"——避免拿陈旧的"看得见主人"骗脑子。
    private var visionFresh: Bool { Date().timeIntervalSince(lastVisionFrame) < 1.5 }
    package var ownerVisible: Bool { _ownerVisible && visionFresh }

    // MARK: 语音 / 文字
    package private(set) var listening = false
    package private(set) var speaking = false
    package private(set) var chatOpen = false
    private var lastUserText: (v: String, via: String, t: Date)?   // 最近一句(语音/打字)

    // MARK: 鼠标 / 二维世界 / 电脑本体(tick 刷新)
    package private(set) var mouseNearGugu = false
    package private(set) var guguState = "idle"
    package private(set) var guguInRoom = false
    package private(set) var frontApp = ""
    package private(set) var rhythm = ""
    package private(set) var lowPower = false
    package private(set) var energy = 0.7
    package private(set) var valence = 0.0

    // MARK: - 感官推送

    /// 视觉:每帧一次的连续快照(VisionSensor.onFrame)。视觉字段的**唯一入口**——
    /// 不再由零散的去抖事件回调喂养,保证"此刻看见什么"前后一致、随相机开关进退。
    package func updateVision(present: Bool, expression: String?,
                      handX: CGFloat?, objectsNow: [String]) {
        let now = Date()
        lastVisionFrame = now
        _ownerVisible = present
        faceExpr = expression.map { ($0, now) }            // nil=中性,立即清空,不留陈旧情绪
        self.handX = handX
        if handX != nil { handSeen = now }
        for o in objectsNow { objects[o] = now }            // 稳定在场集刷新;移走后靠时间衰减
    }

    package func heardOrTyped(_ text: String, via: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lastUserText = (String(t.prefix(40)), via, Date())
    }
    package func setListening(_ b: Bool) { listening = b }
    package func setSpeaking(_ b: Bool) { speaking = b }
    package func setChatOpen(_ b: Bool) { chatOpen = b }

    // MARK: - 环境刷新(GuguApp 周期调用)

    package func tickAmbient(mouseNearGugu: Bool, guguState: String, guguInRoom: Bool,
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

    /// 是否最近看到手(用于"跟随手":手在画面里且新鲜)。
    package var handFresh: Bool { Date().timeIntervalSince(handSeen) < 0.6 }

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
    package func summaryForBrain(now: Date = Date()) -> String {
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
