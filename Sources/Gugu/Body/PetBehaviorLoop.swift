import AppKit
import GuguKernel

/// 咕咕"自娱自乐"的调度器与选择器(L0 行为环):拥有计时器、4–10s 的节律,
/// 以及"此刻做哪个 idle 小动作"的概率决策树。
///
/// **职责边界**:只决策与调度。具体执行委托给 PetController 暴露的 idle 动词
/// (身体怎么做、动什么节点、改什么物理状态,由身体自己说了算)——
/// 决策(这里)与执行(PetController)彻底分开。
@MainActor
final class PetBehaviorLoop {
    private unowned let body: PetController
    private var timer: Timer?

    init(body: PetController) {
        self.body = body
    }

    func start() { scheduleNext() }
    func stop() { timer?.invalidate(); timer = nil }

    /// 每 4–10s 自发做一个小动作(零成本,纯本地),做完再排下一次。
    private func scheduleNext() {
        timer?.invalidate()
        let delay = Double.random(in: 4...10)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
                self?.scheduleNext()
            }
        }
    }

    /// 决定此刻做什么 idle 动作,交给身体执行。
    private func tick() {
        guard body.acceptsIdleBehavior else { return }
        if body.isPerchedIdle {
            body.runPerchedMicro()
            return
        }
        // 站在平台上:沿平台踱步 / 跳去别的平台 / 跳下来 / 否则原地小动作。
        if let pid = body.standingPlatformId {
            let roll = Double.random(in: 0..<1)
            if roll < 0.45, body.platformWalkable(pid) {
                body.idleWalkAlongPlatform(pid); return
            }
            if roll < 0.60, let other = body.randomOtherPlatformId(besides: pid) {
                body.idleJumpToPlatform(other); return
            }
            if roll < 0.70 {
                body.idleJumpOffPlatform(); return
            }
            body.runStandingPlatformMicro(); return
        }
        // 房间地板上、且画了平台:25% 飞上去玩(站到某条平台上)。
        if body.isInHome, body.isUnsupported, body.hasPlatforms, Double.random(in: 0..<1) < 0.25 {
            body.idleFlyUpToRandomPlatform(); return
        }
        // 房间是看咕咕活动的空间:提高踱步频率(否则多被原地小动作淹没)。约 45% 直接踱步。
        if body.isInHome, Double.random(in: 0..<1) < 0.45 {
            body.idleWalkToGroundTarget(); return
        }
        // 常规 idle 池:按当下心情挑一个行为。
        let mood = body.idleMood
        let behavior = IdleSelector.choose(roll: Double.random(in: 0...1),
                                           energy: mood.energy, valence: mood.valence,
                                           availableMove: body.availableIdlePlayMove)
        if body.runIdleMicro(behavior) {
            body.showIdleManpuIfAny()
        }
    }
}
