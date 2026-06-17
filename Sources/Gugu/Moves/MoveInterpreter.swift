import SpriteKit

/// 把一段元动作编排(`[MoveStep]`)翻译成跑在 `BirdNode` 上的 `SKAction`。
///
/// 这是动作进化的"执行层":数据 → 动画。它只会调用 `BirdNode` 已有的安全基元,
/// 步骤在进库前已被 `MetaActionValidator` 夹紧,所以这里可以信任参数区间。
/// `say` 基元通过注入的闭包回到 `PetController.say`,从而走气泡 + 可选朗读。
@MainActor
enum MoveInterpreter {
    /// 编译整段为一个串行 SKAction。`say` 用注入闭包播报。
    static func compile(_ steps: [MoveStep], on bird: BirdNode, say: @escaping (String) -> Void) -> SKAction {
        let actions = steps.map { compileStep($0, on: bird, say: say) }
        return .sequence(actions)
    }

    private static func compileStep(_ step: MoveStep, on bird: BirdNode, say: @escaping (String) -> Void) -> SKAction {
        let op = MetaOp(rawValue: step.op)
        switch op {
        case .move:
            let dx = CGFloat(step.dx ?? 0)
            let dy = CGFloat(step.dy ?? 0)
            return .moveBy(x: dx, y: dy, duration: step.dur ?? 0.3)

        case .rotate:
            return .rotate(byAngle: CGFloat(step.by ?? 0), duration: step.dur ?? 0.3)

        case .scale:
            let dur = step.dur ?? 0.2
            var group: [SKAction] = []
            if let x = step.x { group.append(.scaleX(to: CGFloat(x), duration: dur)) }
            if let y = step.y { group.append(.scaleY(to: CGFloat(y), duration: dur)) }
            return group.isEmpty ? .wait(forDuration: dur) : .group(group)

        case .flap:
            let times = step.times ?? 3
            let fast = step.fast ?? false
            return .run { bird.flapWings(times: times, fast: fast) }

        case .hop:
            let h = CGFloat(step.height ?? 18)
            let dur = step.dur ?? 0.16
            return .sequence([
                .moveBy(x: 0, y: h, duration: dur),
                .moveBy(x: 0, y: -h, duration: max(0.05, dur - 0.02)),
            ])

        case .wait:
            return .wait(forDuration: step.dur ?? 0.3)

        case .say:
            let text = step.text ?? ""
            return .run { if !text.isEmpty { say(text) } }

        case .view:
            let dir: BirdViewDirection
            switch step.dir {
            case "back": dir = .back
            case "side": dir = .side
            default: dir = .front
            }
            return .run { bird.setViewDirection(dir) }

        case .tilt:
            let on = step.on ?? true
            return .run { bird.tiltHead(on) }

        case .blush:
            let on = step.on ?? true
            return .run { bird.showBlush(on) }

        case .peck:
            return .run { bird.peckOnce() }

        case .groom:
            return .run { bird.groomOnce() }

        case .none:
            // 未知 op 在校验阶段已被挡掉;运行期兜底为无操作。
            return .wait(forDuration: 0)
        }
    }
}
