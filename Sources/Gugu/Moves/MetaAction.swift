import Foundation
import GuguKernel

/// 元动作(meta-action):动作进化的安全沙盒。
///
/// 咕咕"学会"一个新动作 = 一段**数据化编排**,而不是新代码(公理 A1/B3)。
/// 每个编排步骤只能调用下面这张**白名单**里的身体基元;参数全部被夹到安全区间。
/// 因为表达力被结构性地限制在"重组已有部件"上,模型再怎么写也越不出身体能力的边界,
/// 也无法借此做任何越权或危险的事——它只能让小鸟动起来。
///
/// 本文件是纯逻辑,**不依赖 SpriteKit**,可被离线自测覆盖。真正把步骤翻成动画的解释器
/// 见 `MoveInterpreter`(那一层才碰身体)。
enum MetaOp: String, Codable, CaseIterable {
    case move      // 平移身体:dx/dy(点),dur(秒)
    case rotate    // 旋转身体:by(弧度),dur
    case scale     // 形变(挤压拉伸):x/y(相对基准的比例),dur
    case flap      // 扑翅:times(次),fast(快/慢)
    case hop       // 蹦一下:height(点),dur(单程)
    case wait      // 停顿:dur
    case say       // 说一句短话:text
    case view      // 切换朝向:dir = front/back/side
    case tilt      // 歪头:on
    case blush     // 脸红:on
    case peck      // 啄一下(无参手势)
    case groom     // 理毛(无参手势)
    case manpu     // 冒一个情绪符号(瞬时触发):kind = sweat/anger/surprise/love/music/question/dizzy
}

/// 编排里的单步。字段全部可选,按 op 取用对应字段;未用到的忽略。
struct MoveStep: Codable, Equatable {
    var op: String
    var dx: Double?
    var dy: Double?
    var by: Double?
    var x: Double?
    var y: Double?
    var dur: Double?
    var times: Int?
    var fast: Bool?
    var height: Double?
    var text: String?
    var dir: String?
    var on: Bool?
    var kind: String?   // manpu:情绪符号种类
}

/// 校验/夹紧用的安全边界。改这里就能调节"进化空间"的大小。
enum MoveLimits {
    static let maxSteps = 12
    static let maxStepDuration = 2.0      // 单步最长 2s
    static let maxTotalDuration = 8.0     // 整段最长 8s(防止动作霸屏)
    static let maxTranslate = 120.0       // 平移幅度上限(点)
    static let maxRotate = 4 * Double.pi  // 最多转两整圈
    static let minScale = 0.3
    static let maxScale = 2.0
    static let maxFlap = 30
    static let maxHop = 80.0
    static let maxSayChars = 24
    static let maxNameChars = 24
    static let maxTriggerChars = 40
    static let validDirs: Set<String> = ["front", "back", "side"]
    /// manpu kind 白名单。必须镜像 `Manpu` 的 rawValue(本文件保持纯逻辑,不引用 SpriteKit 侧的枚举)。
    static let validManpu: Set<String> = ["sweat", "anger", "surprise", "love", "music", "question", "dizzy"]
}

enum MoveValidationError: Error, CustomStringConvertible, Equatable {
    case empty
    case tooManySteps(Int)
    case unknownOp(String)
    case totalDurationExceeded(Double)
    case sayTooLong(Int)
    case invalidDirection(String)
    case invalidManpu(String)
    case nameInvalid
    case triggerTooLong(Int)

    var description: String {
        switch self {
        case .empty: return "动作编排为空"
        case .tooManySteps(let n): return "步骤过多(\(n) > \(MoveLimits.maxSteps))"
        case .unknownOp(let s): return "未知基元: \(s)"
        case .totalDurationExceeded(let d): return "总时长过长(\(String(format: "%.1f", d))s > \(MoveLimits.maxTotalDuration)s)"
        case .sayTooLong(let n): return "台词过长(\(n) > \(MoveLimits.maxSayChars))"
        case .invalidDirection(let s): return "无效朝向: \(s)"
        case .invalidManpu(let s): return "无效情绪符号: \(s)"
        case .nameInvalid: return "动作名非法(空或含路径分隔符)"
        case .triggerTooLong(let n): return "触发词过长(\(n) > \(MoveLimits.maxTriggerChars))"
        }
    }
}

