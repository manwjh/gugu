import AppKit
import GuguKernel
import SpriteKit

/// Borderless transparent always-on-top window hosting the bird.
final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
    }
}

/// SKView subclass that routes mouse interaction to the controller.
final class PetView: SKView {
    weak var controller: PetController?
    private var downAt: CGPoint = .zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragged = false
        controller?.dragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = NSEvent.mouseLocation
        if hypot(loc.x - downAt.x, loc.y - downAt.y) > 4 { dragged = true }
        if dragged { controller?.dragMoved(to: loc) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            controller?.dragEnded()
        } else {
            controller?.dragCancelled()
            if event.clickCount >= 2 {
                controller?.petted()
            } else {
                controller?.poked()
            }
        }
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(at: event, in: self)
    }
}

/// Behavioral states for the body (L0).
enum PetBodyState: String {
    case idle, walk, approach, retreat, perch, flyingToPerch
    case sleep, dance, stare, dragged, falling
    case enteringHome
    case followHand   // 跟随主人的手(共享坐标:走向手的水平位置)
}

enum SupportSurface {
    case appWindow(id: CGWindowID, frame: CGRect)
    case chatInput(frame: CGRect)
    case roomRim(frame: CGRect)        // 小窝内的"上沿"——房间里没有 app 窗口可栖,就栖在房间高处
    case platform(id: UUID)            // 站在/栖在主人画的某条平台上

    var frame: CGRect {
        switch self {
        case .appWindow(_, let frame), .chatInput(let frame), .roomRim(let frame):
            return frame
        case .platform:
            return .zero               // 平台几何另算(房间归一化坐标),不走 frame
        }
    }

    var isChatInput: Bool {
        if case .chatInput = self { return true }
        return false
    }

    var isRoomRim: Bool {
        if case .roomRim = self { return true }
        return false
    }

    var platformId: UUID? {
        if case .platform(let id) = self { return id }
        return nil
    }
}

/// The body: owns the window, the bird node, physics, and the L0 state machine.
/// Entirely local — no model calls here. Receives high-level action labels.
@MainActor
final class PetController: NSObject {
    let window: PetWindow
    private let skView: PetView
    private let scene: SKScene
    let bird: BirdNode
    private let bubble = SpeechBubble()

    private(set) var state: PetBodyState = .idle
    var vel = CGVector.zero
    private var facingRight = true
    private var growthScale: CGFloat = 1
    private var walkTargetX: CGFloat?
    var homeFrame: CGRect?            // 小窝包围框(屏幕坐标);非 nil 表示在小窝(房间)里
    var platforms: [Platform] = []    // 房间内的平台(归一化坐标)
    private var behaviorTimer: Timer?
    private var physicsTimer: Timer?
    var supportSurface: SupportSurface?
    private var perchCompletion: (@MainActor () -> Void)?
    var perchCheckTimer: Timer?
    private var dragSamples: [(p: CGPoint, t: TimeInterval)] = []
    private var dragGrabOffset = CGPoint.zero  // 抓取点相对窗口原点的偏移,拖拽时保持不瞬移
    private var stateUntil: Date = .distantPast
    private var fallFromDrag = false          // distinguishes owner-throw from perch-fall
    private var gracefulFlight = false        // 主动飞起(手势令)→ 落地轻盈,不当摔倒翻滚
    private var lastPerchAttempt = Date.distantPast
    private var pokeCombo = PokeCombo()       // 连击戳计数(递进反应)

    var onPoke: (() -> Void)?
    var onPet: (() -> Void)?
    var onThrown: (() -> Void)?
    var onStateChange: ((PetBodyState) -> Void)?
    var menuProvider: (() -> NSMenu)?
    var speechAvoidanceFrame: CGRect?

    /// idle 自娱自乐时读取当下心情(由 app 注入 Affect;未注入则用中性值)。
    var idleMoodProvider: (() -> (energy: Double, valence: Double))?
    /// idle 时偶尔"自己玩"的一个动作名(由 app 注入,通常随机挑一个已学会/内置动作)。
    var idlePlayMoveProvider: (() -> String?)?
    /// idle 时偶尔自发流露的情绪符号(由 app 注入,读 Affect;大多返回 nil 以免刷屏)。
    var idleManpuProvider: (() -> Manpu?)?

    let winSize = CGSize(width: 150, height: 150)
    /// Bird's feet y-offset inside the scene.
    let feetY: CGFloat = 12

    override init() {
        window = PetWindow(size: winSize)
        skView = PetView(frame: CGRect(origin: .zero, size: winSize))
        scene = SKScene(size: winSize)
        bird = BirdNode()
        super.init()

        scene.backgroundColor = .clear
        scene.scaleMode = .resizeFill
        skView.allowsTransparency = true
        skView.controller = self
        bird.position = CGPoint(x: winSize.width / 2, y: feetY)
        scene.addChild(bird)
        skView.presentScene(scene)
        window.contentView = skView

        // start on main screen bottom, slightly right of center
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX + 200
            window.setFrameOrigin(CGPoint(x: x, y: groundY(for: screen)))
        }
        window.orderFrontRegardless()

