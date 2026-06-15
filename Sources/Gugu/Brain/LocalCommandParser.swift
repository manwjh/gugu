import Foundation

/// Small deterministic parser for owner-directed local actions. It is not a
/// replacement for LLM understanding; it catches explicit commands so permitted
/// tools can run without an extra model call.
struct LocalCommand: Equatable {
    enum Kind: String {
        case note
        case reminder
        case research
    }

    let kind: Kind
    let content: String
    let dueText: String?
    let deferred: Bool
}

enum LocalCommandParser {
    static func parse(_ text: String) -> LocalCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let content = extract(afterAnyOf: ["记一下", "帮我记一下", "帮我记", "记个笔记", "记一笔"], in: trimmed),
           !content.isEmpty {
            return LocalCommand(kind: .note, content: content, dueText: nil, deferred: isDeferred(trimmed))
        }

        if let content = extract(afterAnyOf: ["提醒我", "到时候提醒我", "帮我提醒"], in: trimmed),
           !content.isEmpty {
            return LocalCommand(kind: .reminder, content: contentWithoutDue(content), dueText: dueText(from: content), deferred: isDeferred(trimmed))
        }

        if let content = extract(afterAnyOf: ["研究一下", "帮我研究", "查一下", "帮我查", "查查"], in: trimmed),
           !content.isEmpty {
            return LocalCommand(kind: .research, content: content, dueText: nil, deferred: isDeferred(trimmed))
        }

        return nil
    }

    private static func extract(afterAnyOf prefixes: [String], in text: String) -> String? {
        for prefix in prefixes {
            if let range = text.range(of: prefix, options: [.caseInsensitive, .widthInsensitive]) {
                let raw = String(text[range.upperBound...])
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,。!！?？、 \n\t"))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func dueText(from content: String) -> String? {
        let markers = ["明天", "后天", "今晚", "今天", "下周", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for marker in markers where content.contains(marker) {
            return marker
        }
        return nil
    }

    private static func contentWithoutDue(_ content: String) -> String {
        var out = content
        for marker in ["明天", "后天", "今晚", "今天"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,。!！?？、 \n\t"))
    }

    private static func isDeferred(_ text: String) -> Bool {
        ["今晚", "夜里", "晚上", "睡觉时", "有空时", "待会"].contains { text.contains($0) }
    }
}
