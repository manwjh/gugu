import AppKit
import GuguKernel

// MARK: - ActionGridView (multi-column grid of action buttons for a menu item)

/// 一个塞进 NSMenuItem.view 的多列动作网格。NSMenu 原生只能竖排单列;
/// 用自定义视图就能多列平铺,容纳内置 + 学会的全部动作。点按钮即演动作并收起菜单。
@MainActor
final class ActionGridView: NSView {
    private var names: [String] = []
    var onPick: ((String) -> Void)?

    init(items: [(label: String, name: String)], columns: Int = 3) {
        super.init(frame: .zero)
        let cellW: CGFloat = 96, cellH: CGFloat = 28, gap: CGFloat = 4, margin: CGFloat = 8
        let cols = max(1, columns)
        let rows = max(1, Int(ceil(Double(items.count) / Double(cols))))
        let width = margin * 2 + CGFloat(cols) * cellW + CGFloat(cols - 1) * gap
        let height = margin * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        frame = NSRect(x: 0, y: 0, width: width, height: height)

        for (i, item) in items.enumerated() {
            let col = i % cols, row = i / cols
            let b = NSButton(frame: NSRect(
                x: margin + CGFloat(col) * (cellW + gap),
                y: height - margin - cellH - CGFloat(row) * (cellH + gap),
                width: cellW, height: cellH))
            b.title = item.label
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 12)
            b.lineBreakMode = .byTruncatingTail
            b.tag = i
            b.target = self
            b.action = #selector(tap(_:))
            names.append(item.name)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tap(_ sender: NSButton) {
        let name = names[sender.tag]
        enclosingMenuItem?.menu?.cancelTracking()   // 收起菜单
        onPick?(name)
    }
}
