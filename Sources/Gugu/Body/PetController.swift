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

/// **世界位移**动作:会改 `position`、走状态机,身体真的在世界里移动。
/// 由 startLocomotion(_:) 执行。新增此类动作 = 自觉接受"要回收 support/world"的责任。
enum Locomotion {
    case walk           // 走两步(附近小幅)
    case wander         // 大幅走动
    case approach       // 走向光标
    case retreat        // 退到空间更大的一侧
    case perch          // 飞去栖息(平台/上沿/窗口/聊天框)
    case platformJump   // 站在平台上时的跳跃(给斜向初速→抛物线飞行)
}

/// **局部表演**动作:只在 `bird` 节点上跑动画,**绝不改 position**,演完恢复站姿。
/// 由 perform(gesture:) 执行。模型学会的 move 由构造即属此类——
/// 只能组合表演元动作,拿不到世界位移能力(安全边界)。
enum Gesture {
    case fly            // 原地扑腾升空再落回(不去栖息)
    case settle         // 蹲伏歇着
    case dance
    case stare          // 盯着光标方向,歪头冒问号
    case peck
    case groom
    case yawn
    case hop            // 原地轻跳(地面/上沿;不改窗口位置)
    case nod
    case learnedMove(Move)
}

/// **脑子→身体的行为意图**——LLM 心跳/聊天、菜单、语音命令都说这一套话(唯一行为端口)。
/// 身体在 perform(_:) 里决定可行性(在睡吗?飞行中?够得着吗?)并可拒绝/妥协;
/// 这是 Intent(想做什么)与内部 Locomotion/Gesture(身体怎么做)之间那道清晰的门。
enum Intent: Equatable {
    case idle                                  // 什么都不做
    case walk, wander, approach, retreat       // 地面位移
    case goPerch                               // 飞去栖息
    case fly, settle, dance, stare, peck, groom, yawn, hop, nod   // 局部表演
    case sleep, wake                           // 生命周期

    /// LLM/菜单/语音传来的动作字符串 → 意图(唯一解析口)。未知 → idle。
    /// 注:学会的动作名(动态)不在此解析,由 perform(action:) 适配器先行查表演出。
    init(action: String) {
        switch action {
        case "walk":              self = .walk
        case "wander":            self = .wander
        case "approach", "come":  self = .approach
        case "retreat", "away":   self = .retreat
        case "perch":             self = .goPerch
        case "fly":               self = .fly
        case "settle", "sit":     self = .settle
        case "dance":             self = .dance
        case "stare":             self = .stare
        case "peck":              self = .peck
        case "groom":             self = .groom
        case "yawn":              self = .yawn
        case "jump", "hop":       self = .hop
        case "nod", "yes":        self = .nod
        case "sleep":             self = .sleep
        default:                  self = .idle
        }
    }

    /// 会让身体在世界里移动(位移类)——飞行中 / 聊天框栖息时要拦截。
    var relocatesBody: Bool {
        switch self {
        case .walk, .wander, .approach, .retreat, .goPerch: return true
        default: return false
        }
    }

    /// 地面位移(走类,不含 perch)——有支撑面时要先脱离再走。
    var startsGroundRelocation: Bool {
        switch self {
        case .walk, .wander, .approach, .retreat: return true
        default: return false
        }
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
    /// 身体在世界中的**权威位置**(窗口 origin 口径)。窗口只是它的镜像——
    /// 一切移动只改 position,再经 commit() 推到窗口;读位置一律读 position,绝不读 window.frame。
    /// setter 文件私有(只此文件能改),getter 内部可见(扩展只读)→ 编译器保证唯一事实源。
    private(set) var position = CGPoint.zero
    private var facingRight = true
    private var growthScale: CGFloat = 1
    private var walkTargetX: CGFloat?
    var homeFrame: CGRect?            // 小窝包围框(屏幕坐标);非 nil 表示在小窝(房间)里
    var platforms: [Platform] = []    // 房间内的平台(归一化坐标)
    private var behaviorLoop: PetBehaviorLoop?
    private var physicsTimer: Timer?
    /// "脚下踩着什么"——支撑面。**只能经 setSupport(_:) 写入**(setter 文件私有)。
    private(set) var supportSurface: SupportSurface?
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
            position = CGPoint(x: x, y: groundY(for: screen))
            commit()
        }
        window.orderFrontRegardless()

