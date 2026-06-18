import SpriteKit

enum BirdViewDirection: Equatable {
    case front
    case back
    case side
}

/// 漫符(manpu):漫画式情绪符号,在头顶临时弹出表达情绪。纯矢量绘制以贴合手绘画风。
enum Manpu {
    case sweat      // 汗滴:尴尬 / 疲惫 / 无奈
    case anger      // 青筋(💢):生气 / 不爽
    case surprise   // 惊叹号:吃惊 / 被戳一跳
    case love       // 心:开心 / 被宠
    case music      // 音符:哼唱 / 跳舞 / 高兴
    case question   // 问号:困惑 / 好奇
    case dizzy      // 螺旋:被戳晕 / 眩晕

    /// 头顶/脸颊侧的默认锚点(BirdNode 本地坐标,和 zzz 同区域)。
    var defaultAnchor: CGPoint {
        switch self {
        case .sweat:    return CGPoint(x: 15, y: 30)   // 脸颊侧滑落
        case .anger:    return CGPoint(x: 16, y: 44)
        case .surprise: return CGPoint(x: 14, y: 46)
        case .love:     return CGPoint(x: 12, y: 42)
        case .music:    return CGPoint(x: 16, y: 44)
        case .question: return CGPoint(x: 15, y: 46)
        case .dizzy:    return CGPoint(x: 4, y: 48)     // 头顶正上方转圈
        }
    }

    /// 入场时的轻微倾斜,让符号更活泼。
    var tilt: CGFloat {
        switch self {
        case .surprise: return 0.12
        case .love:     return -0.1
        case .music:    return 0.1
        case .question: return 0.08
        default:        return 0
        }
    }
}

struct BirdAppearanceDebug {
    let direction: BirdViewDirection
    let visibleEyes: Int
    let beakVisible: Bool
    let bellyVisible: Bool
    let backDetailsVisible: Bool
    let closedEyeMarksVisible: Int
    let sleepZVisible: Bool
}

/// Procedurally drawn bird. No art assets — everything is SKShapeNode.
/// The node tree exposes parts so animations can move them independently.
final class BirdNode: SKNode {
    let body = SKShapeNode()
    let belly = SKShapeNode()
    let head = SKNode()
    let eyeL = SKShapeNode(circleOfRadius: 3.4)
    let eyeR = SKShapeNode(circleOfRadius: 3.4)
    let eyelidL = SKShapeNode()
    let eyelidR = SKShapeNode()
    let beak = SKShapeNode()
    let wingL = SKShapeNode()
    let wingR = SKShapeNode()
    let footL = SKShapeNode()
    let footR = SKShapeNode()
    let tail = SKShapeNode()
    let blushL = SKShapeNode(circleOfRadius: 3)
    let blushR = SKShapeNode(circleOfRadius: 3)
    let zzz = SKLabelNode(text: "z")
    /// 漫符层:情绪符号(汗滴/青筋/惊叹/心)的临时覆盖,与身体解耦。
    let manpu = SKNode()
    private let crest = SKShapeNode()
    private let backPatch = SKShapeNode()
    private let backStripe = SKShapeNode()
    private let aura = SKShapeNode(circleOfRadius: 33)
    private var baseScale: CGFloat = 1.0
    private var currentStage: GrowthStage = .hatchling
    private var eyesClosed = false
    private(set) var viewDirection: BirdViewDirection = .front

