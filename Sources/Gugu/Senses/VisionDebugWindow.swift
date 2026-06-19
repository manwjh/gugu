import AppKit
import GuguKernel
@preconcurrency import AVFoundation

/// 可视化视觉调试窗口:本机摄像头实时画面 + 检测框 + 标签(目标检测 demo 那种)。
/// 画面只在本机显示、不录制不上传(与"看完即弃"一致)。底部一条文字汇总。
@MainActor
final class VisionDebugWindow {
    private let window: NSWindow
    private let boxView = PreviewBoxView()
    private let textLabel = NSTextField(labelWithString: "")
    private(set) var isOpen = false

    /// 由 app 注入:创建一个绑定摄像头会话的预览层。
    var previewProvider: (() -> AVCaptureVideoPreviewLayer)?

    private var fps = 0
    private var frameCount = 0
    private var fpsStart = Date()
    private let renderInterval: TimeInterval = 0.33
    private let aggWindow: TimeInterval = 1.5
    private var lastTextRender = Date.distantPast
    private var latest = VisionFrame()
    private var exprHistory: [(t: Date, exprs: [String])] = []
    private var objSeen: [String: (peak: Float, last: Date)] = [:]

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 360),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "咕咕视觉调试 · 本机预览(不录制不上传)"
        window.level = .floating
        window.isReleasedWhenClosed = false

        boxView.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textLabel.textColor = .white
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        let textBG = NSView()
        textBG.wantsLayer = true
        textBG.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        textBG.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(boxView)
        container.addSubview(textBG)
        textBG.addSubview(textLabel)
        NSLayoutConstraint.activate([
            boxView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            boxView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            boxView.topAnchor.constraint(equalTo: container.topAnchor),
            boxView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            textBG.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textBG.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textBG.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            textLabel.leadingAnchor.constraint(equalTo: textBG.leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: textBG.trailingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: textBG.topAnchor, constant: 6),
            textLabel.bottomAnchor.constraint(equalTo: textBG.bottomAnchor, constant: -6),
        ])
        window.contentView = container
        textLabel.stringValue = "(开摄像头后这里出现实时画面与检测框)"
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        if boxView.previewLayer == nil, let layer = previewProvider?() {
            boxView.previewLayer = layer
        }
        if let vis = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: vis.maxX - window.frame.width - 24,
                                          y: vis.maxY - window.frame.height - 24))
        }
        window.makeKeyAndOrderFront(nil)
        isOpen = true
    }

    func close() {
        window.orderOut(nil)
        isOpen = false
    }

    func update(_ d: VisionFrame) {
        guard isOpen else { return }
        let now = Date()
        latest = d

        // 画框(每帧,保持跟手)。物品只画 gugu 关心的白名单(隐藏 person/bus 等噪声)。
        var boxes: [PreviewBoxView.Box] = []
        if let fb = d.faceBox { boxes.append(.init(rect: fb, label: "脸", color: .systemGreen)) }
        if let hb = d.handBox {
            boxes.append(.init(rect: hb, label: d.rawGesture == "—" ? "手" : d.rawGesture, color: .systemOrange))
        }
        for o in d.objectBoxes {
            guard let name = VisionObjectObservation.concreteLabel(o.label) else { continue }
            boxes.append(.init(rect: o.rect, label: String(format: "%@ %.0f%%", name, o.conf * 100), color: .systemTeal))
        }
        boxView.setBoxes(boxes)

        // 累积聚合(给文字汇总)。物品同样只统计白名单。
        exprHistory.append((now, d.expressions))
        exprHistory.removeAll { now.timeIntervalSince($0.t) > aggWindow }
        for o in d.objects where VisionObjectObservation.concreteLabel(o.label) != nil {
            objSeen[o.label] = (max(objSeen[o.label]?.peak ?? 0, o.conf), now)
        }
        objSeen = objSeen.filter { now.timeIntervalSince($0.value.last) <= aggWindow }

        frameCount += 1
        let el = now.timeIntervalSince(fpsStart)
        if el >= 1 { fps = Int((Double(frameCount) / el).rounded()); frameCount = 0; fpsStart = now }

        guard now.timeIntervalSince(lastTextRender) >= renderInterval else { return }
        lastTextRender = now
        textLabel.stringValue = renderText()
    }

    private func zhExpr(_ raw: String) -> String {
        ["smile": "笑", "surprised": "惊讶", "sleepy": "困"][raw] ?? raw
    }

    private func renderText() -> String {
        var tally: [String: Int] = [:]
        for h in exprHistory { for e in h.exprs { tally[e, default: 0] += 1 } }
        let exprStr = tally.isEmpty ? "—"
            : tally.sorted { $0.value > $1.value }.map { "\(zhExpr($0.key))×\($0.value)" }.joined(separator: " ")
        let objStr = objSeen.isEmpty ? "—"
            : objSeen.sorted { $0.value.peak > $1.value.peak }
                .map { "\(VisionObjectObservation.concreteLabel($0.key) ?? $0.key):\(String(format: "%.2f", $0.value.peak))" }
                .joined(separator: " ")
        let d = latest
        return "fps:\(fps)  模型:\(d.modelLoaded ? "已装" : "未装")  低电量:\(d.lowPower ? "是" : "否")\n"
            + String(format: "脸: 嘴宽高 %.2f  上扬 %.3f  眼 L %.2f R %.2f\n", d.mouthWH, d.cornerUpturn, d.eyeL, d.eyeR)
            + "表情(近1.5s): \(exprStr)\n"
            + "物品(近1.5s峰值): \(objStr)"
    }
}

/// 承载预览层 + 在其上画归一化检测框/标签。
@MainActor
private final class PreviewBoxView: NSView {
    struct Box { let rect: CGRect; let label: String; let color: NSColor }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let pl = previewLayer {
                pl.transform = CATransform3DMakeScale(-1, 1, 1)   // 水平镜像(自拍视角)
                layer?.insertSublayer(pl, below: overlay)
            }
            needsLayout = true
        }
    }
    private let overlay = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        overlay.frame = bounds
    }

    func setBoxes(_ boxes: [Box]) {
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let pl = previewLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        for b in boxes {
            // Vision 直立坐标(原点左下);实测此预览层 Y 不需翻(去掉 1-maxY)。x 配合镜像翻。
            let v = b.rect
            let meta = CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height)
            var r = pl.layerRectConverted(fromMetadataOutputRect: meta)
            r = CGRect(x: bounds.width - r.maxX, y: r.minY, width: r.width, height: r.height)  // 配合预览镜像,框 x 也镜像
            guard r.width > 1, r.height > 1 else { continue }
            let shape = CAShapeLayer()
            shape.path = CGPath(rect: r, transform: nil)
            shape.fillColor = nil
            shape.strokeColor = b.color.cgColor
            shape.lineWidth = 2
            overlay.addSublayer(shape)
            let text = CATextLayer()
            text.string = " \(b.label) "
            text.fontSize = 11
            text.foregroundColor = NSColor.black.cgColor
            text.backgroundColor = b.color.cgColor
            text.contentsScale = scale
            text.alignmentMode = .left
            let th: CGFloat = 15
            text.frame = CGRect(x: r.minX, y: max(0, r.maxY - th), width: max(40, r.width), height: th)
            overlay.addSublayer(text)
        }
    }
}
