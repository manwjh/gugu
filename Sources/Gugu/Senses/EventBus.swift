import Foundation

/// A single perceived event. Only text summaries — never raw content.
struct Event: Codable {
    let time: Date
    let kind: String      // app_switch / rhythm / poke / petted / dragged / thrown / return / leave / overtime / chat
    let summary: String   // human-readable line that may be fed to the LLM
    let weight: Int       // curiosity points
}

/// In-memory queue + JSONL persistence (events/YYYY-MM-DD.jsonl).
/// Main-actor bound: all senses and UI post from the main thread.
@MainActor
final class EventBus {
    static let shared = EventBus()
    private(set) var recent: [Event] = []      // ring buffer of recent events
    private(set) var curiosity: Double = 0     // accumulates until heartbeat threshold
    var onPost: ((Event) -> Void)?

    private let iso = ISO8601DateFormatter()

    func post(kind: String, summary: String, weight: Int) {
        let e = Event(time: Date(), kind: kind, summary: summary, weight: weight)
        recent.append(e)
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        curiosity += Double(weight)
        appendToDisk(e)
        Log.info("event", "\(kind) +\(weight) | \(summary)")
        onPost?(e)
    }

    func drainCuriosity() { curiosity = 0 }

    /// Recent events formatted for the heartbeat prompt (last N, compact).
    func promptSummary(limit: Int = 6) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return recent.suffix(limit)
            .map { "[\(df.string(from: $0.time))] \($0.summary)" }
            .joined(separator: "\n")
    }

    private func appendToDisk(_ e: Event) {
        let obj: [String: Any] = [
            "t": iso.string(from: e.time), "kind": e.kind,
            "summary": e.summary, "w": e.weight,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Paths.eventsFile()
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Read today's raw event lines (for the dream job).
    nonisolated static func todayLines() -> [String] {
        guard let text = try? String(contentsOf: Paths.eventsFile(), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
