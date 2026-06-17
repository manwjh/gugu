import SpriteKit

enum BirdViewDirection: Equatable {
    case front
    case back
    case side
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
}
