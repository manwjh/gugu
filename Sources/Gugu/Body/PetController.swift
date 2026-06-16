import AppKit
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
}

private enum SupportSurface {
    case appWindow(id: CGWindowID, frame: CGRect)
    case chatInput(frame: CGRect)

    var frame: CGRect {
        switch self {
        case .appWindow(_, let frame), .chatInput(let frame):
            return frame
        }
    }

    var isChatInput: Bool {
        if case .chatInput = self { return true }
        return false
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
    private var vel = CGVector.zero
    private var facingRight = true
    private var growthScale: CGFloat = 1
    private var walkTargetX: CGFloat?
    private var behaviorTimer: Timer?
    private var physicsTimer: Timer?
    private var supportSurface: SupportSurface?
    private var perchCompletion: (@MainActor () -> Void)?
    private var perchCheckTimer: Timer?
    private var dragSamples: [(p: CGPoint, t: TimeInterval)] = []
    private var stateUntil: Date = .distantPast
    private var fallFromDrag = false          // distinguishes owner-throw from perch-fall
    private var lastPerchAttempt = Date.distantPast

    var onPoke: (() -> Void)?
    var onPet: (() -> Void)?
    var onThrown: (() -> Void)?
    var onStateChange: ((PetBodyState) -> Void)?
    var menuProvider: (() -> NSMenu)?
    var speechAvoidanceFrame: CGRect?

    private let winSize = CGSize(width: 150, height: 150)
    /// Bird's feet y-offset inside the scene.
    private let feetY: CGFloat = 12

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

    private var isOnGround: Bool {
        abs(window.frame.origin.y - groundY(for: screen)) < 2
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
        let scr = screen

        switch state {
        case .falling:
            vel.dy -= 2400 * dt          // gravity
            vel.dx *= 0.995
            origin.x += vel.dx * dt
            origin.y += vel.dy * dt
            let gy = groundY(for: scr)
            if origin.y <= gy {
                origin.y = gy
                land()
            }
            // wall bounce
            if origin.x < scr.visibleFrame.minX { origin.x = scr.visibleFrame.minX; vel.dx = abs(vel.dx) * 0.5 }
            if origin.x > scr.visibleFrame.maxX - winSize.width {
                origin.x = scr.visibleFrame.maxX - winSize.width; vel.dx = -abs(vel.dx) * 0.5
            }
            window.setFrameOrigin(origin)

        case .walk, .approach, .retreat:
            guard let target = walkTargetX else { transition(to: .idle); return }
            let speed: CGFloat = state == .retreat ? 160 : 90
            let dir: CGFloat = target > origin.x ? 1 : -1
            setFacing(right: dir > 0)
            origin.x += dir * speed * dt
            // gentle hop bob
            bird.position.y = feetY + abs(sin(Date().timeIntervalSince1970 * 10)) * 3
            if abs(origin.x - target) < 8 {
                walkTargetX = nil
                bird.position.y = feetY
                transition(to: .idle)
            }
            origin.x = max(scr.visibleFrame.minX, min(origin.x, scr.visibleFrame.maxX - winSize.width))
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

        default:
            break
        }

        bubble.follow(petWindow: window, avoiding: speechAvoidanceFrame)
    }

    private func land() {
        let hard = abs(vel.dx) > 300 || vel.dy < -900
        vel = .zero
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
            if fallFromDrag { onThrown?() }
            transition(to: .idle)
        } else {
            bird.yScale = 0.85
            bird.run(.scaleY(to: 1.0, duration: 0.2))
            transition(to: .idle)
        }
        fallFromDrag = false
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
        let roll = Double.random(in: 0...1)
        switch roll {
        case ..<0.35:
            guard !detachFromSupportBeforeGroundRelocation(action: "walk") else { return }
            // small wander
            let scr = screen.visibleFrame
            let dx = CGFloat.random(in: -180...180)
            let target = max(scr.minX, min(window.frame.origin.x + dx, scr.maxX - winSize.width))
            walkTargetX = target
            transition(to: .walk)
        case ..<0.5:
            bird.setViewDirection(.side)
            bird.groomOnce()
        case ..<0.62:
            bird.setViewDirection(.front)
            bird.peckOnce()
        case ..<0.68:
            bird.setViewDirection(.front)
            bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.bird.tiltHead(false) }
        case ..<0.72:
            // glance toward cursor
            let mouse = NSEvent.mouseLocation
            setFacing(right: mouse.x > window.frame.midX)
            bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bird.tiltHead(false) }
        case ..<0.8:
            bird.setViewDirection(.front)
            bird.flapWings(times: 2)
        default:
            break // just stand there, being a bird
        }
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
        guard state != .dragged else { return }
        if state == .sleep && action != "sleep" { wake() }
        if state == .flyingToPerch, action != "idle" {
            if supportSurface?.isChatInput == true {
                if canPerformAfterChatInputPerch(action) {
                    queueActionAfterChatInputPerch(action)
                }
                return
            }
            if relocatesBody(action) { return }
        }
        if detachFromSupportBeforeGroundRelocation(action: action) {
            return
        }
        switch action {
        case "walk":
            // 走两步:在附近小幅走动,而不是窜到屏幕另一头
            let scr = screen.visibleFrame
            let step = CGFloat.random(in: 60...160) * (Bool.random() ? 1 : -1)
            walkTargetX = max(scr.minX, min(window.frame.origin.x + step, scr.maxX - winSize.width))
            transition(to: .walk)
        case "wander":
            // 大幅走动(心跳里偶尔用)
            let scr = screen.visibleFrame
            walkTargetX = CGFloat.random(in: scr.minX...(scr.maxX - winSize.width))
            transition(to: .walk)
        case "approach", "come":
            let mouse = NSEvent.mouseLocation
            walkTargetX = max(screen.visibleFrame.minX,
                              min(mouse.x - winSize.width / 2, screen.visibleFrame.maxX - winSize.width))
            transition(to: .approach)
        case "retreat", "away":
            let scr = screen.visibleFrame
            let leftDist = window.frame.origin.x - scr.minX
            let rightDist = scr.maxX - window.frame.origin.x
            walkTargetX = leftDist < rightDist ? scr.minX + 8 : scr.maxX - winSize.width - 8
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

    private func transition(to new: PetBodyState) {
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
        say("我好像长大了一点。")
    }

    private func dance() {
        stateUntil = Date().addingTimeInterval(3)
        bird.setViewDirection(.front)
        bird.flapWings(times: 8, fast: true)
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
        transition(to: .idle)
    }

    var isSleeping: Bool { state == .sleep }

    // MARK: - Perch on frontmost window

    private func startPerch() {
        // don't thrash: at most one perch attempt per 30s
        guard Date().timeIntervalSince(lastPerchAttempt) > 30 else { return }
        guard let target = PetController.frontmostWindowInfo() else { return }
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
        // Surface frames are in AppKit coords (bottom-left origin).
        let frame = surface.frame
        let x = max(frame.minX, min(frame.midX - winSize.width / 2, frame.maxX - winSize.width))
        let y = surface.isChatInput ? frame.maxY - feetY + 4 : frame.maxY - feetY - 2
        return CGPoint(x: x, y: y)
    }

    private func becomePerched() {
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

    /// Frontmost normal window of another app, in AppKit coordinates.
    static func frontmostWindowInfo() -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let w = boundsDict["Width"] ?? 0, h = boundsDict["Height"] ?? 0
            guard w > 250, h > 150 else { continue }
            let cgX = boundsDict["X"] ?? 0, cgY = boundsDict["Y"] ?? 0
            // CG top-left origin → AppKit bottom-left origin
            let akFrame = CGRect(x: cgX, y: primaryHeight - cgY - h, width: w, height: h)
            guard let num = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (num, akFrame)
        }
        return nil
    }

    static func windowInfo(for id: CGWindowID) -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let w = boundsDict["Width"] ?? 0, h = boundsDict["Height"] ?? 0
        let cgX = boundsDict["X"] ?? 0, cgY = boundsDict["Y"] ?? 0
        return (id, CGRect(x: cgX, y: primaryHeight - cgY - h, width: w, height: h))
    }

    // MARK: - Dragging

    func dragBegan() {
        if state == .sleep { wake() }
        perchCheckTimer?.invalidate()
        supportSurface = nil
        perchCompletion = nil
        transition(to: .dragged)
        bird.setViewDirection(.front)
        dragSamples = [(NSEvent.mouseLocation, Date().timeIntervalSince1970)]
        bird.setEyesClosed(false)
        // struggle wiggle
        bird.run(.repeatForever(.sequence([
            .rotate(toAngle: 0.2, duration: 0.1),
            .rotate(toAngle: -0.2, duration: 0.1),
        ])), withKey: "struggle")
        bird.flapWings(times: 30, fast: true)
    }

    func dragMoved(to loc: CGPoint) {
        window.setFrameOrigin(CGPoint(x: loc.x - winSize.width / 2, y: loc.y - winSize.height / 2 - 20))
        dragSamples.append((loc, Date().timeIntervalSince1970))
        if dragSamples.count > 6 { dragSamples.removeFirst() }
        bubble.follow(petWindow: window)
    }

    func dragEnded() {
        bird.removeAction(forKey: "struggle")
        bird.zRotation = 0
        fallFromDrag = true
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
        bird.peckOnce()
        bird.run(.sequence([
            .moveBy(x: 0, y: 10, duration: 0.1),
            .moveBy(x: 0, y: -10, duration: 0.12),
        ]))
        onPoke?()
    }

    func petted() {
        if state == .sleep { wake() }
        bird.setViewDirection(.front)
        bird.showBlush(true)
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

/// Floating rounded speech bubble in its own panel, follows the pet.
@MainActor
final class SpeechBubble {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let container = BubbleShapeView()
    private var hideTask: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        container.addSubview(label)
        panel.contentView = container
    }

    func show(text: String, near petWindow: NSWindow, avoiding avoidanceFrame: CGRect? = nil) {
        hideTask?.cancel()
        label.stringValue = text
        let maxWidth: CGFloat = 220
        let size = label.sizeThatFits(NSSize(width: maxWidth, height: 600))
        let padX: CGFloat = 16
        let padY: CGFloat = 14
        let tailSpace: CGFloat = 14
        let w = min(maxWidth, size.width) + padX * 2 + tailSpace * 2
        let h = size.height + padY * 2 + tailSpace * 2
        label.frame = CGRect(x: padX + tailSpace,
                             y: padY + tailSpace,
                             width: w - (padX + tailSpace) * 2,
                             height: h - (padY + tailSpace) * 2)
        container.frame = CGRect(x: 0, y: 0, width: w, height: h)
        panel.setContentSize(NSSize(width: w, height: h))
        position(relativeTo: petWindow, avoiding: avoidanceFrame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        // Duration scales with reading time; keep it long enough for relaxed desktop reading.
        let dur = min(24.0, max(6.0, Double(text.count) * 0.34))
        let task = DispatchWorkItem { [weak self] in self?.hide() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: task)
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func position(relativeTo petWindow: NSWindow, avoiding avoidanceFrame: CGRect? = nil) {
        let pf = petWindow.frame
        // The transparent pet window is taller than the drawn bird. Anchor the
        // bubble to the bird's visual head, not to the window top.
        let birdHeadTop = pf.minY + 72
        let anchor = CGPoint(x: pf.midX, y: birdHeadTop)
        let tipInset: CGFloat = 4
        let base = CGRect(x: anchor.x - panel.frame.width / 2,
                          y: anchor.y - tipInset,
                          width: panel.frame.width,
                          height: panel.frame.height)
        var chosen = base
        if let scr = NSScreen.screens.first(where: { $0.frame.intersects(pf) }) ?? NSScreen.main {
            let visible = scr.visibleFrame.insetBy(dx: 4, dy: 4)
            let gap: CGFloat = 8
            let avoidance = avoidanceFrame?.insetBy(dx: -gap, dy: -gap)
            let sideY = anchor.y - panel.frame.height / 2
            let left = CGRect(x: anchor.x - panel.frame.width + tipInset,
                              y: sideY,
                              width: panel.frame.width,
                              height: panel.frame.height)
            let right = CGRect(x: anchor.x - tipInset,
                               y: sideY,
                               width: panel.frame.width,
                               height: panel.frame.height)
            let below = CGRect(x: anchor.x - panel.frame.width / 2,
                               y: anchor.y - panel.frame.height + tipInset,
                               width: panel.frame.width,
                               height: panel.frame.height)
            var candidates = [base]
            if let avoidance {
                let sideFirst = avoidance.midX >= anchor.x ? [left, right] : [right, left]
                candidates += sideFirst + [
                    CGRect(x: base.minX,
                           y: avoidance.maxY + gap,
                           width: panel.frame.width,
                           height: panel.frame.height),
                    below,
                    CGRect(x: base.minX,
                           y: avoidance.minY - panel.frame.height - gap,
                           width: panel.frame.width,
                           height: panel.frame.height),
                ]
            }
            if base.maxY > visible.maxY {
                candidates.append(below)
            }
            chosen = candidates
                .map { clamped($0, to: visible) }
                .first { frame in
                    guard let avoidance else { return true }
                    return !frame.intersects(avoidance)
                } ?? clamped(base, to: visible)
        }
        panel.setFrameOrigin(chosen.origin)
        let rawTip = panel.convertFromScreen(NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1)).origin
        container.tailTip = CGPoint(x: max(3, min(rawTip.x, panel.frame.width - 3)),
                                    y: max(3, min(rawTip.y, panel.frame.height - 3)))
    }

    func follow(petWindow: NSWindow) {
        guard panel.isVisible else { return }
        position(relativeTo: petWindow)
    }

    func follow(petWindow: NSWindow, avoiding avoidanceFrame: CGRect?) {
        guard panel.isVisible else { return }
        position(relativeTo: petWindow, avoiding: avoidanceFrame)
    }

    private func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        let y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }
}