        refreshGrowthStage()
        bird.startIdleAnimations()
        startPhysics()
        startBehaviorLoop()
    }

    // MARK: - Geometry helpers

    private var screen: NSScreen {
        NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Window origin y when the bird stands on the visible bottom (above Dock).
    private func groundY(for screen: NSScreen) -> CGFloat {
        screen.visibleFrame.minY - feetY + 4
    }

    /// 当前"世界"的边界(窗口 origin 口径):地板/左右墙/天花板。
    /// 在小窝里 → 用房间矩形 + 鸟可见外框内缩;在桌面 → 用屏幕可见区。
    /// 所有走/落/撞墙/栖息都读它,于是窝内窝外物理完全一致,只是边界不同。
    private struct World {
        var groundY: CGFloat   // 站在地板上时的窗口 origin.y
        var minX: CGFloat      // 左墙(窗口 origin.x 下限)
        var maxX: CGFloat      // 右墙(窗口 origin.x 上限)
        var ceilingY: CGFloat  // 天花板(窗口 origin.y 上限)
    }

    private var currentWorld: World {
        if let home = homeFrame {
            let bv = birdVisibleFrame()
            let pad = homePad
            var minX = home.minX + pad - bv.minX
            var maxX = home.maxX - pad - bv.maxX
            if maxX < minX { let c = (minX + maxX) / 2; minX = c; maxX = c }
            let groundY = home.minY + pad - bv.minY
            var ceilingY = home.maxY - pad - bv.maxY
            if ceilingY < groundY { ceilingY = groundY }
            return World(groundY: groundY, minX: minX, maxX: maxX, ceilingY: ceilingY)
        }
        let vf = screen.visibleFrame
        return World(groundY: vf.minY - feetY + 4,
                     minX: vf.minX,
                     maxX: vf.maxX - winSize.width,
                     ceilingY: vf.maxY - winSize.height)
    }

    private var isOnGround: Bool {
        abs(window.frame.origin.y - currentWorld.groundY) < 2
    }

    private func setFacing(right: Bool) {
        guard facingRight != right else { return }
        facingRight = right
        bird.xScale = (right ? 1 : -1) * growthScale
        bird.setViewDirection(.side)
    }

    // MARK: - Physics loop (60 Hz)

    private func startPhysics() {
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.physicsTick(dt: 1.0 / 60.0) }
        }
        RunLoop.main.add(physicsTimer!, forMode: .common)
    }

    private func physicsTick(dt: CGFloat) {
        var origin = window.frame.origin
        updateHandFollow()   // 主人指向→进入/退出"跟随手"

        switch state {
        case .falling:
            let world = currentWorld
            vel.dy -= 2400 * dt          // gravity
            vel.dx *= 0.995
            origin.x += vel.dx * dt
            origin.y += vel.dy * dt
            // 房间里:先查是否撞到主人画的平台
            if let hit = checkPlatformLanding(at: origin, vel: vel) {
                origin = hit.landingOrigin
                supportSurface = .platform(id: hit.platformId)
                land()
            } else if origin.y <= world.groundY {
                origin.y = world.groundY
                land()
            }
            // 房间里被往上丢:撞天花板回弹,不飞出房间
            if isInHome && origin.y > world.ceilingY {
                origin.y = world.ceilingY
                if vel.dy > 0 { vel.dy = -vel.dy * 0.4 }
            }
            // wall bounce
            if origin.x < world.minX { origin.x = world.minX; vel.dx = abs(vel.dx) * 0.5 }
            if origin.x > world.maxX { origin.x = world.maxX; vel.dx = -abs(vel.dx) * 0.5 }
            window.setFrameOrigin(origin)

        case .walk, .approach, .retreat:
            guard var target = walkTargetX else { transition(to: .idle); return }
            let world = currentWorld
            // 站在平台上:沿平台斜面走,目标与位置都夹在平台两端之间(到端折返)。
            var onPlat: Platform?
            if case .platform(let id) = supportSurface,
               let p = platforms.first(where: { $0.id == id }),
               let r = platformOriginXRange(p) {
                onPlat = p
                target = max(r.min, min(target, r.max))
            }
            let speed: CGFloat = state == .retreat ? 160 : 90
            let dir: CGFloat = target > origin.x ? 1 : -1
            setFacing(right: dir > 0)
            origin.x += dir * speed * dt
            if let p = onPlat, let r = platformOriginXRange(p) {
                origin.x = max(r.min, min(origin.x, r.max))
                if let py = platformOriginY(p, birdCenterX: origin.x + winSize.width / 2) { origin.y = py }
            } else {
                origin.y = world.groundY     // 贴着地板走(房间地板或桌面地面)
                origin.x = max(world.minX, min(origin.x, world.maxX))
            }
            // gentle hop bob
            bird.position.y = feetY + abs(sin(Date().timeIntervalSince1970 * 10)) * 3
            if abs(origin.x - target) < 8 {
                walkTargetX = nil
                bird.position.y = feetY
                transition(to: .idle)
            }
            window.setFrameOrigin(origin)

        case .flyingToPerch:
            guard let surface = supportSurface else {
                perchCompletion = nil
                transition(to: .idle)
                return
            }
            let dest = perchPoint(for: surface)
            let dx = dest.x - origin.x, dy = dest.y - origin.y
            let dist = hypot(dx, dy)
            if dist < 6 {
                window.setFrameOrigin(dest)
                becomePerched()
            } else {
                let speed: CGFloat = 380
                setFacing(right: dx > 0)
                origin.x += dx / dist * speed * dt
                origin.y += dy / dist * speed * dt
                window.setFrameOrigin(origin)
            }

        case .enteringHome:
            guard homeFrame != nil else { transition(to: .idle); return }
            let world = currentWorld
            let dest = CGPoint(x: (world.minX + world.maxX) / 2, y: world.groundY)
            let dx = dest.x - origin.x, dy = dest.y - origin.y
            let dist = hypot(dx, dy)
            if dist < 6 {
                window.setFrameOrigin(dest)
                bird.position.y = feetY
                transition(to: .idle)            // 飞进去落到地板,之后过和窝外一致的 idle 生活
            } else {
                let speed: CGFloat = 380
                setFacing(right: dx > 0)
                origin.x += dx / dist * speed * dt
                origin.y += dy / dist * speed * dt
                window.setFrameOrigin(origin)
            }

        case .followHand:
            // 走向手的水平位置(共享坐标:handX 0=左 1=右,已是主人视角)。手离开就回 idle。
            let world = currentWorld
            guard Perception.shared.handFresh, let hx = Perception.shared.handX else {
                bird.position.y = feetY
                transition(to: .idle)
                break
            }
            let targetX = world.minX + hx * (world.maxX - world.minX)
            origin.y = world.groundY
            let dx = targetX - origin.x
            if abs(dx) > 6 {
                setFacing(right: dx > 0)
                let speed: CGFloat = 160
                origin.x += (dx > 0 ? 1 : -1) * min(abs(dx), speed * dt)
                origin.x = max(world.minX, min(origin.x, world.maxX))
                bird.position.y = feetY + abs(sin(Date().timeIntervalSince1970 * 10)) * 3
            } else {
                bird.position.y = feetY
            }
            window.setFrameOrigin(origin)

        default:
            break
        }
        bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
    }

    private func land() {
        let hard = !gracefulFlight && (abs(vel.dx) > 300 || vel.dy < -900)
        vel = .zero
        gracefulFlight = false
        if hard {
            // tumble: full spin + squash
            bird.run(.sequence([
                .rotate(byAngle: facingRight ? -.pi * 2 : .pi * 2, duration: 0.5),
                .run { [weak self] in self?.bird.zRotation = 0 },
            ]))
            bird.setScale(1.0)
            bird.yScale = 0.7
            bird.run(.scaleY(to: 1.0, duration: 0.3))
            // only an owner drag-throw counts as "thrown"; a perch-fall does not
            if fallFromDrag { bird.showManpu(.anger); onThrown?() }
            transition(to: .idle)
        } else {
            bird.yScale = 0.85
            bird.run(.scaleY(to: 1.0, duration: 0.2))
            transition(to: .idle)
        }
        fallFromDrag = false
    }

    // MARK: - Home (小窝) mode

    private let homePad: CGFloat = 6

    var isInHome: Bool { homeFrame != nil }

    /// 鸟身可见核心外框(窗口本地坐标)。**不**用 calculateAccumulatedFrame——
    /// 那会把隐藏的 aura 光环(半径33)、zzz、展开的翅膀都算进去,导致夹边界时
    /// 以为鸟比实际大一圈,既缩小活动区又在四周留隐形空隙。这里用固定的身体核心
    /// 框(绕 BirdNode 原点按 growthScale 缩放),贴边均匀、活动区最大化。
    func birdVisibleFrame() -> CGRect {
        let s = growthScale
        let core = CGRect(x: -22, y: -4, width: 48, height: 56)   // 本地核心(不含 aura/zzz)
        let cx = winSize.width / 2                                // bird.position.x 固定在窗口中线
        return CGRect(x: cx + core.minX * s,
                      y: feetY + core.minY * s,
                      width: core.width * s,
                      height: core.height * s)
    }

    /// 房间内"踱步"目标 X:朝空间更大的一侧走一段(到墙为止),自然形成撞墙折返。
    private func randomGroundWalkTargetX(in world: World) -> CGFloat {
        guard world.maxX > world.minX else { return world.minX }
        let o = window.frame.origin.x
        let span = world.maxX - world.minX
        let towardRight = (world.maxX - o) >= (o - world.minX)
        let step = CGFloat.random(in: (span * 0.35)...(span * 1.0))
        let raw = towardRight ? o + step : o - step
        return max(world.minX, min(raw, world.maxX))
    }

    /// 进入小窝:从当前位置飞进房间、落到地板,之后过和窝外一致的 idle 生活。
    func enterHome(frame: CGRect) {
        if state == .sleep { wake() }
        perchCheckTimer?.invalidate()
        supportSurface = nil
        perchCompletion = nil
        walkTargetX = nil
        speechAvoidanceFrame = nil
        vel = .zero
        homeFrame = frame
        bird.setViewDirection(.side)
        bird.position.y = feetY
        bird.flapWings(times: 16, fast: true)
        transition(to: .enteringHome)
    }

    /// 小窝被拖动/缩放:更新边界,把咕咕重新落到地板/贴回墙内;栖在上沿则贴回上沿。
    func updateHomeFrame(_ frame: CGRect) {
        guard homeFrame != nil else { return }
        homeFrame = frame
        let world = currentWorld
        if case .roomRim = supportSurface {
            supportSurface = .roomRim(frame: frame)
            if state == .perch || state == .flyingToPerch {
                window.setFrameOrigin(perchPoint(for: .roomRim(frame: frame)))
                return
            }
        }
        var o = window.frame.origin
        o.x = max(world.minX, min(o.x, world.maxX))
        if state == .falling || state == .dragged {
            o.y = max(world.groundY, min(o.y, world.ceilingY))
        } else {
            o.y = world.groundY          // 站/走 → 贴地板
        }
        window.setFrameOrigin(o)
        if let t = walkTargetX { walkTargetX = max(world.minX, min(t, world.maxX)) }
    }

    /// 离开小窝:解除边界,世界切回桌面,咕咕从半空自然坠回桌面地面。
    func leaveHome() {
        guard homeFrame != nil else { return }
        homeFrame = nil
        walkTargetX = nil
        platforms = []
        if case .roomRim = supportSurface { supportSurface = nil }
        perchCheckTimer?.invalidate()
        if state == .dragged { return }   // 拖拽中,松手时再决定
        if state == .sleep { wake() }     // 先醒,避免闭眼下落
        bird.flapWings(times: 6, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -40...40), dy: 0)
        transition(to: .falling)
    }

    /// 跟随手:只要画面里有手(handFresh + handX),咕咕就走向手的水平位置(共享坐标,
    /// 天然不猜左右);手离开画面就停。统一的"手部运动跟随",不再依赖任何静态手型。
    private func updateHandFollow() {
        let free = (state == .idle || state == .walk || state == .followHand)
        if free, Perception.shared.handFresh, Perception.shared.handX != nil {
            if state != .followHand { transition(to: .followHand) }
        } else if state == .followHand {
            bird.position.y = feetY
            transition(to: .idle)
        }
    }

    // MARK: - Autonomous idle life (zero cost)

    private func startBehaviorLoop() {
        scheduleNextBehavior()
    }

    private func scheduleNextBehavior() {
        behaviorTimer?.invalidate()
        let delay = Double.random(in: 4...10)
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.idleMicroBehavior()
                self?.scheduleNextBehavior()
            }
        }
    }

    private func idleMicroBehavior() {
        guard Date() > stateUntil else { return }
        if state == .perch {
            perchedMicroBehavior()
            return
        }
        guard state == .idle else { return }
        // 站在平台上:沿平台走两步 / 偶尔跳去别的平台或跳下来 / 否则原地小动作。
        if case .platform(let id) = supportSurface {
            let roll = Double.random(in: 0..<1)
            // 平台够长 → 45% 沿平台踱步(到端折返)
            if roll < 0.45,
               let plat = platforms.first(where: { $0.id == id }),
               let r = platformOriginXRange(plat), r.max - r.min > 30 {
                walkTargetX = CGFloat.random(in: r.min...r.max)
                transition(to: .walk)
                return
            }
            // 15% 跳去另一条平台(有多条时)
            if roll < 0.60, platforms.count > 1,
               let other = platforms.filter({ $0.id != id }).randomElement() {
                supportSurface = .platform(id: other.id)
                transition(to: .flyingToPerch)
                bird.setViewDirection(.side)
                bird.flapWings(times: 12, fast: true)
                return
            }
            // 10% 跳下平台(回到地板/下层平台)
            if roll < 0.70 {
                supportSurface = nil
                bird.flapWings(times: 4, fast: true)
                vel = CGVector(dx: CGFloat.random(in: -50...50), dy: 0)
                bird.position.y = feetY
                transition(to: .falling)
                return
            }
            // 其余:原地小动作
            switch Int.random(in: 0..<5) {
            case 0: bird.setViewDirection(.side); bird.groomOnce()
            case 1: bird.setViewDirection(.front); bird.peckOnce()
            case 2:
                bird.setViewDirection(.front)
                bird.tiltHead(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.bird.tiltHead(false) }
            case 3: bird.setViewDirection(.front); bird.flapWings(times: 2)
            default: bird.stretchOnce()
            }
            return
        }
        // 在房间地板上、且画了平台:25% 概率飞上去玩(站到某条平台上)。
        if isInHome, supportSurface == nil, !platforms.isEmpty, Double.random(in: 0..<1) < 0.25 {
            let target = platforms.randomElement()!
            supportSurface = .platform(id: target.id)
            transition(to: .flyingToPerch)
            bird.setViewDirection(.side)
            bird.flapWings(times: 14, fast: true)
            return
        }
        // 房间是用来看咕咕活动的空间:提高踱步频率,让走动明显可见(否则多被原地小动作淹没,
        // 且 IdleSelector 在低精力时根本不 wander)。约 45% 直接踱步,其余仍走正常 idle 池。
        if isInHome, Double.random(in: 0..<1) < 0.45 {
            walkTargetX = randomGroundWalkTargetX(in: currentWorld)
            transition(to: .walk)
            return
        }
        let mood = idleMoodProvider?() ?? (energy: 0.7, valence: 0.15)
        let move = idlePlayMoveProvider?()
        let behavior = IdleSelector.choose(roll: Double.random(in: 0...1),
                                           energy: mood.energy, valence: mood.valence,
                                           availableMove: move)
        switch behavior {
        case .wander:
            if isInHome {
                // 房间里:踱步到较远一侧(到墙折返),与窝外"偶尔走动"同一套机制。
                walkTargetX = randomGroundWalkTargetX(in: currentWorld)
                transition(to: .walk)
                return
            }
            guard !detachFromSupportBeforeGroundRelocation(action: "walk") else { return }
            let world = currentWorld
            let dx = CGFloat.random(in: -180...180)
            let target = max(world.minX, min(window.frame.origin.x + dx, world.maxX))
            walkTargetX = target
            transition(to: .walk)
        case .groom:
            bird.setViewDirection(.side)
            bird.groomOnce()
        case .peck:
            bird.setViewDirection(.front)
            bird.peckOnce()
        case .tiltHead:
            bird.setViewDirection(.front)
            bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.bird.tiltHead(false) }
        case .glanceCursor:
            let mouse = NSEvent.mouseLocation
            setFacing(right: mouse.x > window.frame.midX)
            bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bird.tiltHead(false) }
        case .flap:
            bird.setViewDirection(.front)
            bird.flapWings(times: 2)
        case .stretch:
            bird.stretchOnce()
            stateUntil = Date().addingTimeInterval(1.2)
        case .lookAround:
            bird.setViewDirection(.front)
            setFacing(right: true)
            bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.setFacing(right: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bird.tiltHead(false) }
            stateUntil = Date().addingTimeInterval(1.6)
        case .hop:
            perform(action: "hop")
        case .hum:
            // 哼唱:轻轻左右摇 + 飘个音符
            bird.setViewDirection(.front)
            bird.run(.sequence([
                .rotate(toAngle: 0.08, duration: 0.3),
                .rotate(toAngle: -0.08, duration: 0.3),
                .rotate(toAngle: 0, duration: 0.2),
            ]))
            bird.showManpu(.music)
            stateUntil = Date().addingTimeInterval(1.0)
        case .playMove(let name):
            perform(action: name)
        case .standStill:
            break // just stand there, being a bird
        }

        // 行为之外,偶尔自发流露一下当下心情(开心冒心/哼唱、累了冒汗、还在气头上冒青筋)。
        if let m = idleManpuProvider?() { bird.showManpu(m) }
    }

    private func perchedMicroBehavior() {
        let roll = Double.random(in: 0...1)
        switch roll {
        case ..<0.34:
            bird.setViewDirection(.back)
            bird.flapWings(times: 1)
            stateUntil = Date().addingTimeInterval(4.2)
        case ..<0.56:
            bird.setViewDirection(.front)
            bird.peckOnce()
            stateUntil = Date().addingTimeInterval(1.4)
        case ..<0.76:
            bird.setViewDirection(.side)
            bird.groomOnce()
            stateUntil = Date().addingTimeInterval(2.0)
        default:
            bird.setViewDirection(.front)
        }
    }

    // MARK: - High-level actions (from heartbeat decisions)

    func perform(action: String) {
        guard state != .dragged else {
            Log.info("action", "被拖拽中，忽略 \(action)")
            return
        }
        // 学会的动作优先:若 action 命中 moves/ 里的某个动作名,演它(数据化编排)。
        if let move = MoveLibrary.shared.move(named: action) {
            performLearnedMove(move)
            return
        }
        if state == .sleep && action != "sleep" { wake() }
        if state == .flyingToPerch, action != "idle" {
            if supportSurface?.isChatInput == true {
                if canPerformAfterChatInputPerch(action) {
                    queueActionAfterChatInputPerch(action)
                }
                Log.info("action", "正在飞向聊天框，忽略 \(action)")
                return
            }
            if relocatesBody(action) {
                Log.info("action", "正在飞行中，忽略位移动作 \(action)")
                return
            }
        }
        if detachFromSupportBeforeGroundRelocation(action: action) {
            return
        }
        switch action {
        case "walk":
            // 走两步:在附近小幅走动,而不是窜到世界另一头
            let world = currentWorld
            let step = CGFloat.random(in: 60...160) * (Bool.random() ? 1 : -1)
            walkTargetX = max(world.minX, min(window.frame.origin.x + step, world.maxX))
            transition(to: .walk)
        case "wander":
            // 大幅走动(心跳里偶尔用)
            let world = currentWorld
            walkTargetX = CGFloat.random(in: world.minX...world.maxX)
            transition(to: .walk)
        case "approach", "come":
            let world = currentWorld
            let mouse = NSEvent.mouseLocation
            walkTargetX = max(world.minX, min(mouse.x - winSize.width / 2, world.maxX))
            transition(to: .approach)
        case "retreat", "away":
            let world = currentWorld
            let leftDist = window.frame.origin.x - world.minX
            let rightDist = world.maxX - window.frame.origin.x
            walkTargetX = leftDist < rightDist ? world.minX : world.maxX
            transition(to: .retreat)
        case "fly":
            flyInPlace()
        case "perch":
            startPerch()
        case "settle", "sit":
            settleDown()
        case "sleep":
            sleep()
        case "dance":
            dance()
        case "stare":
            let mouse = NSEvent.mouseLocation
            setFacing(right: mouse.x > window.frame.midX)
            bird.tiltHead(true)
            bird.showManpu(.question)
            stateUntil = Date().addingTimeInterval(4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.bird.tiltHead(false) }
        case "peck":
            bird.setViewDirection(.front)
            bird.peckOnce()
        case "groom":
            bird.setViewDirection(.side)
            bird.groomOnce()
        case "yawn":
            bird.setViewDirection(.front)
            bird.yawnOnce()
        case "jump", "hop":
            // 站在平台上跳:给斜向上初速,detach,转 falling 抛物线飞行(可能落到另一平台)
            if case .platform = supportSurface {
                let horizDir: CGFloat = Bool.random() ? 1 : -1
                vel = CGVector(dx: horizDir * 120, dy: 180)
                supportSurface = nil
                transition(to: .falling)
                bird.flapWings(times: 3, fast: true)
                return
            }
            // 地面/上沿:原地轻跳动画(不改变窗口位置)
            bird.run(.sequence([
                .moveBy(x: 0, y: 22, duration: 0.16),
                .moveBy(x: 0, y: -22, duration: 0.14),
            ]))
            bird.flapWings(times: 2, fast: true)
        case "nod", "yes":
            bird.setViewDirection(.front)
            bird.head.run(.sequence([
                .moveBy(x: 2, y: -6, duration: 0.12), .moveBy(x: -2, y: 6, duration: 0.12),
                .moveBy(x: 2, y: -6, duration: 0.12), .moveBy(x: -2, y: 6, duration: 0.12),
            ]))
        default:
            break // idle
        }
    }

    /// 演一个"学会的动作":把元动作编排翻成 SKAction 跑在身体上(本地零成本)。
    /// 动作期间临时锁住 idle 微行为,演完恢复站姿与呼吸。
    func performLearnedMove(_ move: Move) {
        guard state == .idle || state == .perch else {
            // 正在走/飞/睡等,先回到 idle 再演,避免动作打架。
            if state == .sleep { wake() }
            else if state != .idle { return }
            return
        }
        let total = MetaActionValidator.totalDuration(move.steps)
        stateUntil = Date().addingTimeInterval(total + 0.2)
        bird.stopIdleAnimations()
        let action = MoveInterpreter.compile(move.steps, on: bird, say: { [weak self] text in
            self?.say(text)
        }, face: { [weak self] right in
            self?.facingRight = right
        })
        bird.run(action, withKey: "learnedMove")
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.25) { [weak self] in
            guard let self, self.state == .idle || self.state == .perch else { return }
            self.bird.zRotation = 0
            self.bird.setScale(self.growthScale)
            self.bird.xScale = (self.facingRight ? 1 : -1) * self.growthScale
            self.bird.position.y = self.feetY
            self.bird.setViewDirection(.front)
            self.bird.startIdleAnimations()
        }
    }

    /// 主人手向上一挥 → 真的朝上飞一段:用重力模型给一个向上的初速度,
    /// 抛物线冲上去再自然落回(鸟飞不出屏幕,上冲再回落正是自然的"飞一个")。
    /// 与原地扑腾不同——这是窗口在空间里真的上移,方向对应手势方向。
    func flyUpward() {
        switch state {
        case .idle, .perch, .walk, .approach, .retreat, .followHand: break
        default: return   // 下落/拖拽/进窝等过程中不打断
        }
        supportSurface = nil          // 离开栖息面,交给重力
        perchCompletion = nil
        fallFromDrag = false
        gracefulFlight = true         // 落地走轻盈分支,不翻滚
        bird.setViewDirection(.front)
        bird.flapWings(times: 12, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -60...60), dy: 1050)   // 向上冲,峰高≈230pt
        transition(to: .falling)
    }

    /// 原地飞:扑腾翅膀小幅升空再落回(不去栖息窗口)。
    private func flyInPlace() {
        guard state == .idle || state == .perch else { return }
        stateUntil = Date().addingTimeInterval(2)
        bird.setViewDirection(.front)
        bird.flapWings(times: 10, fast: true)
        bird.run(.sequence([
            .moveBy(x: 0, y: 60, duration: 0.4),
            .moveBy(x: CGFloat.random(in: -20...20), y: 0, duration: 0.3),
            .moveBy(x: 0, y: -60, duration: 0.4),
        ]))
    }

    /// 蹲伏歇着:鸟把腿收起、身子贴地、羽毛微蓬(不是狗式端坐)。
    private func settleDown() {
        bird.setViewDirection(.front)
        bird.removeAction(forKey: "breathe")
        // 收脚:把脚藏到身下
        bird.footL.run(.fadeAlpha(to: 0, duration: 0.25))
        bird.footR.run(.fadeAlpha(to: 0, duration: 0.25))
        // 身子下沉压扁、略微变宽(蓬毛感)
        bird.run(.group([.scaleY(to: 0.72, duration: 0.3), .scaleX(to: 1.06, duration: 0.3)]))
        bird.position.y = max(2, feetY - 8)
        stateUntil = Date().addingTimeInterval(8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.bird.footL.run(.fadeAlpha(to: 1, duration: 0.25))
            self.bird.footR.run(.fadeAlpha(to: 1, duration: 0.25))
            self.bird.run(.group([.scaleY(to: 1.0, duration: 0.3), .scaleX(to: 1.0, duration: 0.3)]))
            self.bird.position.y = self.feetY
            self.bird.startIdleAnimations()
        }
    }

    func transition(to new: PetBodyState) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    func refreshGrowthStage() {
        let stage = GrowthStage(rawStage: PetState.load().stage)
        growthScale = stage.visualScale
        bird.apply(stage: stage)
        bird.xScale = (facingRight ? 1 : -1) * growthScale
    }

    func celebrateEvolution(to stage: GrowthStage) {
        bird.celebrateEvolution(to: stage)
        bird.flapWings(times: stage == .spirit ? 18 : 12, fast: true)
        say(L.grewUp)
    }

    private func dance() {
        stateUntil = Date().addingTimeInterval(3)
        bird.setViewDirection(.front)
        bird.flapWings(times: 8, fast: true)
        bird.showManpu(.music)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.bird.showManpu(.music) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.bird.showManpu(.music) }
        let hop = SKAction.sequence([
            .moveBy(x: 0, y: 14, duration: 0.14),
            .moveBy(x: 0, y: -14, duration: 0.12),
        ])
        let wiggle = SKAction.sequence([
            .rotate(toAngle: 0.15, duration: 0.13),
            .rotate(toAngle: -0.15, duration: 0.13),
            .rotate(toAngle: 0, duration: 0.1),
        ])
        bird.run(.repeat(.group([hop, wiggle]), count: 5))
    }

    // MARK: - Sleep / wake

    func sleep() {
        guard state != .sleep else { return }
        bird.setViewDirection(.front)
        bird.removeAction(forKey: "struggle")
        bird.zRotation = 0
        bird.position.y = feetY
        bird.footL.run(.fadeAlpha(to: 1, duration: 0.12))
        bird.footR.run(.fadeAlpha(to: 1, duration: 0.12))
        bird.xScale = (facingRight ? 1 : -1) * growthScale
        transition(to: .sleep)
        bird.setEyesClosed(true, animated: false)
        bird.startSleepZzz()
        bird.removeAction(forKey: "blinkLoop")
        bird.yScale = 0.92 * growthScale
    }

    func wake() {
        guard state == .sleep else { return }
        bird.setEyesClosed(false, animated: false)
        bird.stopSleepZzz()
        bird.position.y = feetY
        bird.footL.run(.fadeAlpha(to: 1, duration: 0.12))
        bird.footR.run(.fadeAlpha(to: 1, duration: 0.12))
        bird.xScale = (facingRight ? 1 : -1) * growthScale
        bird.yScale = growthScale
        bird.startIdleAnimations()
        // 在小窝里醒来:贴回地板/墙内,回到 idle 站立,由 idle 循环决定下一步。
        if isInHome, !(supportSurface?.isRoomRim ?? false) {
            let world = currentWorld
            var o = window.frame.origin
            o.x = max(world.minX, min(o.x, world.maxX))
            o.y = world.groundY
            window.setFrameOrigin(o)
        }
        transition(to: .idle)
    }

    var isSleeping: Bool { state == .sleep }

    // MARK: - Perch on frontmost window

    private func startPerch() {
        // 房间里:优先栖到离当前位置最近的平台;没有平台才栖到房间上沿。
        if let home = homeFrame {
            perchCheckTimer?.invalidate()
            if let nearest = nearestPlatform() {
                supportSurface = .platform(id: nearest.id)
            } else {
                supportSurface = .roomRim(frame: home)
            }
            perchCompletion = nil
            transition(to: .flyingToPerch)
            bird.setViewDirection(.side)
            bird.flapWings(times: 16, fast: true)
            return
        }
        // don't thrash: at most one perch attempt per 10s
        guard Date().timeIntervalSince(lastPerchAttempt) > 10 else {
            Log.info("perch", "冷却中，距上次尝试不到10s")
            say(L.perchCooldown)
            return
        }
        guard let target = PetController.frontmostWindowInfo() else {
            Log.info("perch", "找不到可站的窗口")
            say(L.perchNoWindow)
            return
        }
        lastPerchAttempt = Date()
        perchCheckTimer?.invalidate()
        supportSurface = .appWindow(id: target.id, frame: target.frame)
        perchCompletion = nil
        transition(to: .flyingToPerch)
        bird.setViewDirection(.side)
        bird.flapWings(times: 20, fast: true)
    }

    func perch(on frame: CGRect) {
        guard state != .dragged else { return }
        guard homeFrame == nil else { return }   // 小窝里不去栖息聊天框
        if state == .sleep { wake() }
        perchCheckTimer?.invalidate()
        supportSurface = .chatInput(frame: frame)
        perchCompletion = nil
        speechAvoidanceFrame = frame
        transition(to: .flyingToPerch)
        bird.setViewDirection(.side)
        bird.flapWings(times: 16, fast: true)
    }

    func updateInputPanelFrame(_ frame: CGRect?) {
        speechAvoidanceFrame = frame

        guard supportSurface?.isChatInput == true else {
            bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
            return
        }

        guard let frame else {
            supportSurface = nil
            perchCompletion = nil
            if state == .flyingToPerch {
                bird.flapWings(times: 4, fast: true)
                vel = .zero
                transition(to: .falling)
            } else if state == .perch {
                bird.flapWings(times: 6, fast: true)
                vel = CGVector(dx: CGFloat.random(in: -40...40), dy: 0)
                transition(to: .falling)
            } else if state == .sleep && !isOnGround {
                wake()
                bird.flapWings(times: 4, fast: true)
                vel = CGVector(dx: CGFloat.random(in: -40...40), dy: 0)
                transition(to: .falling)
            }
            bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
            return
        }

        supportSurface = .chatInput(frame: frame)
        if shouldFollowChatInputSurface {
            window.setFrameOrigin(perchPoint(for: .chatInput(frame: frame)))
        }
        bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
    }

    private var shouldFollowChatInputSurface: Bool {
        switch state {
        case .dragged, .falling, .walk, .approach, .retreat:
            return false
        default:
            return true
        }
    }

    private func perchPoint(for surface: SupportSurface) -> CGPoint {
        // 平台:站在平台中点(鸟脚踩线段)
        if case .platform(let id) = surface, let home = homeFrame,
           let plat = platforms.first(where: { $0.id == id }) {
            let (s, e) = plat.absolute(in: home)
            let midX = (s.x + e.x) / 2
            let midY = (s.y + e.y) / 2
            return CGPoint(x: midX - winSize.width / 2, y: midY - birdVisibleFrame().minY)
        }
        // 房间上沿:从当前 x 直直飞到房间高处(鸟身顶贴近天花板),x 夹在左右墙内。
        if case .roomRim(let home) = surface {
            let bv = birdVisibleFrame()
            var minX = home.minX + homePad - bv.minX
            var maxX = home.maxX - homePad - bv.maxX
            if maxX < minX { let c = (minX + maxX) / 2; minX = c; maxX = c }
            let x = max(minX, min(window.frame.origin.x, maxX))
            let y = home.maxY - homePad - bv.maxY
            return CGPoint(x: x, y: y)
        }
        // Surface frames are in AppKit coords (bottom-left origin).
        let frame = surface.frame
        let x = max(frame.minX, min(frame.midX - winSize.width / 2, frame.maxX - winSize.width))
        let y = surface.isChatInput ? frame.maxY - feetY + 4 : frame.maxY - feetY - 2
        return CGPoint(x: x, y: y)
    }

    private func becomePerched() {
        // 飞到平台:站上去(.idle),可在上面走动/折返,而不是静止 perch。
        if case .platform = supportSurface {
            bird.setViewDirection(.front)
            bird.position.y = feetY
            bird.yScale = 0.9
            bird.run(.scaleY(to: 1.0, duration: 0.2))
            let completion = perchCompletion
            perchCompletion = nil
            transition(to: .idle)
            completion?()
            return
        }
        transition(to: .perch)
        bird.setViewDirection(.front)
        bird.yScale = 0.9
        bird.run(.scaleY(to: 1.0, duration: 0.2))
        perchCheckTimer?.invalidate()
        if case .appWindow = supportSurface {
            perchCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPerchStillValid() }
            }
        }
        let completion = perchCompletion
        perchCompletion = nil
        completion?()
    }

    private func queueActionAfterChatInputPerch(_ action: String) {
        let previous = perchCompletion
        perchCompletion = { [weak self] in
            previous?()
            self?.perform(action: action)
        }
    }

    private func canPerformAfterChatInputPerch(_ action: String) -> Bool {
        !relocatesBody(action)
    }

    private func detachFromSupportBeforeGroundRelocation(action: String) -> Bool {
        guard supportSurface != nil, startsGroundRelocation(action) else { return false }

        perchCheckTimer?.invalidate()
        supportSurface = nil
        perchCompletion = nil
        walkTargetX = nil
        fallFromDrag = false

        guard !isOnGround else { return false }

        bird.position.y = feetY
        bird.flapWings(times: 6, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -40...40), dy: 0)
        transition(to: .falling)
        return true
    }

    private func startsGroundRelocation(_ action: String) -> Bool {
        switch action {
        case "walk", "wander", "approach", "come", "retreat", "away":
            return true
        default:
            return false
        }
    }

    private func relocatesBody(_ action: String) -> Bool {
        switch action {
        case "walk", "wander", "approach", "come", "retreat", "away", "perch":
            return true
        default:
            return false
        }
    }

    private func checkPerchStillValid() {
        guard (state == .perch || state == .sleep), case let .appWindow(id, frame) = supportSurface else {
            perchCheckTimer?.invalidate(); return
        }
        let current = PetController.windowInfo(for: id)
        if let cur = current, abs(cur.frame.maxY - frame.maxY) < 4, abs(cur.frame.midX - frame.midX) < 4 {
            return // still solid
        }
        // window moved or vanished: feet lose ground → fall
        perchCheckTimer?.invalidate()
        supportSurface = nil
        perchCompletion = nil
        if state == .sleep { wake() }
        bird.flapWings(times: 6, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -60...60), dy: 0)
        transition(to: .falling)
    }

    // MARK: - Dragging

    func dragBegan() {
        if state == .sleep { wake() }
        perchCheckTimer?.invalidate()
        supportSurface = nil
        perchCompletion = nil
        transition(to: .dragged)
        bird.setViewDirection(.front)
        let m = NSEvent.mouseLocation
        // 记下抓取点相对窗口原点的偏移,拖拽时保持它 → 鸟跟着光标走,不在起手瞬移。
        dragGrabOffset = CGPoint(x: m.x - window.frame.origin.x, y: m.y - window.frame.origin.y)
        dragSamples = [(m, Date().timeIntervalSince1970)]
        bird.setEyesClosed(false)
        // struggle wiggle
        bird.run(.repeatForever(.sequence([
            .rotate(toAngle: 0.2, duration: 0.1),
            .rotate(toAngle: -0.2, duration: 0.1),
        ])), withKey: "struggle")
        bird.flapWings(times: 30, fast: true)
    }

    func dragMoved(to loc: CGPoint) {
        var origin = CGPoint(x: loc.x - dragGrabOffset.x, y: loc.y - dragGrabOffset.y)
        // 房间里拖拽:夹在四壁内,不让咕咕被拖出边界。
        if isInHome {
            let world = currentWorld
            origin.x = max(world.minX, min(origin.x, world.maxX))
            origin.y = max(world.groundY, min(origin.y, world.ceilingY))
        }
        window.setFrameOrigin(origin)
        dragSamples.append((loc, Date().timeIntervalSince1970))
        if dragSamples.count > 6 { dragSamples.removeFirst() }
        bubble.follow(petWindow: window)
    }

    func dragEnded() {
        bird.removeAction(forKey: "struggle")
        bird.zRotation = 0
        // 松手后靠重力落下:桌面落到地面、房间里落到房间地板(撞墙反弹)。
        // 房间里是"丢着玩",不算被丢出去(不触发 thrown)。
        fallFromDrag = !isInHome
        // velocity from recent samples
        if dragSamples.count >= 2 {
            let a = dragSamples.first!, b = dragSamples.last!
            let dt = max(0.016, b.t - a.t)
            vel = CGVector(dx: (b.p.x - a.p.x) / dt, dy: (b.p.y - a.p.y) / dt)
            // cap insane velocities
            vel.dx = max(-1600, min(1600, vel.dx))
            vel.dy = max(-1200, min(1200, vel.dy))
        } else {
            vel = .zero
        }
        transition(to: .falling)
    }

    func dragCancelled() {
        bird.removeAction(forKey: "struggle")
        bird.zRotation = 0
        if !isOnGround && state == .dragged {
            vel = .zero
            transition(to: .falling)
        } else if state == .dragged {
            transition(to: .idle)
        }
    }

    // MARK: - Direct interactions

    func poked() {
        if state == .sleep { wake() }
        bird.setViewDirection(.front)

        let combo = pokeCombo.registerPoke()
        let reaction = PokeCombo.reaction(for: combo)
        switch reaction {
        case .mild:
            bird.showManpu(.surprise)
            bird.peckOnce()
            bird.run(.sequence([
                .moveBy(x: 0, y: 10, duration: 0.1),
                .moveBy(x: 0, y: -10, duration: 0.12),
            ]))
        case .annoyed:
            // 有点烦:扭头 + 小幅后仰
            bird.showManpu(.anger)
            setFacing(right: !facingRight)
            bird.tiltHead(true)
            bird.run(.sequence([
                .moveBy(x: facingRight ? -6 : 6, y: 0, duration: 0.1),
                .moveBy(x: facingRight ? 6 : -6, y: 0, duration: 0.12),
            ]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.bird.tiltHead(false) }
        case .dizzy:
            // 被戳晕:左右摇晃 + 头顶螺旋 + 晕眼
            bird.showManpu(.dizzy)
            bird.dizzyEyes(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.bird.dizzyEyes(false) }
            bird.run(.sequence([
                .rotate(toAngle: 0.18, duration: 0.1),
                .rotate(toAngle: -0.18, duration: 0.1),
                .rotate(toAngle: 0.12, duration: 0.1),
                .rotate(toAngle: 0, duration: 0.1),
            ]))
        case .flee:
            // 受不了,躲到一边
            bird.showManpu(.sweat)
            perform(action: "retreat")
        }
        if let words = reaction.speech, state != .sleep {
            say(words)
        }
        onPoke?()
    }

    func petted() {
        if state == .sleep { wake() }
        bird.setViewDirection(.front)
        bird.showBlush(true)
        bird.showManpu(.love)
        bird.tiltHead(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.bird.showBlush(false)
            self?.bird.tiltHead(false)
        }
        onPet?()
    }

    func showContextMenu(at event: NSEvent, in view: NSView) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - Speech

    /// 说话时朗读这句话(由 app 注入 Voice;未注入则只显示气泡)。
    var speakAloud: ((String, String) -> Void)?

    func say(_ text: String, mood: String = "平静") {
        let display = PetController.desktopSpeech(from: text)
        guard !display.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        bubble.show(text: display, near: window, avoiding: speechAvoidanceFrame)
        speakAloud?(display, mood)
        // a little chirp gesture when speaking
        bird.setViewDirection(.front)
        bird.peckOnce()
    }

    static func desktopSpeech(from text: String) -> String {
        var out = text
        while let start = out.firstIndex(of: "("),
              let end = out[start...].firstIndex(of: ")") {
            out.removeSubrange(start...end)
        }
        while let start = out.firstIndex(of: "（"),
              let end = out[start...].firstIndex(of: "）") {
            out.removeSubrange(start...end)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceStops = CharacterSet(charactersIn: "。！？!?")
        var pieces: [String] = []
        var current = ""
        for scalar in out.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if sentenceStops.contains(scalar) {
                pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                if pieces.count >= 2 { break }
            }
        }
        if pieces.isEmpty {
            pieces = [out]
        }
        let joined = pieces.joined(separator: "\n")
        if joined.count > 80 {
            return String(joined.prefix(76)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return joined
    }
}