        refreshGrowthStage()
        bird.startIdleAnimations()
        startPhysics()
        behaviorLoop = PetBehaviorLoop(body: self)
        behaviorLoop?.start()
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
        // 左右墙按**鸟可见身体**算(而非 150px 窗口),让鸟可见边沿正好贴到屏幕左右沿,
        // 留白=0;与小窝模式同一套(pad 取 0)。窗口透明,多出的部分挂到屏幕外即可。
        let bv = birdVisibleFrame()
        return World(groundY: vf.minY - feetY + 4,
                     minX: vf.minX - bv.minX,
                     maxX: vf.maxX - bv.maxX,
                     ceilingY: vf.maxY - winSize.height)
    }

    private var isOnGround: Bool {
        abs(position.y - currentWorld.groundY) < 2
    }

    private func setFacing(right: Bool) {
        guard facingRight != right else { return }
        facingRight = right
        bird.xScale = (right ? 1 : -1) * growthScale
        bird.setViewDirection(.side)
    }

    /// 把权威位置推到窗口并让气泡跟随——**所有位置写入的唯一出口**。
    /// 物理与交互只改 position,然后 commit();窗口由此始终镜像 position。
    private func commit() {
        window.setFrameOrigin(position)
        bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
    }

    /// "脚下踩着什么"的唯一写入口。集中于此,便于后续在一处统一维护支撑相关不变量。
    func setSupport(_ surface: SupportSurface?) {
        supportSurface = surface
    }

    // MARK: - Physics loop (60 Hz)

    private func startPhysics() {
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.physicsTick(dt: 1.0 / 60.0) }
        }
        RunLoop.main.add(physicsTimer!, forMode: .common)
    }

    private func physicsTick(dt: CGFloat) {
        var origin = position
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
                setSupport(.platform(id: hit.platformId))
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
            position = origin

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
            bird.startWalkCadence(speed: speed)   // 脚步交替(已在走则无操作);离开 walk 态时 transition 收尾
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
            position = origin

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
                position = dest
                becomePerched()
            } else {
                let speed: CGFloat = 380
                setFacing(right: dx > 0)
                origin.x += dx / dist * speed * dt
                origin.y += dy / dist * speed * dt
                position = origin
            }

        case .enteringHome:
            guard homeFrame != nil else { transition(to: .idle); return }
            let world = currentWorld
            let dest = CGPoint(x: (world.minX + world.maxX) / 2, y: world.groundY)
            let dx = dest.x - origin.x, dy = dest.y - origin.y
            let dist = hypot(dx, dy)
            if dist < 6 {
                position = dest
                bird.position.y = feetY
                transition(to: .idle)            // 飞进去落到地板,之后过和窝外一致的 idle 生活
            } else {
                let speed: CGFloat = 380
                setFacing(right: dx > 0)
                origin.x += dx / dist * speed * dt
                origin.y += dy / dist * speed * dt
                position = origin
            }

        case .followHand:
            // 逗它玩:飞向指尖的 2D 位置,懒散缓动、跟不太紧;到跟前偶尔啄一下。
            let world = currentWorld
            guard Perception.shared.handFresh,
                  let nx = Perception.shared.handX, let ny = Perception.shared.handY else {
                loseFingerInterest()
                break
            }
            let tx = world.minX + nx * (world.maxX - world.minX)
            let ty = world.groundY + ny * (world.ceilingY - world.groundY)
            let dx = tx - origin.x, dy = ty - origin.y
            let dist = hypot(dx, dy)
            if dist > 26 {
                setFacing(right: dx > 0)
                let maxStep: CGFloat = 190 * dt                 // 限速:慵懒,追不太上
                let step = min(dist * 0.12, maxStep)            // 指数缓动:近了慢、远了也不暴冲
                origin.x += dx / dist * step
                origin.y += dy / dist * step
                bird.position.y = feetY + sin(Date().timeIntervalSince1970 * 12) * 2   // 飞行微颤
                position = origin
            } else {
                bird.position.y = feetY
                position = origin
                if Date().timeIntervalSince(lastChasePeck) > 1.0 {   // 到指尖跟前:逗一下
                    lastChasePeck = Date()
                    bird.peckOnce()
                }
            }

        default:
            break
        }
        commit()
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
        let o = position.x
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
        setSupport(nil)
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
            setSupport(.roomRim(frame: frame))
            if state == .perch || state == .flyingToPerch {
                position = perchPoint(for: .roomRim(frame: frame))
                commit()
                return
            }
        }
        var o = position
        o.x = max(world.minX, min(o.x, world.maxX))
        if state == .falling || state == .dragged {
            o.y = max(world.groundY, min(o.y, world.ceilingY))
        } else {
            o.y = world.groundY          // 站/走 → 贴地板
        }
        position = o
        commit()
        if let t = walkTargetX { walkTargetX = max(world.minX, min(t, world.maxX)) }
    }

    /// 离开小窝:解除边界,世界切回桌面,咕咕从半空自然坠回桌面地面。
    func leaveHome() {
        guard homeFrame != nil else { return }
        homeFrame = nil
        walkTargetX = nil
        platforms = []
        if case .roomRim = supportSurface { setSupport(nil) }
        perchCheckTimer?.invalidate()
        if state == .dragged { return }   // 拖拽中,松手时再决定
        if state == .sleep { wake() }     // 先醒,避免闭眼下落
        bird.flapWings(times: 6, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -40...40), dy: 0)
        transition(to: .falling)
    }

    // 逗它玩:指尖在画面里**动**才会引起注意(静止的手不追);追的是指尖的 2D 位置,
    // 飞着懒散地跟、跟不太紧;指尖不动 ~2s 或离开画面 → 失去兴趣,回去自己玩。
    private var lastFingerMove = Date.distantPast
    private var prevFingerNorm: CGPoint?
    private var lastChasePeck = Date.distantPast

    private func updateHandFollow() {
        let free = (state == .idle || state == .walk || state == .followHand)
        let now = Date()
        guard Perception.shared.handFresh,
              let nx = Perception.shared.handX, let ny = Perception.shared.handY else {
            prevFingerNorm = nil
            if state == .followHand { loseFingerInterest() }
            return
        }
        let p = CGPoint(x: nx, y: ny)
        if let prev = prevFingerNorm, hypot(p.x - prev.x, p.y - prev.y) > 0.02 {
            lastFingerMove = now                      // 指尖动了一下(低灵敏:微抖不算)
        }
        prevFingerNorm = p
        let playing = now.timeIntervalSince(lastFingerMove) < 2.0   // 2s 不动=失去兴趣
        if free, playing {
            if state != .followHand {
                transition(to: .followHand)
                bird.tiltHead(true)                   // "咦?" 注意到了
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.bird.tiltHead(false) }
            }
        } else if state == .followHand {
            loseFingerInterest()
        }
    }

    /// 失去兴趣:在空中就**优雅滑落**(交给重力,落地不翻滚,与主动飞行一致);在地面就回 idle。
    private func loseFingerInterest() {
        if position.y > currentWorld.groundY + 2 {
            gracefulFlight = true                       // 轻盈落地,不当摔倒翻滚
            vel = CGVector(dx: 0, dy: -40)              // 从悬停起一个柔和的初速,自然滑下而非僵在空中
            transition(to: .falling)
        } else {
            bird.position.y = feetY
            transition(to: .idle)
        }
    }

    // MARK: - Autonomous idle life — 执行口(调度与决策在 PetBehaviorLoop)

    /// 此刻能否插入 idle 自娱:不在"别打断"窗口内,且站着或栖着。
    var acceptsIdleBehavior: Bool { Date() > stateUntil && (state == .idle || state == .perch) }
    /// 栖息态(idle 决策树据此走 perched 分支)。
    var isPerchedIdle: Bool { state == .perch }
    /// 当前站在哪条平台上(没站平台 → nil)。
    var standingPlatformId: UUID? { supportSurface?.platformId }
    /// 完全没有支撑面(房间地板上)。
    var isUnsupported: Bool { supportSurface == nil }
    var hasPlatforms: Bool { !platforms.isEmpty }
    /// 当下心情(未注入 → 中性值)。
    var idleMood: (energy: Double, valence: Double) { idleMoodProvider?() ?? (energy: 0.7, valence: 0.15) }
    /// idle 时可"自己玩"的一个动作名。
    var availableIdlePlayMove: String? { idlePlayMoveProvider?() }

    /// 平台够长可踱步(两端窗口 x 跨度 > 30)。
    func platformWalkable(_ id: UUID) -> Bool {
        guard let plat = platforms.first(where: { $0.id == id }), let r = platformOriginXRange(plat) else { return false }
        return r.max - r.min > 30
    }
    /// 随机另一条平台(只有一条 → nil)。
    func randomOtherPlatformId(besides id: UUID) -> UUID? {
        guard platforms.count > 1 else { return nil }
        return platforms.filter { $0.id != id }.randomElement()?.id
    }

    func idleWalkAlongPlatform(_ id: UUID) {
        guard let plat = platforms.first(where: { $0.id == id }), let r = platformOriginXRange(plat) else { return }
        walkTargetX = CGFloat.random(in: r.min...r.max)
        transition(to: .walk)
    }
    func idleJumpToPlatform(_ id: UUID) {
        setSupport(.platform(id: id))
        transition(to: .flyingToPerch)
        bird.setViewDirection(.side)
        bird.flapWings(times: 12, fast: true)
    }
    func idleJumpOffPlatform() {
        setSupport(nil)
        bird.flapWings(times: 4, fast: true)
        vel = CGVector(dx: CGFloat.random(in: -50...50), dy: 0)
        bird.position.y = feetY
        transition(to: .falling)
    }
    /// 平台上原地小动作(5 选 1)。
    func runStandingPlatformMicro() {
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
    }
    func idleFlyUpToRandomPlatform() {
        guard let target = platforms.randomElement() else { return }
        setSupport(.platform(id: target.id))
        transition(to: .flyingToPerch)
        bird.setViewDirection(.side)
        bird.flapWings(times: 14, fast: true)
    }
    func idleWalkToGroundTarget() {
        walkTargetX = randomGroundWalkTargetX(in: currentWorld)
        transition(to: .walk)
    }

    /// 执行 IdleSelector 选出的一个 idle 行为。返回值 = 之后是否还顺带流露情绪符号
    /// (in-home 的 wander 与"脱支撑失败"会提前收尾、不再冒符号——沿用旧逻辑)。
    func runIdleMicro(_ behavior: IdleBehavior) -> Bool {
        switch behavior {
        case .wander:
            if isInHome {
                // 房间里:踱步到较远一侧(到墙折返),与窝外"偶尔走动"同一套机制。
                walkTargetX = randomGroundWalkTargetX(in: currentWorld)
                transition(to: .walk)
                return false
            }
            guard !detachFromSupportBeforeGroundRelocation(.walk) else { return false }
            let world = currentWorld
            let dx = CGFloat.random(in: -180...180)
            let target = max(world.minX, min(position.x + dx, world.maxX))
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
            setFacing(right: mouse.x > position.x + winSize.width / 2)
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
            perform(.hop)
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
        return true
    }

    /// 行为之外偶尔自发流露当下心情(大多 nil,不刷屏)。
    func showIdleManpuIfAny() {
        if let m = idleManpuProvider?() { bird.showManpu(m) }
    }

    /// 栖息时的小动作(由 PetBehaviorLoop 调度)。
    func runPerchedMicro() {
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

    /// 字符串入口(LLM 输出 / 菜单 / 语音命令 都是字符串)——解析成 Intent 后交给 perform(_:)。
    /// 学会的动作名是动态字符串,在此先查表、当 Gesture 演出(沿用旧行为:在 guard 前解析返回)。
    func perform(action: String) {
        guard state != .dragged else {
            Log.info("action", "被拖拽中，忽略 \(action)")
            return
        }
        if let move = MoveLibrary.shared.move(named: action) {
            perform(gesture: .learnedMove(move))
            return
        }
        perform(Intent(action: action))
    }

    /// **行为意图的唯一执行口**:身体在此决定可行性并分派到 Locomotion / Gesture / 生命周期。
    func perform(_ intent: Intent) {
        guard state != .dragged else {
            Log.info("action", "被拖拽中，忽略 \(intent)")
            return
        }
        if state == .sleep, intent != .sleep { wake() }
        if state == .flyingToPerch, intent != .idle {
            if supportSurface?.isChatInput == true {
                if !intent.relocatesBody {
                    queueAfterChatInputPerch(intent)
                }
                Log.info("action", "正在飞向聊天框，忽略 \(intent)")
                return
            }
            if intent.relocatesBody {
                Log.info("action", "正在飞行中，忽略位移动作 \(intent)")
                return
            }
        }
        if detachFromSupportBeforeGroundRelocation(intent) {
            return
        }
        // 意图 → 类型化执行:世界位移走 startLocomotion,局部表演走 perform(gesture:)。
        switch intent {
        case .walk:      startLocomotion(.walk)
        case .wander:    startLocomotion(.wander)
        case .approach:  startLocomotion(.approach)
        case .retreat:   startLocomotion(.retreat)
        case .goPerch:   startLocomotion(.perch)
        case .fly:       perform(gesture: .fly)
        case .settle:    perform(gesture: .settle)
        case .dance:     perform(gesture: .dance)
        case .stare:     perform(gesture: .stare)
        case .peck:      perform(gesture: .peck)
        case .groom:     perform(gesture: .groom)
        case .yawn:      perform(gesture: .yawn)
        case .nod:       perform(gesture: .nod)
        case .hop:
            // hop 的双重身份显式化:站在平台上 = 世界位移(抛物线跳);否则 = 原地表演。
            if case .platform = supportSurface { startLocomotion(.platformJump) }
            else { perform(gesture: .hop) }
        case .sleep:     sleep()
        case .wake:      wake()
        case .idle:      break
        }
    }

    // MARK: - Locomotion(世界位移)/ Gesture(局部表演)

    /// 世界位移的唯一执行口:改 position / 设 walkTarget / 走状态机。
    func startLocomotion(_ loco: Locomotion) {
        switch loco {
        case .walk:
            // 走两步:在附近小幅走动,而不是窜到世界另一头
            let world = currentWorld
            let step = CGFloat.random(in: 60...160) * (Bool.random() ? 1 : -1)
            walkTargetX = max(world.minX, min(position.x + step, world.maxX))
            transition(to: .walk)
        case .wander:
            // 大幅走动(心跳里偶尔用)
            let world = currentWorld
            walkTargetX = CGFloat.random(in: world.minX...world.maxX)
            transition(to: .walk)
        case .approach:
            let world = currentWorld
            let mouse = NSEvent.mouseLocation
            walkTargetX = max(world.minX, min(mouse.x - winSize.width / 2, world.maxX))
            transition(to: .approach)
        case .retreat:
            let world = currentWorld
            let leftDist = position.x - world.minX
            let rightDist = world.maxX - position.x
            walkTargetX = leftDist < rightDist ? world.minX : world.maxX
            transition(to: .retreat)
        case .perch:
            startPerch()
        case .platformJump:
            // 站在平台上跳:给斜向上初速,detach,转 falling 抛物线飞行(可能落到另一平台)
            let horizDir: CGFloat = Bool.random() ? 1 : -1
            vel = CGVector(dx: horizDir * 120, dy: 180)
            setSupport(nil)
            transition(to: .falling)
            bird.flapWings(times: 3, fast: true)
        }
    }

    /// 局部表演的唯一执行口:只跑 bird 节点动画,**不触碰 position**。
    /// position 的 setter 文件私有,这里结构上就拿不到世界位移能力。
    func perform(gesture: Gesture) {
        switch gesture {
        case .fly:
            flyInPlace()
        case .settle:
            settleDown()
        case .dance:
            dance()
        case .stare:
            let mouse = NSEvent.mouseLocation
            setFacing(right: mouse.x > position.x + winSize.width / 2)
            bird.tiltHead(true)
            bird.showManpu(.question)
            stateUntil = Date().addingTimeInterval(4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.bird.tiltHead(false) }
        case .peck:
            bird.setViewDirection(.front)
            bird.peckOnce()
        case .groom:
            bird.setViewDirection(.side)
            bird.groomOnce()
        case .yawn:
            bird.setViewDirection(.front)
            bird.yawnOnce()
        case .hop:
            // 地面/上沿:原地轻跳动画(不改变窗口位置)
            bird.run(.sequence([
                .moveBy(x: 0, y: 22, duration: 0.16),
                .moveBy(x: 0, y: -22, duration: 0.14),
            ]))
            bird.flapWings(times: 2, fast: true)
        case .nod:
            bird.setViewDirection(.front)
            bird.head.run(.sequence([
                .moveBy(x: 2, y: -6, duration: 0.12), .moveBy(x: -2, y: 6, duration: 0.12),
                .moveBy(x: 2, y: -6, duration: 0.12), .moveBy(x: -2, y: 6, duration: 0.12),
            ]))
        case .learnedMove(let move):
            performLearnedMove(move)
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
        setSupport(nil)               // 离开栖息面,交给重力
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
        // 离开走路态(到任何非走路态)→ 收住脚步、双脚归位站姿。
        let wasWalking = state == .walk || state == .approach || state == .retreat
        let willWalk = new == .walk || new == .approach || new == .retreat
        if wasWalking && !willWalk { bird.stopWalkCadence() }
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
            var o = position
            o.x = max(world.minX, min(o.x, world.maxX))
            o.y = world.groundY
            position = o
            commit()
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
                setSupport(.platform(id: nearest.id))
            } else {
                setSupport(.roomRim(frame: home))
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
        setSupport(.appWindow(id: target.id, frame: target.frame))
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
        setSupport(.chatInput(frame: frame))
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
            setSupport(nil)
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

        setSupport(.chatInput(frame: frame))
        if shouldFollowChatInputSurface {
            position = perchPoint(for: .chatInput(frame: frame))
            commit()
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
            let x = max(minX, min(position.x, maxX))
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

    private func queueAfterChatInputPerch(_ intent: Intent) {
        let previous = perchCompletion
        perchCompletion = { [weak self] in
            previous?()
            self?.perform(intent)
        }
    }

    private func detachFromSupportBeforeGroundRelocation(_ intent: Intent) -> Bool {
        guard supportSurface != nil, intent.startsGroundRelocation else { return false }

        perchCheckTimer?.invalidate()
        setSupport(nil)
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
        setSupport(nil)
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
        setSupport(nil)
        perchCompletion = nil
        transition(to: .dragged)
        bird.setViewDirection(.front)
        let m = NSEvent.mouseLocation
        // 记下抓取点相对窗口原点的偏移,拖拽时保持它 → 鸟跟着光标走,不在起手瞬移。
        dragGrabOffset = CGPoint(x: m.x - position.x, y: m.y - position.y)
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
        position = origin
        commit()
        dragSamples.append((loc, Date().timeIntervalSince1970))
        if dragSamples.count > 6 { dragSamples.removeFirst() }
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
            perform(.retreat)
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
