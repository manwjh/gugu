import Foundation

/// Local token metering. The relay's usage numbers are unreliable (returns 0),
/// so we estimate tokens as ceil(chars / 3.2) — conservative for mixed CJK/ASCII
/// (CJK is ~1 token per char; this overestimates safely for budget purposes).
/// Budget is expressed purely in tokens — no money anywhere.
@MainActor
final class Budget {
    struct Usage: Codable {
        var date: String
        var calls: Int
        var tokensIn: Int
        var tokensOut: Int

        var total: Int { tokensIn + tokensOut }
    }

    private(set) var usage: Usage
    /// Daily token ceiling. When exhausted, the pet gets sleepy.
    var dailyTokens: Int

    /// Degrade ladder: 0 = full, 1 = no conversation tier (use instinct), 2 = asleep.
    var degradeLevel: Int {
        let r = Double(usage.total) / Double(max(dailyTokens, 1))
        if r >= 1.0 { return 2 }
        if r >= 0.85 { return 1 }
        return 0
    }

    init(dailyTokens: Int) {
        self.dailyTokens = dailyTokens
        let today = Budget.todayString()
        if let data = try? Data(contentsOf: Paths.usage),
           let u = try? JSONDecoder().decode(Usage.self, from: data),
           u.date == today {
            usage = u
        } else {
            usage = Usage(date: today, calls: 0, tokensIn: 0, tokensOut: 0)
        }
    }

    static func estimateTokens(_ text: String) -> Int {
        estimateTokens(chars: text.count)
    }

    static func estimateTokens(chars: Int) -> Int {
        max(1, Int(ceil(Double(chars) / 3.2)))
    }

    func record(inputChars: Int, outputChars: Int, tier: ModelTier) {
        rolloverIfNeeded()
        usage.tokensIn += Budget.estimateTokens(chars: inputChars)
        usage.tokensOut += Budget.estimateTokens(chars: outputChars)
        usage.calls += 1
        save()
    }

    func rolloverIfNeeded() {
        let today = Budget.todayString()
        if usage.date != today {
            usage = Usage(date: today, calls: 0, tokensIn: 0, tokensOut: 0)
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(usage) {
            try? data.write(to: Paths.usage)
        }
    }

    private static func todayString() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    /// Compact "k" formatting for the menu (e.g. 12.3k / 300k).
    private static func fmt(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    var statusLine: String {
        "今日 \(Budget.fmt(usage.total)) / \(Budget.fmt(dailyTokens)) tokens · \(usage.calls) 次"
    }
}