    /// Bird faces right by default in side view; flip via xScale on the whole node.
    override init() {
        super.init()
        buildShapes()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildShapes() {
        let feather = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.35, alpha: 1)   // warm yellow
        let featherDark = NSColor(calibratedRed: 0.86, green: 0.62, blue: 0.2, alpha: 1)
        let bellyColor = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.82, alpha: 1)
        let beakColor = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.25, alpha: 1)
        let footColor = NSColor(calibratedRed: 0.9, green: 0.55, blue: 0.3, alpha: 1)

        // tail (behind body)
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: 0, y: 0))
        tailPath.addQuadCurve(to: CGPoint(x: -16, y: 10), control: CGPoint(x: -12, y: -2))
        tailPath.addQuadCurve(to: CGPoint(x: -14, y: 2), control: CGPoint(x: -14, y: 6))
        tailPath.closeSubpath()
        tail.path = tailPath
        tail.fillColor = featherDark
        tail.strokeColor = .clear
        tail.position = CGPoint(x: -14, y: 14)
        tail.zPosition = 0
        addChild(tail)

        // body: plump ellipse
        body.path = CGPath(ellipseIn: CGRect(x: -18, y: 0, width: 38, height: 34), transform: nil)
        body.fillColor = feather
        body.strokeColor = NSColor(calibratedWhite: 0.25, alpha: 0.9)
        body.lineWidth = 1.6
        body.zPosition = 1
        addChild(body)

        // belly patch
        belly.path = CGPath(ellipseIn: CGRect(x: -8, y: 1.5, width: 24, height: 20), transform: nil)
        belly.fillColor = bellyColor
        belly.strokeColor = .clear
        belly.zPosition = 2
        addChild(belly)

        backPatch.path = backPatchPath()
        backPatch.fillColor = featherDark.withAlphaComponent(0.22)
        backPatch.strokeColor = .clear
        backPatch.alpha = 0
        backPatch.zPosition = 2.05
        addChild(backPatch)

        backStripe.path = backStripePath()
        backStripe.fillColor = .clear
        backStripe.strokeColor = featherDark.withAlphaComponent(0.58)
        backStripe.lineWidth = 1.5
        backStripe.lineCap = .round
        backStripe.alpha = 0
        backStripe.zPosition = 2.25
        addChild(backStripe)

        // head group sits on upper-front of the body
        head.position = CGPoint(x: 6, y: 26)
        head.zPosition = 3
        addChild(head)

        crest.path = crestPath(width: 9, height: 9)
        crest.fillColor = featherDark
        crest.strokeColor = NSColor(calibratedWhite: 0.25, alpha: 0.7)
        crest.lineWidth = 0.8
        crest.alpha = 0
        crest.zPosition = -0.2
        head.addChild(crest)

        // eyes
        eyeL.fillColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        eyeL.strokeColor = .clear
        eyeL.position = CGPoint(x: 2, y: 2)
        head.addChild(eyeL)
        eyeR.fillColor = eyeL.fillColor
        eyeR.strokeColor = .clear
        eyeR.position = CGPoint(x: 11, y: 2)
        head.addChild(eyeR)
        // eye glints
        for eye in [eyeL, eyeR] {
            let glint = SKShapeNode(circleOfRadius: 1.1)
            glint.fillColor = .white
            glint.strokeColor = .clear
            glint.position = CGPoint(x: 1, y: 1.2)
            eye.addChild(glint)
        }
        // Closed eyes are drawn as simple arcs. Filled lids read like glasses at desktop scale.
        for (lid, eye) in [(eyelidL, eyeL), (eyelidR, eyeR)] {
            lid.path = closedEyePath(width: 7.2)
            lid.fillColor = .clear
            lid.strokeColor = NSColor(calibratedWhite: 0.22, alpha: 0.72)
            lid.lineWidth = 1.45
            lid.lineCap = .round
            lid.position = eye.position
            lid.alpha = 0
            lid.zPosition = 2
            head.addChild(lid)
        }

        // beak: small triangle pointing right
        let beakPath = CGMutablePath()
        beakPath.move(to: CGPoint(x: 0, y: 3))
        beakPath.addLine(to: CGPoint(x: 9, y: -0.5))
        beakPath.addLine(to: CGPoint(x: 0, y: -3.5))
        beakPath.closeSubpath()
        beak.path = beakPath
        beak.fillColor = beakColor
        beak.strokeColor = NSColor(calibratedWhite: 0.25, alpha: 0.7)
        beak.lineWidth = 1
        beak.position = CGPoint(x: 15, y: -1)
        head.addChild(beak)

        // blush (hidden by default, shows when petted)
        for (blush, x) in [(blushL, CGFloat(-3)), (blushR, CGFloat(14))] {
            blush.fillColor = NSColor(calibratedRed: 1, green: 0.6, blue: 0.55, alpha: 0.55)
            blush.strokeColor = .clear
            blush.position = CGPoint(x: x, y: -4)
            blush.alpha = 0
            head.addChild(blush)
        }

        // wings
        let wingPath = CGMutablePath()
        wingPath.move(to: CGPoint(x: 0, y: 0))
        wingPath.addQuadCurve(to: CGPoint(x: -4, y: -14), control: CGPoint(x: -10, y: -6))
        wingPath.addQuadCurve(to: CGPoint(x: 4, y: -2), control: CGPoint(x: 4, y: -10))
        wingPath.closeSubpath()
        wingL.path = wingPath
        wingL.fillColor = featherDark
        wingL.strokeColor = .clear
        wingL.position = CGPoint(x: -8, y: 22)
        wingL.zPosition = 2.5
        addChild(wingL)
        wingR.path = wingPath
        wingR.fillColor = featherDark.withAlphaComponent(0.8)
        wingR.strokeColor = .clear
        wingR.position = CGPoint(x: 2, y: 22)
        wingR.zPosition = 0.5
        addChild(wingR)

        // feet
        for (foot, x) in [(footL, CGFloat(-6)), (footR, CGFloat(6))] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 4))
            p.addLine(to: CGPoint(x: 0, y: -3))
            p.move(to: CGPoint(x: -3, y: -4))
            p.addLine(to: CGPoint(x: 0, y: -3))
            p.addLine(to: CGPoint(x: 3, y: -4))
            foot.path = p
            foot.strokeColor = footColor
            foot.lineWidth = 2
            foot.lineCap = .round
            foot.position = CGPoint(x: x, y: 0)
            foot.zPosition = 0.8
            addChild(foot)
        }

        // zzz label for sleep
        zzz.fontName = "Helvetica-Bold"
        zzz.fontSize = 13
        zzz.fontColor = NSColor(calibratedWhite: 0.4, alpha: 0.9)
        zzz.position = CGPoint(x: 18, y: 38)
        zzz.alpha = 0
        zzz.zPosition = 5
        addChild(zzz)

        // 漫符层:在最上层,符号即时生成又即时移除,不预建。
        manpu.zPosition = 6
        addChild(manpu)

        aura.fillColor = .clear
        aura.strokeColor = NSColor.systemTeal.withAlphaComponent(0.28)
        aura.lineWidth = 2
        aura.alpha = 0
        aura.zPosition = -2
        aura.position = CGPoint(x: 2, y: 22)
        addChild(aura)
        setViewDirection(.front, animated: false)
    }

    func apply(stage: GrowthStage) {
        currentStage = stage
        baseScale = stage.visualScale
        setScale(baseScale)

        crest.removeAllActions()
        aura.removeAllActions()
        switch stage {
        case .hatchling:
            body.fillColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.42, alpha: 1)
            wingL.alpha = 0.72
            wingR.alpha = 0.55
            tail.xScale = 0.65
            tail.yScale = 0.75
            crest.alpha = 0
            aura.alpha = 0
        case .fledgling:
            body.fillColor = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.35, alpha: 1)
            wingL.alpha = 0.9
            wingR.alpha = 0.72
            tail.xScale = 0.85
            tail.yScale = 0.9
            crest.alpha = 0.45
            aura.alpha = 0
        case .adult:
            body.fillColor = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.35, alpha: 1)
            wingL.alpha = 1
            wingR.alpha = 0.8
            tail.xScale = 1
            tail.yScale = 1
            crest.alpha = 0.85
            aura.alpha = 0
        case .spirit:
            body.fillColor = NSColor(calibratedRed: 0.92, green: 0.82, blue: 0.48, alpha: 1)
            wingL.alpha = 1
            wingR.alpha = 0.86
            tail.xScale = 1.08
            tail.yScale = 1.05
            crest.alpha = 1
            aura.alpha = 0.45
            aura.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.18, duration: 1.2),
                .fadeAlpha(to: 0.48, duration: 1.2),
            ])), withKey: "aura")
        }
        setViewDirection(viewDirection, animated: false)
    }

    func setViewDirection(_ direction: BirdViewDirection, animated: Bool = true) {
        viewDirection = direction
        let duration = animated ? 0.18 : 0
        switch direction {
        case .side:
            applySideView(duration: duration)
        case .front:
            applyFrontView(duration: duration)
        case .back:
            applyBackView(duration: duration)
        }
    }

    private func applySideView(duration: TimeInterval) {
        body.path = CGPath(ellipseIn: CGRect(x: -18, y: 0, width: 38, height: 34), transform: nil)
        belly.path = CGPath(ellipseIn: CGRect(x: -8, y: 1.5, width: 24, height: 20), transform: nil)
        belly.alpha = 1
        backPatch.alpha = 0
        backStripe.alpha = 0
        move(head, to: CGPoint(x: 6, y: 26), duration: duration)
        rotate(head, to: 0, duration: duration)
        move(eyeL, to: CGPoint(x: 2, y: 2), duration: duration)
        move(eyeR, to: CGPoint(x: 8, y: 2.2), duration: duration)
        eyeL.setScale(0.9)
        eyeR.setScale(1.02)
        move(eyelidL, to: CGPoint(x: 2, y: 2), duration: duration)
        move(eyelidR, to: CGPoint(x: 8, y: 2.2), duration: duration)
        beak.path = sideBeakPath()
        move(beak, to: CGPoint(x: 14, y: -0.6), duration: duration)
        beak.setScale(1)
        beak.alpha = 1
        crest.path = crestPath(width: 8, height: 8)
        move(crest, to: CGPoint(x: 0, y: -1), duration: duration)
        wingL.path = sideWingPath()
        wingR.path = sideWingPath()
        wingL.xScale = 1
        wingR.xScale = 0.72
        move(wingL, to: CGPoint(x: -8, y: 22), duration: duration)
        move(wingR, to: CGPoint(x: 2, y: 22), duration: duration)
        rotate(wingL, to: -0.05, duration: duration)
        rotate(wingR, to: -0.04, duration: duration)
        wingL.zPosition = 2.5
        wingR.zPosition = 0.5
        tail.path = sideTailPath()
        move(tail, to: CGPoint(x: -14, y: 14), duration: duration)
        rotate(tail, to: 0, duration: duration)
        tail.zPosition = 0
        move(footL, to: CGPoint(x: -6, y: 0), duration: duration)
        move(footR, to: CGPoint(x: 6, y: 0), duration: duration)
        move(blushL, to: CGPoint(x: -3, y: -4), duration: duration)
        move(blushR, to: CGPoint(x: 14, y: -4), duration: duration)
        applyStageWingAlpha(sideView: true)
        applyEyeClosure(animated: false)
    }

    private func applyFrontView(duration: TimeInterval) {
        body.path = CGPath(ellipseIn: CGRect(x: -20, y: 0, width: 40, height: 35), transform: nil)
        belly.path = CGPath(ellipseIn: CGRect(x: -12, y: 2, width: 24, height: 20), transform: nil)
        belly.alpha = 1
        backPatch.alpha = 0
        backStripe.alpha = 0
        move(head, to: CGPoint(x: 0, y: 27), duration: duration)
        rotate(head, to: 0, duration: duration)
        move(eyeL, to: CGPoint(x: -6.5, y: 2.2), duration: duration)
        move(eyeR, to: CGPoint(x: 6.5, y: 2.2), duration: duration)
        eyeL.setScale(0.92)
        eyeR.setScale(0.92)
        move(eyelidL, to: CGPoint(x: -6.5, y: 2.2), duration: duration)
        move(eyelidR, to: CGPoint(x: 6.5, y: 2.2), duration: duration)
        beak.path = frontBeakPath()
        move(beak, to: CGPoint(x: 0, y: -3.2), duration: duration)
        beak.setScale(1)
        beak.alpha = 1
        crest.path = crestPath(width: 10, height: 8)
        move(crest, to: CGPoint(x: -5, y: 0), duration: duration)
        wingL.path = frontWingPath()
        wingR.path = frontWingPath()
        wingL.xScale = 1
        wingR.xScale = -1
        move(wingL, to: CGPoint(x: -17, y: 22), duration: duration)
        move(wingR, to: CGPoint(x: 17, y: 22), duration: duration)
        wingL.zPosition = 0.85
        wingR.zPosition = 0.85
        rotate(wingL, to: -0.14, duration: duration)
        rotate(wingR, to: 0.14, duration: duration)
        tail.path = backTailPath()
        move(tail, to: CGPoint(x: 0, y: 7), duration: duration)
        rotate(tail, to: 0, duration: duration)
        tail.zPosition = -0.5
        move(footL, to: CGPoint(x: -7, y: 0), duration: duration)
        move(footR, to: CGPoint(x: 7, y: 0), duration: duration)
        move(blushL, to: CGPoint(x: -10, y: -4), duration: duration)
        move(blushR, to: CGPoint(x: 10, y: -4), duration: duration)
        applyStageWingAlpha(sideView: false)
        applyEyeClosure(animated: false)
    }

    private func applyBackView(duration: TimeInterval) {
        body.path = CGPath(ellipseIn: CGRect(x: -20, y: 0, width: 40, height: 35), transform: nil)
        belly.alpha = 0
        backPatch.path = backPatchPath()
        backPatch.alpha = 1
        backStripe.path = backStripePath()
        backStripe.alpha = 1
        move(head, to: CGPoint(x: 0, y: 27), duration: duration)
        rotate(head, to: 0, duration: duration)
        eyeL.alpha = 0
        eyeR.alpha = 0
        eyelidL.alpha = 0
        eyelidR.alpha = 0
        beak.alpha = 0
        crest.path = crestPath(width: 11, height: 7)
        move(crest, to: CGPoint(x: -5.5, y: -1), duration: duration)
        wingL.path = backWingPath()
        wingR.path = backWingPath()
        wingL.xScale = 1
        wingR.xScale = -1
        move(wingL, to: CGPoint(x: -15, y: 23), duration: duration)
        move(wingR, to: CGPoint(x: 15, y: 23), duration: duration)
        wingL.zPosition = 1.9
        wingR.zPosition = 1.9
        rotate(wingL, to: -0.05, duration: duration)
        rotate(wingR, to: 0.05, duration: duration)
        tail.path = backTailPath()
        move(tail, to: CGPoint(x: 0, y: 3), duration: duration)
        rotate(tail, to: 0, duration: duration)
        tail.zPosition = 0.35
        move(footL, to: CGPoint(x: -7, y: 0), duration: duration)
        move(footR, to: CGPoint(x: 7, y: 0), duration: duration)
        blushL.alpha = 0
        blushR.alpha = 0
        applyStageWingAlpha(sideView: false)
        applyEyeClosure(animated: false)
    }

    private func move(_ node: SKNode, to point: CGPoint, duration: TimeInterval) {
        if duration <= 0 {
            node.position = point
        } else {
            node.run(.move(to: point, duration: duration))
        }
    }

    private func rotate(_ node: SKNode, to angle: CGFloat, duration: TimeInterval) {
        if duration <= 0 {
            node.zRotation = angle
        } else {
            node.run(.rotate(toAngle: angle, duration: duration))
        }
    }

    private func closedEyePath(width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -width / 2, y: 0))
        path.addQuadCurve(to: CGPoint(x: width / 2, y: 0),
                          control: CGPoint(x: 0, y: -2.2))
        return path
    }

    private func sideTailPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: -16, y: 10), control: CGPoint(x: -12, y: -2))
        path.addQuadCurve(to: CGPoint(x: -14, y: 2), control: CGPoint(x: -14, y: 6))
        path.closeSubpath()
        return path
    }

    private func backTailPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -11, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: -12), control: CGPoint(x: -7, y: -8))
        path.addQuadCurve(to: CGPoint(x: 11, y: 0), control: CGPoint(x: 7, y: -8))
        path.addQuadCurve(to: CGPoint(x: 0, y: 5), control: CGPoint(x: 7, y: 3))
        path.addQuadCurve(to: CGPoint(x: -11, y: 0), control: CGPoint(x: -7, y: 3))
        path.closeSubpath()
        return path
    }

    private func sideWingPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: -4, y: -14), control: CGPoint(x: -10, y: -6))
        path.addQuadCurve(to: CGPoint(x: 4, y: -2), control: CGPoint(x: 4, y: -10))
        path.closeSubpath()
        return path
    }

    private func frontWingPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 0))
        path.addCurve(to: CGPoint(x: -12, y: -9), control1: CGPoint(x: -5, y: -1), control2: CGPoint(x: -11, y: -4))
        path.addCurve(to: CGPoint(x: -6, y: -21), control1: CGPoint(x: -14, y: -14), control2: CGPoint(x: -10, y: -19))
        path.addCurve(to: CGPoint(x: 5, y: -5), control1: CGPoint(x: 1, y: -18), control2: CGPoint(x: 4, y: -10))
        path.closeSubpath()
        return path
    }

    private func backWingPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(to: CGPoint(x: -13, y: -8), control1: CGPoint(x: -6, y: -1), control2: CGPoint(x: -12, y: -4))
        path.addCurve(to: CGPoint(x: -7, y: -22), control1: CGPoint(x: -15, y: -15), control2: CGPoint(x: -11, y: -20))
        path.addCurve(to: CGPoint(x: 5, y: -5), control1: CGPoint(x: -1, y: -19), control2: CGPoint(x: 3, y: -11))
        path.closeSubpath()
        return path
    }

    private func applyStageWingAlpha(sideView: Bool) {
        let primary: CGFloat
        let secondary: CGFloat
        switch currentStage {
        case .hatchling:
            primary = 0.72
            secondary = 0.55
        case .fledgling:
            primary = 0.9
            secondary = 0.72
        case .adult:
            primary = 1
            secondary = 0.8
        case .spirit:
            primary = 1
            secondary = 0.86
        }
        wingL.alpha = primary
        wingR.alpha = sideView ? secondary : primary
    }

    private func visibleEyeTargets() -> [(eye: SKShapeNode, lid: SKShapeNode)] {
        switch viewDirection {
        case .front:
            return [(eyeL, eyelidL), (eyeR, eyelidR)]
        case .side:
            return [(eyeR, eyelidR)]
        case .back:
            return []
        }
    }

    private func applyEyeClosure(animated: Bool) {
        let visiblePairs = visibleEyeTargets()
        for pair in [(eyeL, eyelidL), (eyeR, eyelidR)] {
            let visible = visiblePairs.contains { $0.eye === pair.0 }
            setAlpha(pair.0, to: visible && !eyesClosed ? 1 : 0, animated: animated)
            setAlpha(pair.1, to: visible && eyesClosed ? 1 : 0, animated: animated)
        }
    }

    private func setAlpha(_ node: SKNode, to alpha: CGFloat, animated: Bool) {
        node.removeAction(forKey: "alpha")
        if animated {
            node.run(.fadeAlpha(to: alpha, duration: 0.14), withKey: "alpha")
        } else {
            node.alpha = alpha
        }
    }

    private func sideBeakPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 2.8))
        path.addQuadCurve(to: CGPoint(x: 8, y: -0.4), control: CGPoint(x: 5, y: 2.4))
        path.addQuadCurve(to: CGPoint(x: 0, y: -3.2), control: CGPoint(x: 5, y: -2.8))
        path.addQuadCurve(to: CGPoint(x: 0, y: 2.8), control: CGPoint(x: -1.3, y: -0.2))
        path.closeSubpath()
        return path
    }

    private func frontBeakPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -3.4, y: 1.8))
        path.addQuadCurve(to: CGPoint(x: 0, y: -3.8), control: CGPoint(x: -2.6, y: -1.4))
        path.addQuadCurve(to: CGPoint(x: 3.4, y: 1.8), control: CGPoint(x: 2.6, y: -1.4))
        path.addQuadCurve(to: CGPoint(x: -3.4, y: 1.8), control: CGPoint(x: 0, y: 3.1))
        path.closeSubpath()
        return path
    }

    private func crestPath(width: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let baseY: CGFloat = 8
        path.move(to: CGPoint(x: 0, y: baseY))
        path.addCurve(to: CGPoint(x: width * 0.28, y: baseY + height * 0.72),
                      control1: CGPoint(x: width * 0.03, y: baseY + height * 0.34),
                      control2: CGPoint(x: width * 0.16, y: baseY + height * 0.68))
        path.addCurve(to: CGPoint(x: width * 0.47, y: baseY + height * 0.34),
                      control1: CGPoint(x: width * 0.36, y: baseY + height * 0.66),
                      control2: CGPoint(x: width * 0.42, y: baseY + height * 0.44))
        path.addCurve(to: CGPoint(x: width * 0.72, y: baseY + height),
                      control1: CGPoint(x: width * 0.53, y: baseY + height * 0.6),
                      control2: CGPoint(x: width * 0.62, y: baseY + height * 0.94))
        path.addCurve(to: CGPoint(x: width, y: baseY),
                      control1: CGPoint(x: width * 0.86, y: baseY + height * 0.86),
                      control2: CGPoint(x: width * 0.98, y: baseY + height * 0.42))
        path.addCurve(to: CGPoint(x: 0, y: baseY),
                      control1: CGPoint(x: width * 0.72, y: baseY - 1.4),
                      control2: CGPoint(x: width * 0.28, y: baseY - 1.4))
        path.closeSubpath()
        return path
    }

    private func backPatchPath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: -11, y: 18, width: 22, height: 14), transform: nil)
    }

    private func backStripePath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 30))
        path.addCurve(to: CGPoint(x: 0, y: 8),
                      control1: CGPoint(x: -2, y: 24),
                      control2: CGPoint(x: 2, y: 15))
        return path
    }

    func debugAppearance() -> BirdAppearanceDebug {
        let visibleEyes = [eyeL, eyeR].filter { $0.alpha > 0.05 }.count
        return BirdAppearanceDebug(
            direction: viewDirection,
            visibleEyes: visibleEyes,
            beakVisible: beak.alpha > 0.05,
            bellyVisible: belly.alpha > 0.05,
            backDetailsVisible: backPatch.alpha > 0.05 && backStripe.alpha > 0.05,
            closedEyeMarksVisible: [eyelidL, eyelidR].filter { $0.alpha > 0.05 }.count,
            sleepZVisible: zzz.alpha > 0.05
        )
    }

    func celebrateEvolution(to stage: GrowthStage) {
        apply(stage: stage)
        removeAction(forKey: "evolve")
        let rise = SKAction.sequence([
            .group([
                .scale(to: baseScale * 1.16, duration: 0.22),
                .moveBy(x: 0, y: 20, duration: 0.22),
            ]),
            .group([
                .scale(to: baseScale, duration: 0.28),
                .moveBy(x: 0, y: -20, duration: 0.28),
            ]),
        ])
        run(.repeat(rise, count: 2), withKey: "evolve")
        flapWings(times: 12, fast: true)
        showBlush(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.showBlush(false)
        }
    }

    // MARK: - Micro animations

    func startIdleAnimations() {
        // breathing: subtle body scale
        let breathe = SKAction.repeatForever(.sequence([
            .scaleY(to: 1.03, duration: 1.2),
            .scaleY(to: 1.0, duration: 1.2),
        ]))
        body.run(breathe, withKey: "breathe")
        belly.run(breathe.copy() as! SKAction, withKey: "breathe")

        // blinking: random interval
        let blink = SKAction.run { [weak self] in self?.blinkOnce() }
        let blinkLoop = SKAction.repeatForever(.sequence([
            .wait(forDuration: 3.2, withRange: 4.0),
            blink,
        ]))
        run(blinkLoop, withKey: "blinkLoop")
    }

    /// Stop the looping idle animations (breathing/blinking) so a scripted
    /// move can take over the body cleanly. Call startIdleAnimations() to resume.
    func stopIdleAnimations() {
        body.removeAction(forKey: "breathe")
        belly.removeAction(forKey: "breathe")
        removeAction(forKey: "blinkLoop")
    }

    func blinkOnce() {
        guard !eyesClosed, viewDirection != .back else { return }
        for pair in visibleEyeTargets() {
            pair.eye.run(.sequence([
                .fadeAlpha(to: 0.12, duration: 0.05),
                .wait(forDuration: 0.08),
                .fadeAlpha(to: 1, duration: 0.06),
            ]), withKey: "blinkEye")
            pair.lid.run(.sequence([
                .fadeAlpha(to: 1, duration: 0.05),
                .wait(forDuration: 0.08),
                .fadeAlpha(to: 0, duration: 0.06),
            ]), withKey: "blinkLid")
        }
    }

    func setEyesClosed(_ closed: Bool, animated: Bool = true) {
        eyesClosed = closed
        for node in [eyeL, eyeR, eyelidL, eyelidR] {
            node.removeAllActions()
        }
        applyEyeClosure(animated: animated)
    }

    func flapWings(times: Int = 3, fast: Bool = false) {
        let dur = fast ? 0.07 : 0.12
        let flap = SKAction.sequence([
            .rotate(toAngle: 0.9, duration: dur),
            .rotate(toAngle: -0.2, duration: dur),
        ])
        wingL.run(.repeat(flap, count: times))
        wingR.run(.repeat(flap, count: times))
    }

    func showBlush(_ show: Bool) {
        for b in [blushL, blushR] {
            b.run(.fadeAlpha(to: show ? 1 : 0, duration: 0.3))
        }
    }

    func startSleepZzz() {
        zzz.removeAction(forKey: "zzz")
        zzz.position = CGPoint(x: 18, y: 36)
        zzz.alpha = 0.9
        zzz.setScale(0.7)
        let float = SKAction.repeatForever(.sequence([
            .run { [weak self] in
                guard let self else { return }
                self.zzz.position = CGPoint(x: 18, y: 36)
                self.zzz.alpha = 0.9
                self.zzz.setScale(0.7)
            },
            .group([
                .moveBy(x: 8, y: 14, duration: 1.6),
                .fadeOut(withDuration: 1.6),
                .scale(to: 1.2, duration: 1.6),
            ]),
        ]))
        zzz.run(float, withKey: "zzz")
    }

    func stopSleepZzz() {
        zzz.removeAction(forKey: "zzz")
        zzz.alpha = 0
    }

    /// Head tilt for "stare" / curiosity.
    func tiltHead(_ on: Bool) {
        head.removeAllActions()
        head.run(.rotate(toAngle: on ? 0.22 : 0, duration: 0.25))
    }

    /// Peck animation: head dips quickly.
    func peckOnce() {
        head.run(.sequence([
            .moveBy(x: 4, y: -8, duration: 0.1),
            .moveBy(x: -4, y: 8, duration: 0.15),
        ]))
    }

    /// Preen/groom: head turns back toward wing.
    func groomOnce() {
        head.run(.sequence([
            .rotate(toAngle: -0.7, duration: 0.3),
            .moveBy(x: -6, y: -4, duration: 0.2),
            .wait(forDuration: 0.5),
            .moveBy(x: 6, y: 4, duration: 0.2),
            .rotate(toAngle: 0, duration: 0.3),
        ]))
    }

    /// 朝行进方向翻身:只翻 `xScale` 符号,保留 growthScale 量级(`xScale == ±growthScale`)。
    func faceWalking(right: Bool) {
        let mag = abs(xScale)
        xScale = mag * (right ? 1 : -1)
    }

    /// 走路步态:一只脚踏地"咬住地面",另一只抬起前摆落到新落点,交替进行。
    ///
    /// 关键是治"滑步"——脚是身体的子节点,身体匀速前移时,**踏地的脚在局部坐标里反向滑动**,
    /// 正好抵消身体位移,所以世界里它钉在原地;只有摆动脚才抬起、向前迈到下一个落点。
    /// `parentDx` 是身体在父坐标里的水平净位移(带符号)。步数取偶数 → 每只脚净位移 0
    /// (cleanup 不复位脚,必须自洽归零,否则脚会永久偏移)。
    func walkCadence(over dur: TimeInterval, parentDx: CGFloat) {
        guard dur > 0.06, abs(parentDx) > 1 else { return }
        let sx = xScale == 0 ? 1 : xScale
        var steps = Int((abs(parentDx) / 12).rounded())   // 约 12pt 一步
        steps = max(2, min(6, steps))
        if steps % 2 != 0 { steps += 1 }                  // 偶数 → 每脚净 0
        let stepDur = dur / Double(steps)
        let half = max(0.03, stepDur / 2)
        // 身体每步的前移量,换算到脚的局部坐标(除以 xScale,含朝向符号与 growthScale)。
        let advance = (parentDx / sx) / CGFloat(steps)

        // 踏地:局部反向滑 advance(线性,匹配身体匀速)→ 世界里脚不动。
        func plant() -> SKAction {
            .moveBy(x: -advance, y: 0, duration: stepDur)   // linear,精确抵消身体前移
        }
        // 抬腿前摆:局部前移 advance(世界里 = 2×身体步距,迈到新落点)+ 抬起落下。
        func swing() -> SKAction {
            let fwd = SKAction.moveBy(x: advance, y: 0, duration: stepDur); fwd.timingMode = .easeInEaseOut
            let up = SKAction.moveBy(x: 0, y: 3, duration: half); up.timingMode = .easeOut
            let down = SKAction.moveBy(x: 0, y: -3, duration: half); down.timingMode = .easeIn
            return .group([fwd, .sequence([up, down])])
        }
        func legSequence(swingFirst: Bool) -> SKAction {
            var seq: [SKAction] = []
            var sw = swingFirst
            for _ in 0..<steps { seq.append(sw ? swing() : plant()); sw.toggle() }
            return .sequence(seq)
        }
        footL.removeAction(forKey: "walkStep")
        footR.removeAction(forKey: "walkStep")
        footL.run(legSequence(swingFirst: false), withKey: "walkStep")  // 左脚先踏地
        footR.run(legSequence(swingFirst: true), withKey: "walkStep")   // 右脚先迈步

        // 身体朝行进方向轻微前倾、再归位(净 0)。幅度要小。
        let dir: CGFloat = parentDx >= 0 ? -1 : 1
        let lean = SKAction.rotate(toAngle: dir * 0.03, duration: dur * 0.35); lean.timingMode = .easeInEaseOut
        let back = SKAction.rotate(toAngle: 0, duration: dur * 0.35); back.timingMode = .easeInEaseOut
        run(.sequence([lean, .wait(forDuration: max(0, dur * 0.3)), back]), withKey: "walkLean")
    }

    /// Stretch: a brief squash-then-stretch with a small wing lift, like a yawny stretch.
    func stretchOnce() {
        run(.sequence([
            .group([.scaleY(to: 0.82, duration: 0.18), .scaleX(to: 1.08, duration: 0.18)]),
            .group([.scaleY(to: 1.12, duration: 0.22), .scaleX(to: 0.94, duration: 0.22)]),
            .group([.scaleY(to: 1.0, duration: 0.2), .scaleX(to: 1.0, duration: 0.2)]),
        ]), withKey: "stretch")
        flapWings(times: 1)
    }

    /// Yawn: head tilts up, beak opens wide, a single sleepy "z" floats up.
    func yawnOnce() {
        head.run(.sequence([
            .rotate(toAngle: 0.35, duration: 0.35),
            .wait(forDuration: 0.45),
            .rotate(toAngle: 0, duration: 0.3),
        ]))
        beak.run(.sequence([
            .scale(to: 1.8, duration: 0.35),
            .wait(forDuration: 0.45),
            .scale(to: 1.0, duration: 0.3),
        ]))
        zzz.removeAction(forKey: "zzz")
        zzz.position = CGPoint(x: 18, y: 34)
        zzz.alpha = 0
        zzz.setScale(0.6)
        zzz.run(.sequence([
            .group([
                .fadeAlpha(to: 0.9, duration: 0.3),
                .moveBy(x: 4, y: 12, duration: 1.0),
                .scale(to: 0.9, duration: 0.6),
            ]),
            .fadeOut(withDuration: 0.4),
            .run { [weak self] in self?.zzz.position = CGPoint(x: 18, y: 38) },
        ]))
    }

    // MARK: - 漫符 (manpu) 情绪符号

    /// TEMP-DEBUG: 静态摆放全部漫符用于离屏渲染验证(验证后删除)。
    func debugPlaceAllManpu() {
        let layout: [(Manpu, CGPoint)] = [
            (.sweat, CGPoint(x: -36, y: 40)), (.anger, CGPoint(x: -24, y: 44)),
            (.surprise, CGPoint(x: -12, y: 44)), (.love, CGPoint(x: 0, y: 42)),
            (.music, CGPoint(x: 12, y: 44)), (.question, CGPoint(x: 26, y: 44)),
            (.dizzy, CGPoint(x: 40, y: 44)),
        ]
        for (kind, pos) in layout {
            let n = makeManpuNode(kind)
            n.position = pos
            manpu.addChild(n)
        }
    }

    /// 在头顶弹出一个情绪符号,播放「弹入 → 行为 → 淡出」后自动移除。
    /// 与身体动画解耦,可与 showBlush / 动作叠加。
    func showManpu(_ kind: Manpu, at anchor: CGPoint? = nil) {
        let node = makeManpuNode(kind)
        node.position = anchor ?? kind.defaultAnchor
        node.zRotation = kind.tilt
        node.alpha = 0
        node.setScale(0.1)
        manpu.addChild(node)

        // 入场:带一点过冲的弹出。
        let popIn = SKAction.group([
            .sequence([.scale(to: 1.2, duration: 0.13), .scale(to: 1.0, duration: 0.07)]),
            .fadeIn(withDuration: 0.12),
        ])

        // 保持阶段:每种符号有自己的小动作。
        let behavior: SKAction
        switch kind {
        case .love:
            behavior = .group([.moveBy(x: 2, y: 16, duration: 1.0), .scale(to: 1.1, duration: 1.0)])
        case .sweat:
            behavior = .sequence([.wait(forDuration: 0.1), .moveBy(x: 1.5, y: -6, duration: 0.5)])
        case .surprise:
            behavior = .sequence([
                .moveBy(x: 0, y: 4, duration: 0.08),
                .moveBy(x: 0, y: -4, duration: 0.1),
                .wait(forDuration: 0.4),
            ])
        case .anger:
            let pulse = SKAction.sequence([.scale(to: 1.25, duration: 0.12), .scale(to: 1.0, duration: 0.12)])
            behavior = .sequence([.repeat(pulse, count: 2), .wait(forDuration: 0.1)])
        case .music:
            // 音符:边上飘边左右摇摆(像随节奏晃)
            let sway = SKAction.sequence([
                .rotate(toAngle: kind.tilt + 0.18, duration: 0.3),
                .rotate(toAngle: kind.tilt - 0.18, duration: 0.3),
                .rotate(toAngle: kind.tilt, duration: 0.2),
            ])
            behavior = .group([.moveBy(x: 6, y: 18, duration: 0.9), sway])
        case .question:
            // 问号:歪头式上下点一下,停留稍久(困惑感)
            behavior = .sequence([
                .moveBy(x: 0, y: 3, duration: 0.12),
                .moveBy(x: 0, y: -3, duration: 0.14),
                .wait(forDuration: 0.6),
            ])
        case .dizzy:
            // 螺旋:原地转圈再消失
            behavior = .sequence([.repeat(.rotate(byAngle: .pi * 2, duration: 0.7), count: 2)])
        }

        node.run(.sequence([popIn, behavior, .fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    private func makeManpuNode(_ kind: Manpu) -> SKNode {
        switch kind {
        case .question:  return makeQuestionNode()
        case .dizzy:     return makeSpiralNode(maxR: 7, turns: 2.0,
                                               color: NSColor(calibratedRed: 0.45, green: 0.4, blue: 0.7, alpha: 0.95),
                                               lineWidth: 1.6)
        default:         return makeShapeManpu(kind)
        }
    }

    private func makeShapeManpu(_ kind: Manpu) -> SKShapeNode {
        let node = SKShapeNode()
        node.lineJoin = .round
        switch kind {
        case .sweat:
            node.path = sweatPath()
            node.fillColor = NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.96, alpha: 0.9)
            node.strokeColor = NSColor(calibratedRed: 0.3, green: 0.55, blue: 0.85, alpha: 0.55)
            node.lineWidth = 0.8
        case .anger:
            node.path = angerPath()
            node.fillColor = NSColor(calibratedRed: 0.88, green: 0.18, blue: 0.2, alpha: 0.95)
            node.strokeColor = NSColor(calibratedRed: 0.6, green: 0.1, blue: 0.12, alpha: 0.75)
            node.lineWidth = 0.8
        case .surprise:
            node.path = exclamationPath()
            node.fillColor = NSColor(calibratedRed: 0.96, green: 0.36, blue: 0.18, alpha: 1)
            node.strokeColor = .clear
        case .love:
            node.path = heartPath()
            node.fillColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.56, alpha: 0.95)
            node.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.5)
            node.lineWidth = 0.8
        case .music:
            node.path = musicNotePath()
            node.fillColor = NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.78, alpha: 0.95)
            node.strokeColor = .clear
        case .question, .dizzy:
            break // 由 makeManpuNode 单独构造
        }
        return node
    }

    /// 问号:描边的钩子曲线 + 一个实心圆点(两者分开,故用容器节点)。
    private func makeQuestionNode() -> SKNode {
        let color = NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.85, alpha: 1)
        let node = SKNode()
        let hook = SKShapeNode(path: questionHookPath())
        hook.fillColor = .clear
        hook.strokeColor = color
        hook.lineWidth = 1.8
        hook.lineCap = .round
        node.addChild(hook)
        let dot = SKShapeNode(circleOfRadius: 1.25)
        dot.fillColor = color
        dot.strokeColor = .clear
        dot.position = CGPoint(x: 0.4, y: -4)
        node.addChild(dot)
        return node
    }

    /// 螺旋:阿基米德螺线的描边,用于眩晕符号与晕眼。
    private func makeSpiralNode(maxR: CGFloat, turns: CGFloat, color: NSColor, lineWidth: CGFloat) -> SKShapeNode {
        let node = SKShapeNode(path: spiralPath(maxR: maxR, turns: turns))
        node.fillColor = .clear
        node.strokeColor = color
        node.lineWidth = lineWidth
        node.lineCap = .round
        return node
    }

    private func heartPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -5.5))                  // 底尖
        p.addCurve(to: CGPoint(x: 0, y: 3),                 // 左半:上行到顶部中央凹口
                   control1: CGPoint(x: -7, y: -3),
                   control2: CGPoint(x: -6.5, y: 6))
        p.addCurve(to: CGPoint(x: 0, y: -5.5),              // 右半:下行回底尖
                   control1: CGPoint(x: 6.5, y: 6),
                   control2: CGPoint(x: 7, y: -3))
        p.closeSubpath()
        return p
    }

    private func sweatPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 7))                                            // 顶尖
        p.addQuadCurve(to: CGPoint(x: 4, y: -1), control: CGPoint(x: 4, y: 3.5))
        p.addArc(center: CGPoint(x: 0, y: -1), radius: 4, startAngle: 0, endAngle: .pi, clockwise: true)  // 底部圆鼓
        p.addQuadCurve(to: CGPoint(x: 0, y: 7), control: CGPoint(x: -4, y: 3.5))
        p.closeSubpath()
        return p
    }

    /// 青筋(💢):尖角朝上下左右、四边深凹的四角星,呈撞击/爆发感。
    private func angerPath() -> CGPath {
        let p = CGMutablePath()
        let R: CGFloat = 7.5, i: CGFloat = 1.9
        p.move(to: CGPoint(x: 0, y: R))                                   // 上
        p.addQuadCurve(to: CGPoint(x: R, y: 0), control: CGPoint(x: i, y: i))      // → 右
        p.addQuadCurve(to: CGPoint(x: 0, y: -R), control: CGPoint(x: i, y: -i))    // → 下
        p.addQuadCurve(to: CGPoint(x: -R, y: 0), control: CGPoint(x: -i, y: -i))   // → 左
        p.addQuadCurve(to: CGPoint(x: 0, y: R), control: CGPoint(x: -i, y: i))     // → 上
        p.closeSubpath()
        return p
    }

    private func exclamationPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -1.7, y: 7))      // 竖条:上宽下窄
        p.addLine(to: CGPoint(x: 1.7, y: 7))
        p.addLine(to: CGPoint(x: 0.9, y: 1.2))
        p.addLine(to: CGPoint(x: -0.9, y: 1.2))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: -1.4, y: -3, width: 2.8, height: 2.8))   // 圆点
        return p
    }

    /// 八分音符:符头(斜椭圆)+ 符干 + 符尾旗。
    private func musicNotePath() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -4, y: -5.5, width: 6, height: 4.6))     // 符头
        p.addRect(CGRect(x: 0.6, y: -3.6, width: 1.5, height: 12))          // 符干
        p.move(to: CGPoint(x: 2.1, y: 8.4))                                 // 符尾旗
        p.addQuadCurve(to: CGPoint(x: 5.4, y: 2.6), control: CGPoint(x: 6.2, y: 6.4))
        p.addQuadCurve(to: CGPoint(x: 2.1, y: 4.8), control: CGPoint(x: 4, y: 4.4))
        p.closeSubpath()
        return p
    }

    /// 问号上半钩(描边用,开放路径)。
    private func questionHookPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -3.2, y: 4.6))
        p.addQuadCurve(to: CGPoint(x: 0.2, y: 8.6), control: CGPoint(x: -3.4, y: 8.8))   // 上行到顶
        p.addQuadCurve(to: CGPoint(x: 1.4, y: 3.0), control: CGPoint(x: 4.4, y: 7.0))    // 越顶向右下
        p.addQuadCurve(to: CGPoint(x: 0.4, y: -0.8), control: CGPoint(x: -0.8, y: 1.6))  // 收进中线落到点上方
        return p
    }

    /// 阿基米德螺线(从中心向外),用于眩晕。
    private func spiralPath(maxR: CGFloat, turns: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let steps = 48
        p.move(to: .zero)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = t * turns * 2 * .pi
            let r = t * maxR
            p.addLine(to: CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        return p
    }

    /// 晕眼:在可见的眼睛上叠一个旋转的小螺旋(被戳晕时),`on=false` 移除。
    func dizzyEyes(_ on: Bool) {
        for eye in [eyeL, eyeR] {
            eye.childNode(withName: "dizzy")?.removeFromParent()
            guard on else { continue }
            let s = makeSpiralNode(maxR: 3.0, turns: 1.7,
                                   color: NSColor(calibratedWhite: 0.96, alpha: 0.95),
                                   lineWidth: 0.8)
            s.name = "dizzy"
            s.zPosition = 3
            eye.addChild(s)
            s.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 0.8)), withKey: "spin")
        }
    }
}
