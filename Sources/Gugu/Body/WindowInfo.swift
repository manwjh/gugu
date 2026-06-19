import AppKit
import GuguKernel

/// 与宠物行为无关的 CGWindowList 工具:查询前台窗口 / 指定窗口的几何。
/// 保持为 PetController 的 static 扩展,调用点(PetController.frontmostWindowInfo()
/// / PetController.windowInfo(for:))无需改动。
@MainActor
extension PetController {
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
}
