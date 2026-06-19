import AppKit
import GuguKernel

/// 小窝(home)的半透明容器窗口。borderless、透明底,层级低于咕咕窗口(.statusBar)
/// 因此咕咕始终画在小窝之上。窗口体内可拖动移动,右下角 grip 可缩放。
/// 第二阶段:左上角画笔按钮切换模式,画笔模式下拖拽画平台线段、点删平台。
final class HomeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating              // 低于咕咕的 .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = false   // 自己处理移动/缩放/画线,给 grip+按钮让路
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Content view (画板 + grip + 平台绘制 + 画笔按钮)

final class HomeContentView: NSView {
    var onFrameChange: ((CGRect) -> Void)?
    var onCommit: ((CGRect) -> Void)?
    var onPlatformsChange: (([Platform]) -> Void)?

    var platforms: [Platform] = [] {
        didSet { needsDisplay = true }
    }

    private var drawMode = false {  // 画笔模式:拖拽画平台;普通模式:拖拽移动窗口
        didSet {
            pencilButton.image = NSImage(systemSymbolName: drawMode ? "pencil.circle.fill" : "pencil",
                                          accessibilityDescription: nil)
            needsDisplay = true
        }
    }

    private let minSize = CGSize(width: 200, height: 200)
    private let gripSize: CGFloat = 24
    private let buttonSize: CGFloat = 20
    private let cornerRadius: CGFloat = 18

    private var mode: DragMode = .none
    private var frameStart = CGRect.zero
    private var mouseStart = CGPoint.zero
    private var dragStart: CGPoint?       // 画笔模式:画线起点(本地坐标)
    private var dragCurrent: CGPoint?     // 画笔模式:画线终点(实时)

    private lazy var pencilButton: NSButton = {
        let b = NSButton(frame: CGRect(x: 12, y: bounds.height - 12 - buttonSize, width: buttonSize, height: buttonSize))
        b.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.target = self
        b.action = #selector(toggleDrawMode)
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        b.layer?.cornerRadius = 4
        b.autoresizingMask = [.maxXMargin, .minYMargin]   // 钉在左上角
        return b
    }()