enum MetaActionValidator {
    /// 夹紧单步到安全区间(数值越界不报错,直接 clamp;只有结构性问题才在 list 层报错)。
    static func clamp(_ step: MoveStep) -> MoveStep {
        var s = step
        if let v = s.dur { s.dur = min(max(0, v), MoveLimits.maxStepDuration) }
        if let v = s.dx { s.dx = clampMag(v, MoveLimits.maxTranslate) }
        if let v = s.dy { s.dy = clampMag(v, MoveLimits.maxTranslate) }
        if let v = s.by { s.by = clampMag(v, MoveLimits.maxRotate) }
        if let v = s.x { s.x = min(max(MoveLimits.minScale, v), MoveLimits.maxScale) }
        if let v = s.y { s.y = min(max(MoveLimits.minScale, v), MoveLimits.maxScale) }
        if let v = s.height { s.height = min(max(0, v), MoveLimits.maxHop) }
        if let v = s.times { s.times = min(max(1, v), MoveLimits.maxFlap) }
        return s
    }

    private static func clampMag(_ v: Double, _ limit: Double) -> Double {
        min(max(-limit, v), limit)
    }

    /// 估算一段编排的总时长(用于霸屏防护)。
    static func totalDuration(_ steps: [MoveStep]) -> Double {
        steps.reduce(0) { acc, s in
            let op = MetaOp(rawValue: s.op)
            switch op {
            case .hop:
                // 蹦:上+下两程
                return acc + 2 * min(max(0, s.dur ?? 0.16), MoveLimits.maxStepDuration)
            case .peck, .groom, .say, .view, .tilt, .blush, .flap, .manpu, .none:
                // 这些基元有自己的内部时长,这里给一个保守估计
                return acc + max(s.dur ?? defaultDuration(for: op), 0)
            default:
                return acc + min(max(0, s.dur ?? 0), MoveLimits.maxStepDuration)
            }
        }
    }

    private static func defaultDuration(for op: MetaOp?) -> Double {
        switch op {
        case .peck: return 0.25
        case .groom: return 1.4
        case .flap: return 0.5
        case .view, .tilt, .blush: return 0.2
        default: return 0
        }
    }

    /// 校验并夹紧整段编排;通过则返回 clamp 后的步骤,否则抛出结构性错误。
    @discardableResult
    static func validate(steps rawSteps: [MoveStep]) throws -> [MoveStep] {
        guard !rawSteps.isEmpty else { throw MoveValidationError.empty }
        guard rawSteps.count <= MoveLimits.maxSteps else {
            throw MoveValidationError.tooManySteps(rawSteps.count)
        }
        var clamped: [MoveStep] = []
        for raw in rawSteps {
            guard let op = MetaOp(rawValue: raw.op) else {
                throw MoveValidationError.unknownOp(raw.op)
            }
            if op == .say, let t = raw.text, t.count > MoveLimits.maxSayChars {
                throw MoveValidationError.sayTooLong(t.count)
            }
            if op == .view {
                let dir = raw.dir ?? ""
                guard MoveLimits.validDirs.contains(dir) else {
                    throw MoveValidationError.invalidDirection(dir)
                }
            }
            if op == .manpu {
                let kind = raw.kind ?? ""
                guard MoveLimits.validManpu.contains(kind) else {
                    throw MoveValidationError.invalidManpu(kind)
                }
            }
            clamped.append(clamp(raw))
        }
        let total = totalDuration(clamped)
        guard total <= MoveLimits.maxTotalDuration else {
            throw MoveValidationError.totalDurationExceeded(total)
        }
        return clamped
    }

    /// 动作名既是展示名也是文件名,必须可安全落盘。
    static func sanitizedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed != ".",
              trimmed != ".." else {
            throw MoveValidationError.nameInvalid
        }
        return String(trimmed.prefix(MoveLimits.maxNameChars))
    }
}
