import Foundation
import CoreGraphics

/// 房间内的平台(横杠/斜坡):主人画的线段,咕咕可以站上去、跳、perch。
/// 坐标用归一化 [0…1] 存(相对房间 bounds),这样缩放房间时平台自动跟着。
struct Platform: Codable, Identifiable, Equatable {
    let id: UUID
    /// 起止点,归一化坐标 ([0,0]=左下角, [1,1]=右上角,房间本地)
    var start: CGPoint
    var end: CGPoint

    init(id: UUID = UUID(), start: CGPoint, end: CGPoint) {
        self.id = id
        self.start = start
        self.end = end
    }

    /// 转成房间绝对坐标(px)
    func absolute(in roomFrame: CGRect) -> (start: CGPoint, end: CGPoint) {
        let s = CGPoint(x: roomFrame.minX + start.x * roomFrame.width,
                        y: roomFrame.minY + start.y * roomFrame.height)
        let e = CGPoint(x: roomFrame.minX + end.x * roomFrame.width,
                        y: roomFrame.minY + end.y * roomFrame.height)
        return (s, e)
    }

    /// 线段的角度(弧度,相对水平向右)
    var angle: CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }

    /// 线段长度(归一化空间,需乘房间尺寸得实际长度)
    var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    /// 点 `p`(归一化坐标)到线段的最近点(投影点,夹在两端之间)
    func closestPoint(to p: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-8 else { return start }  // 退化成点
        let t = max(0, min(1, ((p.x - start.x) * dx + (p.y - start.y) * dy) / lenSq))
        return CGPoint(x: start.x + t * dx, y: start.y + t * dy)
    }

    /// 点 `p`(归一化坐标)到线段的距离(归一化空间)
    func distance(to p: CGPoint) -> CGFloat {
        let c = closestPoint(to: p)
        return hypot(p.x - c.x, p.y - c.y)
    }

    /// 从绝对坐标(房间 px)构造归一化 Platform
    static func fromAbsolute(start: CGPoint, end: CGPoint, in roomFrame: CGRect) -> Platform {
        let ns = CGPoint(x: (start.x - roomFrame.minX) / roomFrame.width,
                         y: (start.y - roomFrame.minY) / roomFrame.height)
        let ne = CGPoint(x: (end.x - roomFrame.minX) / roomFrame.width,
                         y: (end.y - roomFrame.minY) / roomFrame.height)
        return Platform(start: ns, end: ne)
    }
}
