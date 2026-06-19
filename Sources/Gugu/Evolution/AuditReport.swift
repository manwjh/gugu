import Foundation

/// Human-facing audit report. Kept in Evolution (not Kernel) because it reads
/// pending proposals + evolution state to build the summary — i.e. it depends
/// *up* on Evolution/Memory, while `Audit.record` (Kernel) depends on nothing.
extension Audit {
    @MainActor
    static func report(maxEvents: Int = 80) -> URL {
        let todayEvents = readLines(Paths.eventsFile()).suffix(maxEvents)
        let todayAudit = readLines(Paths.auditFile()).suffix(maxEvents)
        let state = PetState.load()
        let proposals = Evolution(memory: Memory()).pendingProposals()
        let usage = (try? String(contentsOf: Paths.usage, encoding: .utf8)) ?? L.auditEmpty

        let body = """
        \(L.auditTitle)

        \(L.auditGeneratedAt(ISO8601DateFormatter().string(from: Date())))

        \(L.auditCurrentState)
        \(L.auditStage(state.stage))
        \(L.auditPendingStage(state.pending_stage ?? L.auditNone))
        \(L.auditDays(state.days_together))
        \(L.auditEventCount(state.events_seen))
        \(L.auditInteractions(state.interactions))
        \(L.auditBond(String(format: "%.2f", state.bond)))
        \(L.auditTrust(String(format: "%.2f", state.trust)))

        \(L.auditProposals)
        \(proposals.isEmpty ? L.auditNone : proposals.map { "- \($0.title) (\($0.id))" }.joined(separator: "\n"))

        \(L.auditEvents)
        \(todayEvents.isEmpty ? L.auditPending : todayEvents.joined(separator: "\n"))

        \(L.auditSection)
        \(todayAudit.isEmpty ? L.auditPending : todayAudit.joined(separator: "\n"))

        \(L.auditUsage)
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
