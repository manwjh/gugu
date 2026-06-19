import AppKit
import GuguKernel
import Foundation

/// 小窝的所有权与生命周期:打开/关闭、暴露当前 frame、把拖动/缩放变化通知外部。
/// frame 持久化到 home.json,关掉再开恢复上次尺寸/位置。
@MainActor
final class HomeController {
    private let window: HomeWindow
    private let content: HomeContentView

    private(set) var isOpen = false

    /// 小窝 frame 变化(拖动/缩放)时回调,供 PetController 更新包围框。
    var onFrameChange: ((CGRect) -> Void)?
    /// 平台集合变化(画/删/清空)时回调,供 PetController 更新可站立的平台。
    var onPlatformsChange: (([Platform]) -> Void)?

    var frame: CGRect { window.frame }
    private(set) var platforms: [Platform] = []

    private let defaultSize = CGSize(width: 360, height: 260)

    init() {
        let saved = HomeController.loadState()
        let size = saved?.size ?? defaultSize
        window = HomeWindow(size: size)
        content = HomeContentView(frame: CGRect(origin: .zero, size: size))
        window.contentView = content

        platforms = HomeController.loadPlatforms()
        content.platforms = platforms

        content.onFrameChange = { [weak self] f in self?.onFrameChange?(f) }
        content.onCommit = { f in HomeController.saveState(f) }
        content.onPlatformsChange = { [weak self] ps in
            guard let self else { return }
            self.platforms = ps
            HomeController.savePlatforms(ps)
            self.onPlatformsChange?(ps)
        }

        if let origin = saved?.origin {
            window.setFrameOrigin(origin)
        } else {
            centerOnMainScreen()
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // 若上次保存的位置已不在任何屏幕内,回到主屏居中。
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            centerOnMainScreen()
        }
        window.orderFrontRegardless()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        HomeController.saveState(window.frame)
        window.orderOut(nil)
    }

    private func centerOnMainScreen() {
        guard let vis = NSScreen.main?.visibleFrame else { return }
        let origin = CGPoint(x: vis.midX - window.frame.width / 2,
                             y: vis.midY - window.frame.height / 2)
        window.setFrameOrigin(origin)
    }

    // MARK: - Persistence

    private struct HomeState: Codable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        var origin: CGPoint { CGPoint(x: x, y: y) }
        var size: CGSize { CGSize(width: w, height: h) }
    }

    private static func loadState() -> (origin: CGPoint, size: CGSize)? {
        guard let data = try? Data(contentsOf: Paths.homeState),
              let s = try? JSONDecoder().decode(HomeState.self, from: data) else { return nil }
        return (s.origin, s.size)
    }

    private static func saveState(_ frame: CGRect) {
        let s = HomeState(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Paths.homeState, options: .atomic)
        }
    }

    private static func loadPlatforms() -> [Platform] {
        guard let data = try? Data(contentsOf: Paths.homePlatforms),
              let ps = try? JSONDecoder().decode([Platform].self, from: data) else { return [] }
        return ps
    }

    private static func savePlatforms(_ platforms: [Platform]) {
        guard let data = try? JSONEncoder().encode(platforms) else { return }
        try? data.write(to: Paths.homePlatforms, options: .atomic)
    }
}
