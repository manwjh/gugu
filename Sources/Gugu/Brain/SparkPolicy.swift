import Foundation
import GuguKernel

/// 「灵光」择机策略——纯逻辑,便于测试。
///
/// 对应"语言魅力被成本压住"的短板:绝大多数心跳仍用便宜模型(公理 A2),
/// 只在**罕见的高价值时机**临时借一次更强的脑子,让偶尔那一句话真的有灵性。
/// 不是全程换贵模型——那会烧钱且违背成本哲学。
///
/// 触发条件(全部满足才点亮灵光):
/// 1. 配置启用(spark_id 非空且每日上限 > 0);
/// 2. 当下确实是高价值时机(好奇心远超阈值,说明攒了很多观察);
/// 3. 今天用的次数没到上限;
/// 4. 距上次灵光已过冷却。
enum SparkPolicy {
    /// 高价值时机:好奇心达到普通心跳阈值的这个倍数,才配得上灵光。
    static let curiosityMultiplier: Double = 2.0

    struct Inputs {
        var enabled: Bool
        var curiosity: Double
        var heartbeatThreshold: Double
        var usedToday: Int
        var dailyLimit: Int
        var secondsSinceLastSpark: TimeInterval
        var cooldown: TimeInterval
    }

    /// 是否该在这一次心跳点亮灵光。纯函数,无副作用。
    static func shouldSpark(_ i: Inputs) -> Bool {
        guard i.enabled else { return false }
        guard i.usedToday < i.dailyLimit else { return false }
        guard i.secondsSinceLastSpark >= i.cooldown else { return false }
        return i.curiosity >= i.heartbeatThreshold * curiosityMultiplier
    }
}
