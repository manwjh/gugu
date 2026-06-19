import AppKit

/// 视觉调试窗口:实时显示摄像头每帧算出的原始数值(嘴/眼/手指/手型/物品/fps),
/// 用来校准阈值,替代"盲调"。只在主人从菜单打开时显示。
@MainActor
final class VisionDebugWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private(set) var isOpen = false

    // 估算 fps(数 onDebug 调用频率)
    private var frameCount = 0
    private var fpsStart = Date()
    private var fps = 0

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 300),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "咕咕视觉调试"
        window.level = .floating
        window.isReleasedWhenClosed = false

        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
        ])
        window.contentView = container
        label.stringValue = "(摄像头未开启时这里没有数据)\n菜单栏开「睁眼看你」即可。"
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
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

    func update(_ d: VisionDebug) {
        guard isOpen else { return }
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsStart)
        if elapsed >= 1 {
            fps = Int((Double(frameCount) / elapsed).rounded())
            frameCount = 0
            fpsStart = Date()
        }
        label.stringValue = render(d)
    }

    private func render(_ d: VisionDebug) -> String {
        func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
        let fingerNames = ["食", "中", "无", "小"]
        let fingerStr = d.fingers.isEmpty
            ? "—"
            : zip(fingerNames, d.fingers).map { "\($0)\($1 ? "✓" : "·")" }.joined(separator: " ")
        let exprStr = d.expressions.isEmpty ? "—" : d.expressions.joined(separator: ",")
        let objStr = d.objects.isEmpty
            ? "—"
            : d.objects.map { "\($0.label):\(String(format: "%.2f", $0.conf))" }.joined(separator: ", ")
        return """
        fps: \(fps)      低电量: \(d.lowPower ? "是" : "否")
        物品模型: \(d.modelLoaded ? "已装(可认物品)" : "未装(只认猫狗)")
        ──────────────
        脸: \(d.facePresent ? "在座" : "无")
          嘴 宽/高 = \(f(d.mouthWH))
          嘴角上扬 = \(f(d.cornerUpturn))   (>0.035 → 笑)
          眼 L=\(f(d.eyeL))  R=\(f(d.eyeR))  (<0.16 → 困)
          本帧表情: \(exprStr)
        ──────────────
        手型: \(d.gesture)
          手指[食中无小]: \(fingerStr)
          挥手轨迹: \(d.palmSamples) 帧
        ──────────────
        物品: \(objStr)
        """
    }
}
