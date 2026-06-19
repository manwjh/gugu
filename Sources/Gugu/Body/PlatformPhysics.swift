import AppKit
import GuguKernel
import SpriteKit

/// 平台/落地碰撞:房间内主人画的平台(归一化坐标),咕咕在其上站/走/栖/落。
/// 纯物理位置迁移——成员可见性不变,只是把这组方法从 PetController.swift 搬到这里。
@MainActor
extension PetController {
    /// HomeController 通知平台变化(画/删/清空):更新本地缓存。
    /// 若咕咕正站/栖在某条被删掉的平台上 → 解除支撑,自然坠落。
    func updatePlatforms(_ newPlatforms: [Platform]) {
        platforms = newPlatforms
        if let id = supportSurface?.platformId,
           !newPlatforms.contains(where: { $0.id == id }) {
            supportSurface = nil
            perchCheckTimer?.invalidate()
            if state != .dragged {
                bird.flapWings(times: 4, fast: true)
                vel = CGVector(dx: CGFloat.random(in: -30...30), dy: 0)
                bird.position.y = feetY
                transition(to: .falling)
            }
        }
    }

    /// 下落中穿过某平台 → 返回落脚信息(平台 id + 落脚点);否则 nil。
    /// 检测:从上一帧到这一帧,窗口中心点穿过了某条线段,且速度向下(vel.dy < 0)。
    func checkPlatformLanding(at origin: CGPoint, vel: CGVector) -> (platformId: UUID, landingOrigin: CGPoint)? {
        guard let home = homeFrame, vel.dy < 0 else { return nil }
        // 全程用屏幕绝对坐标(经 Platform.absolute),省掉归一化来回换算;
        // 落点参照鸟"可见底"(与房间地板一致),而非 feetY 锚点,否则脚会穿到线下面。
        let bvMinY = birdVisibleFrame().minY
        let cx = origin.x + winSize.width / 2
        let curY = origin.y + feetY
        let prevY = curY - vel.dy / 60.0            // 上一帧 y(dt≈1/60)
        for plat in platforms {
            let (s, e) = plat.absolute(in: home)
            // 这一帧落到线段 y 区间内,且确有"自上而下穿过"的趋势
            guard prevY >= min(s.y, e.y), curY <= max(s.y, e.y) else { continue }
            let dx = e.x - s.x
            if abs(dx) < 1e-6 {                      // 垂直线段:x 命中即落到顶端
                guard abs(cx - s.x) < home.width * 0.01 else { continue }
                return (plat.id, CGPoint(x: origin.x, y: max(s.y, e.y) - bvMinY))
            }
            let t = (cx - s.x) / dx
            guard t >= 0, t <= 1 else { continue }   // 不在线段横向范围内
            let lineY = s.y + t * (e.y - s.y)
            if prevY >= lineY && curY <= lineY {
                return (plat.id, CGPoint(x: origin.x, y: lineY - bvMinY))
            }
        }
        return nil
    }

    /// 返回离当前位置最近的平台(房间内有平台时用)
    func nearestPlatform() -> Platform? {
        guard let home = homeFrame, !platforms.isEmpty else { return nil }
        let birdCenterX = window.frame.origin.x + winSize.width / 2
        let birdCenterY = window.frame.origin.y + feetY
        let normBird = CGPoint(x: (birdCenterX - home.minX) / home.width,
                               y: (birdCenterY - home.minY) / home.height)
        var nearest: Platform?
        var minDist = CGFloat.infinity
        for plat in platforms {
            let closest = plat.closestPoint(to: normBird)
            let dist = hypot(closest.x - normBird.x, closest.y - normBird.y)
            if dist < minDist {
                minDist = dist
                nearest = plat
            }
        }
        return nearest
    }

    /// 平台在鸟中心 x(屏幕 px)处对应的窗口 origin.y(让鸟可见底踩在斜面上);
    /// x 超出线段范围返回 nil。
    func platformOriginY(_ plat: Platform, birdCenterX cx: CGFloat) -> CGFloat? {
        guard let home = homeFrame else { return nil }
        let (s, e) = plat.absolute(in: home)
        let minX = min(s.x, e.x), maxX = max(s.x, e.x)
        guard cx >= minX - 1, cx <= maxX + 1 else { return nil }
        let dx = e.x - s.x
        let lineY: CGFloat
        if abs(dx) < 1e-6 { lineY = max(s.y, e.y) }     // 垂直线段:用顶端
        else { lineY = s.y + (cx - s.x) / dx * (e.y - s.y) }
        return lineY - birdVisibleFrame().minY
    }

    /// 平台两端对应的窗口 origin.x 范围(供沿平台走动/折返时夹住,不走出平台)。
    func platformOriginXRange(_ plat: Platform) -> (min: CGFloat, max: CGFloat)? {
        guard let home = homeFrame else { return nil }
        let (s, e) = plat.absolute(in: home)
        return (min(s.x, e.x) - winSize.width / 2, max(s.x, e.x) - winSize.width / 2)
    }
}
