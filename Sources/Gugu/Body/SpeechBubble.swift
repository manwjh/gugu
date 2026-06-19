import AppKit

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
