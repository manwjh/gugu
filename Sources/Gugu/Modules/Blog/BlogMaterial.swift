import Foundation
import GuguKernel

/// 收集"今天"可写的素材:小记(notes.jsonl)与聊天片段(chat.jsonl)。
/// 全程容错——任何文件缺失/格式不对都跳过,绝不抛错;都没有就给个安静的占位。
/// 记忆梗概由 Brain.writeBlog 自己叠加,这里只管"今天发生了什么"。
enum BlogMaterial {
    static func gatherToday(now: Date = Date()) -> String {
        let today = dayPrefix(now)
        var parts: [String] = []

        let notes = readJSONL(Paths.root.appendingPathComponent("notes.jsonl"))
            .filter { ($0["t"] as? String)?.hasPrefix(today) == true }
            .compactMap { $0["text"] as? String }
        if !notes.isEmpty {
            parts.append("今天的小记:\n" + notes.map { "- \($0)" }.joined(separator: "\n"))
        }

        let chats = readJSONL(Paths.chatLog)
            .filter { ($0["t"] as? String)?.hasPrefix(today) == true }
            .compactMap { row -> String? in
                let u = (row["user"] as? String) ?? ""
                let p = (row["pet"] as? String) ?? ""
                if u.isEmpty && p.isEmpty { return nil }
                return "主人:\(u) / 咕咕:\(p)"
            }
        if !chats.isEmpty {
            parts.append("今天和主人的对话(节选):\n" + chats.suffix(12).joined(separator: "\n"))
        }

        // 今天发生的小事(里程碑/学新动作/互动等),取自 EventBus 当天日志——
        // 这就是"重要时刻自动记一笔"的来源:它们已经在事件流里,日记顺手写进去。
        let skip: Set<String> = ["app_switch", "rhythm", "voice", "chat"]
        var seen = Set<String>()
        var moments: [String] = []
        for line in EventBus.todayLines() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = obj["kind"] as? String, !skip.contains(kind),
                  let summary = obj["summary"] as? String, !summary.isEmpty,
                  !seen.contains(summary) else { continue }
            seen.insert(summary)
            moments.append(summary)
        }
        if !moments.isEmpty {
            parts.append("今天发生的小事:\n" + moments.suffix(12).map { "- \($0)" }.joined(separator: "\n"))
        }

        if parts.isEmpty {
            return "今天很安静,没什么特别的事,主人大概在专心忙自己的。"
        }
        return parts.joined(separator: "\n\n")
    }

    private static func dayPrefix(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private static func readJSONL(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }
}
