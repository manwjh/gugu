import SpriteKit

/// 把一段元动作编排(`[MoveStep]`)翻译成跑在 `BirdNode` 上的 `SKAction`。
///
/// 这是动作进化的"执行层":数据 → 动画。它只会调用 `BirdNode` 已有的安全基元,
/// 步骤在进库前已被 `MetaActionValidator` 夹紧,所以这里可以信任参数区间。
/// `say` 基元通过注入的闭包回到 `PetController.say`,从而走气泡 + 可选朗读。
///
/// 运动类基元(move/rotate/hop/scale)在这里补上了动画三件套——**缓动 + 挤压拉伸 + 次级运动**,
/// 让小鸟"走"起来有起伏落脚、"转"起来有蓄力回弹,而不是贴图在飘/纸片在旋。
/// 所有装饰都是瞬态、净变换量与朴素实现一致,跑完由 `PetController.performLearnedMove` 收尾清回 idle。
@MainActor
enum MoveInterpreter {
    /// 编译整段为一个串行 SKAction。`say` 用注入闭包播报;`face` 在水平走动时回写朝向(默认 no-op)。
    static func compile(_ steps: [MoveStep],
                        on bird: BirdNode,
                        say: @escaping (String) -> Void,
                        face: @escaping (Bool) -> Void = { _ in }) -> SKAction {
        let actions = steps.map { compileStep($0, on: bird, say: say, face: face) }
        return .sequence(actions)
    }

    private static func compileStep(_ step: MoveStep,
                                    on bird: BirdNode,
                                    say: @escaping (String) -> Void,
                                    face: @escaping (Bool) -> Void) -> SKAction {
        let op = MetaOp(rawValue: step.op)
        switch op {
        case .move:
            // 走路:身体匀速前移(踏地脚才能精确"咬住地面"),脚步与朝向交给 walkCadence。
            // 身体本身不做竖直颠簸——那会读成蹦跳,也会让踏地的脚看着在浮。
            let dx = CGFloat(step.dx ?? 0)
            let dy = CGFloat(step.dy ?? 0)
            let dur = step.dur ?? 0.3
            let walk = SKAction.group([
                .moveBy(x: dx, y: dy, duration: dur),   // linear:身体匀速前移,踏地脚反向滑动才抵得准
                .run { bird.walkCadence(over: dur, parentDx: dx) },
            ])
            let bigHorizontal = abs(dx) > 14 && abs(dx) >= abs(dy)
            guard bigHorizontal else { return walk }
            let turn = SKAction.run {
                bird.setViewDirection(.side)
                bird.faceWalking(right: dx > 0)
                face(dx > 0)
            }
            return .sequence([turn, walk])

        case .rotate:
            // 转身:反向蓄力 → 主转带越冲 + 身体被甩扁 → 回弹归位(治"纸片旋转")。净旋转 = by。
            let by = CGFloat(step.by ?? 0)
            let dur = step.dur ?? 0.3
            guard abs(by) > 0.001 else { return .wait(forDuration: dur) }
            let ant = smallShare(0.08, of: by)   // 预备幅度,随 |by| 缩放,符号同 by
            let over = smallShare(0.12, of: by)  // 越冲幅度
            let prep = eased(.rotate(byAngle: -ant, duration: dur * 0.18), .easeOut)
            let main = eased(.rotate(byAngle: by + ant + over, duration: dur * 0.64), .easeInEaseOut)
            let settle = eased(.rotate(byAngle: -over, duration: dur * 0.18), .easeOut)
            let spin = SKAction.group([main, squashPulse(dur * 0.64)])
            return .sequence([prep, spin, settle])

        case .scale:
            // 形变:加缓动 + 轻微过冲回弹,让到位有弹性而非生硬。净缩放 = 目标 x/y。
            let dur = step.dur ?? 0.2
            var group: [SKAction] = []
            if let x = step.x { group.append(bouncyScaleX(to: CGFloat(x), dur: dur)) }
            if let y = step.y { group.append(bouncyScaleY(to: CGFloat(y), dur: dur)) }
            return group.isEmpty ? .wait(forDuration: dur) : .group(group)

        case .flap:
            let times = step.times ?? 3
            let fast = step.fast ?? false
            return .run { bird.flapWings(times: times, fast: fast) }

        case .hop:
            // 教科书挤压拉伸跳:下蹲蓄力 → 升空拉长(减速到顶)→ 下落收回(加速)→ 落地缓冲回弹。
            // 净垂直 0、净缩放 1(末段过冲值按前三段乘积反算)。
            let h = CGFloat(step.height ?? 18)
            let dur = step.dur ?? 0.16
            let down = max(0.05, dur - 0.02)
            let crouch = eased(.scaleX(by: 1.10, y: 0.82, duration: 0.09), .easeOut)
            let launch = SKAction.group([
                eased(.moveBy(x: 0, y: h, duration: dur), .easeOut),
                eased(.scaleX(by: 0.88, y: 1.28, duration: dur), .easeOut),
            ])
            let drop = SKAction.group([
                eased(.moveBy(x: 0, y: -h, duration: down), .easeIn),
                eased(.scaleX(by: 1.12, y: 0.86, duration: down), .easeIn),
            ])
            let settle = eased(.scaleX(by: 1 / (1.10 * 0.88 * 1.12),
                                       y: 1 / (0.82 * 1.28 * 0.86),
                                       duration: 0.10), .easeOut)
            return .sequence([crouch, launch, drop, settle])

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

    // MARK: - 动画小工具

    /// 给一个 leaf SKAction 设缓动(`.sequence`/`.group` 自身的 timingMode 会被忽略,只对叶子有效)。
    private static func eased(_ a: SKAction, _ mode: SKActionTimingMode) -> SKAction {
        a.timingMode = mode
        return a
    }

    /// 转身时身体被甩扁再回弹(相对缩放,去程×回程 = 1,净缩放不变)。
    private static func squashPulse(_ dur: TimeInterval) -> SKAction {
        let half = max(0.05, dur / 2)
        let squeeze = eased(.scaleX(by: 0.92, y: 1.06, duration: half), .easeOut)
        let release = eased(.scaleX(by: 1 / 0.92, y: 1 / 1.06, duration: half), .easeIn)
        return .sequence([squeeze, release])
    }

    /// 取 `base` 与 `|by|·0.5` 的较小者作幅度,符号同 `by`——让很小的旋转不至于配上夸张的蓄力。
    private static func smallShare(_ base: CGFloat, of by: CGFloat) -> CGFloat {
        let mag = min(base, abs(by) * 0.5)
        return by >= 0 ? mag : -mag
    }

    /// 带过冲的缩放到位:先冲过目标一点点,再缓回目标。
    private static func bouncyScaleX(to target: CGFloat, dur: TimeInterval) -> SKAction {
        let overshoot = target + (target >= 1 ? 0.06 : -0.06)
        return .sequence([
            eased(.scaleX(to: overshoot, duration: dur * 0.7), .easeOut),
            eased(.scaleX(to: target, duration: dur * 0.3), .easeInEaseOut),
        ])
    }

    private static func bouncyScaleY(to target: CGFloat, dur: TimeInterval) -> SKAction {
        let overshoot = target + (target >= 1 ? 0.06 : -0.06)
        return .sequence([
            eased(.scaleY(to: overshoot, duration: dur * 0.7), .easeOut),
            eased(.scaleY(to: target, duration: dur * 0.3), .easeInEaseOut),
        ])
    }
}
