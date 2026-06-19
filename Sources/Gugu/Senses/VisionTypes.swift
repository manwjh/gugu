import Foundation

enum VisionExpression: String {
    case smile, surprised, sleepy

    var eventKind: String { "see_\(rawValue)" }

    var summary: String {
        switch self {
        case .smile: return "你看见主人在笑"
        case .surprised: return "你看见主人好像有点惊讶"
        case .sleepy: return "你看见主人眯着眼睛,像是有点累"
        }
    }
}

enum VisionGesture: String {
    case wave, openPalm, thumbsUp, ok, pointing
    case flyUp   // 手向上一挥:让咕咕飞一个

    var eventKind: String { "gesture_\(rawValue)" }

    var summary: String {
        switch self {
        case .wave: return "你看见主人向你挥手"
        case .openPalm: return "你看见主人把手掌伸给你看"
        case .thumbsUp: return "你看见主人竖起了大拇指"
        case .ok: return "你看见主人比了一个 OK 手势"
        case .pointing: return "你看见主人伸出手指指了指"
        case .flyUp: return "你看见主人把手往上一挥,像是让你飞起来"
        }
    }
}

struct VisionObjectObservation: Hashable {
    let label: String
    let confidence: Float
    let center: CGPoint?
    let area: CGFloat?

    init(label: String, confidence: Float, center: CGPoint? = nil, area: CGFloat? = nil) {
        self.label = label
        self.confidence = confidence
        self.center = center
        self.area = area
    }

    var summary: String {
        "你看见附近有\(VisionObjectObservation.localizedLabel(label))"
    }

    static func localizedLabel(_ label: String) -> String {
        concreteLabel(label) ?? label
    }

    /// 把检测/分类标识符映射成我们关心的"具体物品"中文名;不认得返回 nil。
    /// 模糊包含匹配,兼容 COCO 名(如 "cell phone" 带空格)与同义变体。
    static func concreteLabel(_ identifier: String) -> String? {
        let id = identifier.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { id.contains($0) } }
        if has("cat") { return "猫" }
        if has("dog", "puppy") { return "狗" }
        if has("bird") { return "鸟" }
        if has("phone") { return "手机" }                 // cell phone / telephone / smartphone
        if has("laptop", "notebook computer") { return "笔记本电脑" }
        if has("keyboard") { return "键盘" }
        if has("remote") { return "遥控器" }
        if id == "tv" || has("television", "monitor") { return "屏幕" }
        if id.contains("mouse") && !id.contains("mousepad") { return "鼠标" }
        if has("wine glass") { return "酒杯" }
        if has("cup", "mug", "coffee") { return "杯子" }
        if has("bottle", "flask", "thermos") { return "瓶子" }
        if has("bowl") { return "碗" }
        if has("fork", "knife", "spoon") { return "餐具" }
        if has("book") { return "书" }
        if has("scissors") { return "剪刀" }
        if has("toothbrush") { return "牙刷" }
        if has("clock", "watch") { return "钟表" }
        if has("vase") { return "花瓶" }
        if has("houseplant", "potted plant", "flower", "plant") { return "植物" }
        if has("spectacle", "eyeglass", "sunglass", "eyewear") || id == "glasses" { return "眼镜" }
        if has("headphone", "earphone", "headset") { return "耳机" }
        if has("teddy", "plush", "stuffed") { return "玩偶" }
        if has("banana") { return "香蕉" }
        if has("orange") && !has("orangutan") { return "橙子" }
        if id.contains("apple") && !id.contains("pineapple") { return "苹果" }
        if has("hat", "beanie") { return "帽子" }
        return nil
    }
}

enum VideoUnderstandingEvent: String {
    case personApproached, personMovedAway, personMovedLeft, personMovedRight
    case handReachedTowardCamera
    case objectAppeared, objectDisappeared, objectMoved

    var eventKind: String { "video_\(rawValue)" }

    func summary(label: String? = nil) -> String {
        switch self {
        case .personApproached: return "你看见主人好像靠近了一点"
        case .personMovedAway: return "你看见主人好像离远了一点"
        case .personMovedLeft: return "你看见主人往左边动了动"
        case .personMovedRight: return "你看见主人往右边动了动"
        case .handReachedTowardCamera: return "你看见主人的手靠近了你"
        case .objectAppeared: return "你看见\(label ?? "一个东西")出现在附近"
        case .objectDisappeared: return "你看见\(label ?? "一个东西")不见了"
        case .objectMoved: return "你看见\(label ?? "一个东西")被挪动了"
        }
    }
}

/// 用户主动开启摄像头时的真实结果(用于给出正确反馈,而非假装成功)。
enum VisionStartOutcome {
    case started     // 已授权且会话起来了
    case denied      // 系统权限被拒/受限
    case noDevice    // 找不到摄像头
    case failed      // 会话配置失败
}

/// 每帧的视觉快照——视觉感知的**唯一连续真相源**。
/// 既喂感知上下文(Perception 的视觉字段全部出自这里,语义已平滑),
/// 也喂调试窗口(下半部分的原始数值/外框,用于调阈值)。
struct VisionFrame {
    // —— 语义层(已平滑,给 Perception 连续读)——
    var ownerPresent = false              // 经迟滞平滑的"主人在不在"
    var expression: String?               // 当前表情(连续 3 帧确认;无=中性)
    var gesture: String?                  // 当前保持的手型(2 帧确认;无=没摆手型)
    var handX: CGFloat?                    // 手水平位置 0=左 1=右(主人视角,已镜像)
    var objectsNow: [String] = []         // 当前稳定在场的具体物品(中文名;已去抖,非每帧原始)

    // —— 调试层(原始数值,给调试窗口调阈值)——
    var facePresent = false               // 本帧原始是否检到脸(画外框用)
    var mouthWH: CGFloat = 0
    var cornerUpturn: CGFloat = 0
    var eyeL: CGFloat = 0
    var eyeR: CGFloat = 0
    var expressions: [String] = []        // 本帧检测到(去抖前)
    var rawGesture: String = "—"          // 本帧原始手型
    var fingers: [Bool] = []              // 食/中/无名/小
    var palmSamples = 0                   // 手轨迹缓冲帧数
    var objects: [(label: String, conf: Float)] = []
    var lowPower = false
    var modelLoaded = false
    // 可视化用:归一化外框(Vision 坐标,原点左下)
    var faceBox: CGRect?
    var handBox: CGRect?
    var objectBoxes: [(label: String, conf: Float, rect: CGRect)] = []
}
