import Foundation

/// Append-only local audit log for actions that change files, settings, or
/// permissions. It stores only summaries and file paths, never raw sensor data.
enum Audit {
    static func record(kind: String, summary: String, detail: [String: String] = [:]) {
        var obj: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "summary": summary,
        ]
        if !detail.isEmpty { obj["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Paths.auditFile()
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func report(maxEvents: Int = 80) -> URL {
        let todayEvents = readLines(Paths.eventsFile()).suffix(maxEvents)
        let todayAudit = readLines(Paths.auditFile()).suffix(maxEvents)
        let state = PetState.load()
        let proposals = Evolution(memory: Memory()).pendingProposals()
        let usage = (try? String(contentsOf: Paths.usage, encoding: .utf8)) ?? "(暂无)"

        let body = """
        # 咕咕今天看到了什么

        生成时间:\(ISO8601DateFormatter().string(from: Date()))

        ## 当前状态
        - 形态:\(state.stage)
        - 待进化:\(state.pending_stage ?? "无")
        - 相处天数:\(state.days_together)
        - 事件数:\(state.events_seen)
        - 互动数:\(state.interactions)
        - 羁绊:\(String(format: "%.2f", state.bond))
        - 信任:\(String(format: "%.2f", state.trust))

        ## 待批准提案
        \(proposals.isEmpty ? "无" : proposals.map { "- \($0.title) (\($0.id))" }.joined(separator: "\n"))

        ## 今日感知事件
        \(todayEvents.isEmpty ? "暂无" : todayEvents.joined(separator: "\n"))

        ## 今日审计
        \(todayAudit.isEmpty ? "暂无" : todayAudit.joined(separator: "\n"))

        ## 用量
        \(usage)
        """

        let url = Paths.auditDir.appendingPathComponent("today.md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