    private lazy var clearButton: NSButton = {
        let b = NSButton(frame: CGRect(x: 12 + buttonSize + 6, y: bounds.height - 12 - buttonSize, width: buttonSize, height: buttonSize))
        b.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.target = self
        b.action = #selector(clearAllPlatforms)
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        b.layer?.cornerRadius = 4
        b.autoresizingMask = [.maxXMargin, .minYMargin]   // 钉在左上角
        return b
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizesSubviews = true
        addSubview(pencilButton)
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleDrawMode() {
        drawMode.toggle()
    }

    @objc private func clearAllPlatforms() {
        guard !platforms.isEmpty else { return }
        platforms = []
        onPlatformsChange?(platforms)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 半透明圆角矩形底
        let bg = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.systemTeal.withAlphaComponent(0.08).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        bg.lineWidth = 1.5
        bg.stroke()

        // 右下角 grip(三条斜杠)
        let cx = bounds.maxX - gripSize / 2, cy = bounds.minY + gripSize / 2
        NSColor.white.withAlphaComponent(0.4).setStroke()
        for i in 0..<3 {
            let offset = CGFloat(i) * 5
            let p = NSBezierPath()
            p.move(to: CGPoint(x: cx - 10 + offset, y: cy - 10 + offset))
            p.line(to: CGPoint(x: cx + 2 + offset, y: cy + 2 + offset))
            p.lineWidth = 1.5
            p.stroke()
        }

        // 地板线:贴着房间底内沿画一条淡线,让"重力 + 落脚"读起来更清楚。
        let floorInset: CGFloat = 6
        let floor = NSBezierPath()
        floor.move(to: CGPoint(x: cornerRadius, y: floorInset))
        floor.line(to: CGPoint(x: bounds.maxX - cornerRadius, y: floorInset))
        floor.lineWidth = 1
        NSColor.white.withAlphaComponent(0.18).setStroke()
        floor.stroke()

        // 画所有平台(房间本地坐标 → 绝对 px)
        guard let roomFrame = window?.frame else { return }
        for plat in platforms {
            let (s, e) = plat.absolute(in: roomFrame)
            // 转成 view 本地坐标(view 的 bounds 原点在左下角,与房间 frame 对齐)
            let vs = CGPoint(x: s.x - roomFrame.minX, y: s.y - roomFrame.minY)
            let ve = CGPoint(x: e.x - roomFrame.minX, y: e.y - roomFrame.minY)
            let path = NSBezierPath()
            path.move(to: vs)
            path.line(to: ve)
            path.lineCapStyle = .round
            path.lineWidth = 3
            NSColor.systemCyan.withAlphaComponent(0.7).setStroke()
            path.stroke()
            // 端点小圆点,读作"实心横杠/落脚台"
            NSColor.systemCyan.withAlphaComponent(0.85).setFill()
            for p in [vs, ve] {
                NSBezierPath(ovalIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
            }
        }

        // 画笔模式:正在拖拽的临时线段
        if drawMode, let start = dragStart, let cur = dragCurrent {
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: cur)
            path.lineCapStyle = .round
            path.lineWidth = 3
            NSColor.white.withAlphaComponent(0.5).setStroke()
            path.stroke()
        }
    }

    // MARK: - Mouse handling

    private enum DragMode { case none, move, resize }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        mouseStart = NSEvent.mouseLocation     // 屏幕坐标:位移/缩放增量的稳定参照
        guard let window else { return }
        frameStart = window.frame

        if drawMode {
            // 画笔模式:检查是否点中某平台(距离 < 8pt) → 删除;否则开始画新平台
            if let hitIndex = hitTestPlatform(at: loc) {
                platforms.remove(at: hitIndex)
                onPlatformsChange?(platforms)
                return
            }
            dragStart = loc
            dragCurrent = loc
            return
        }

        // 普通模式:右下角 → 缩放;其余 → 移动
        let gripRect = CGRect(x: bounds.maxX - gripSize, y: bounds.minY, width: gripSize, height: gripSize)
        if gripRect.contains(loc) {
            mode = .resize
        } else {
            mode = .move
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let loc = convert(event.locationInWindow, from: nil)

        if drawMode {
            dragCurrent = loc
            needsDisplay = true
            return
        }

        // 位移/缩放用屏幕坐标算增量:窗口在缩放时原点会移动,locationInWindow 的
        // 参照系会跟着漂,导致鼠标和起点越拖越远。屏幕坐标稳定,不受窗口变化影响。
        let m = NSEvent.mouseLocation
        let dx = m.x - mouseStart.x
        let dy = m.y - mouseStart.y
        switch mode {
        case .move:
            let origin = CGPoint(x: frameStart.minX + dx, y: frameStart.minY + dy)
            window.setFrameOrigin(origin)
        case .resize:
            let maxSize = (window.screen ?? NSScreen.main)?.visibleFrame.size
                ?? CGSize(width: 4000, height: 4000)
            var w = frameStart.width + dx
            var h = frameStart.height - dy
            w = max(minSize.width, min(w, maxSize.width))
            h = max(minSize.height, min(h, maxSize.height))
            let newOrigin = CGPoint(x: frameStart.minX, y: frameStart.maxY - h)
            window.setFrame(CGRect(origin: newOrigin, size: CGSize(width: w, height: h)),
                            display: true)
        case .none:
            break
        }
        onFrameChange?(window.frame)
    }

    override func mouseUp(with event: NSEvent) {
        if drawMode, let start = dragStart, let end = dragCurrent {
            let dist = hypot(end.x - start.x, end.y - start.y)
            if dist > 20 {  // 最短 20pt 才算有效平台
                guard let roomFrame = window?.frame else { return }
                // 转成房间绝对坐标再归一化
                let absStart = CGPoint(x: roomFrame.minX + start.x, y: roomFrame.minY + start.y)
                let absEnd = CGPoint(x: roomFrame.minX + end.x, y: roomFrame.minY + end.y)
                let plat = Platform.fromAbsolute(start: absStart, end: absEnd, in: roomFrame)
                platforms.append(plat)
                onPlatformsChange?(platforms)
            }
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }

        if mode != .none, let window {
            onCommit?(window.frame)
        }
        mode = .none
    }

    /// 点击测试:返回离 `loc` 最近的平台索引(距离 < 8pt),供删除用
    private func hitTestPlatform(at loc: CGPoint) -> Int? {
        guard let roomFrame = window?.frame else { return nil }
        // loc 是 view 本地坐标,转成房间归一化坐标
        let absLoc = CGPoint(x: roomFrame.minX + loc.x, y: roomFrame.minY + loc.y)
        let normLoc = CGPoint(x: (absLoc.x - roomFrame.minX) / roomFrame.width,
                              y: (absLoc.y - roomFrame.minY) / roomFrame.height)
        let threshold = 8.0 / roomFrame.width  // 8pt 转归一化
        for (i, plat) in platforms.enumerated() {
            if plat.distance(to: normLoc) < threshold {
                return i
            }
        }
        return nil
    }
}
