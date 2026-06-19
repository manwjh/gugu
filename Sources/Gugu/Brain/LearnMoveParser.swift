import Foundation
import GuguKernel

/// 识别"主人想教咕咕一个新动作"的请求(本地、零成本)。
///
/// 命中后返回主人描述的动作意图(一句话),交给 `Brain.learnMove` 让模型把它
/// 翻译成一段受白名单约束的元动作编排,再生成 move_add 提案等主人批准。
///
/// 例:
///   "咕咕,学个翻跟头"        → "翻跟头"
///   "教你转个圈好不好"        → "转个圈"
///   "你能学会作揖吗"          → "作揖"
enum LearnMoveParser {
    private static let prefixes = [
        "学一个", "学个", "学会", "学一下", "学习",
        "教你", "教咕咕", "我教你", "你能不能学", "你能学会", "你会不会",
        "learn", "learn to", "learn a", "teach you", "can you learn", "try to learn",
    ]

    /// 返回主人想教的动作意图描述;不是学动作请求则返回 nil。
    static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in prefixes {
            guard let range = trimmed.range(of: prefix, options: .caseInsensitive) else { continue }
            var rest = String(trimmed[range.upperBound...])
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,。!！?？、~ \n\t"))
            // 去掉常见的语气尾巴（中英文）
            for tail in ["好不好", "好吗", "可以吗", "行不行", "怎么样", "吗", "呢", "啊", "嘛", "吧",
                         "please", "ok", "okay"] {
                if rest.lowercased().hasSuffix(tail.lowercased()) {
                    rest = String(rest.dropLast(tail.count))
                }
            }
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,。!！?？、~ \n\t"))
            if !rest.isEmpty, rest.count <= 20 {
                return rest
            }
        }
        return nil
    }
}