@MainActor
private final class BubbleShapeView: NSView {
    var tailTip: CGPoint = .zero {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tailSpace: CGFloat = 14
        let body = bounds.insetBy(dx: tailSpace + 0.5, dy: tailSpace + 0.5)
        let corner: CGFloat = 13
        let tailWidth: CGFloat = 18
        let attachX = max(body.minX + corner + tailWidth / 2,
                          min(tailTip.x, body.maxX - corner - tailWidth / 2))
        let attachY = max(body.minY + corner + tailWidth / 2,
                          min(tailTip.y, body.maxY - corner - tailWidth / 2))

        let bodyPath = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
        let tail = NSBezierPath()
        let tailStart: CGPoint
        let tailEnd: CGPoint
        switch nearestEdge(to: tailTip, in: body) {
        case .bottom:
            tailStart = CGPoint(x: attachX - tailWidth / 2, y: body.minY + 1)
            tailEnd = CGPoint(x: attachX + tailWidth / 2, y: body.minY + 1)
        case .top:
            tailStart = CGPoint(x: attachX - tailWidth / 2, y: body.maxY - 1)
            tailEnd = CGPoint(x: attachX + tailWidth / 2, y: body.maxY - 1)
        case .left:
            tailStart = CGPoint(x: body.minX + 1, y: attachY - tailWidth / 2)
            tailEnd = CGPoint(x: body.minX + 1, y: attachY + tailWidth / 2)
        case .right:
            tailStart = CGPoint(x: body.maxX - 1, y: attachY - tailWidth / 2)
            tailEnd = CGPoint(x: body.maxX - 1, y: attachY + tailWidth / 2)
        }
        tail.move(to: tailStart)
        tail.line(to: tailTip)
        tail.line(to: tailEnd)
        tail.close()

        let fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.97)
        let strokeColor = NSColor(calibratedWhite: 0.3, alpha: 0.24)
        fillColor.setFill()
        bodyPath.fill()
        tail.fill()

        strokeColor.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        // Re-fill the tail after stroking the rounded body so the join has no inner seam.
        fillColor.setFill()
        tail.fill()
        let tailStroke = NSBezierPath()
        tailStroke.move(to: tailStart)
        tailStroke.line(to: tailTip)
        tailStroke.line(to: tailEnd)
        strokeColor.setStroke()
        tailStroke.lineWidth = 1
        tailStroke.stroke()
    }

    private enum Edge { case top, bottom, left, right }

    private func nearestEdge(to point: CGPoint, in rect: CGRect) -> Edge {
        let distances: [(Edge, CGFloat)] = [
            (.bottom, abs(point.y - rect.minY)),
            (.top, abs(point.y - rect.maxY)),
            (.left, abs(point.x - rect.minX)),
            (.right, abs(point.x - rect.maxX)),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }
}
