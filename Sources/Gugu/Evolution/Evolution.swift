import Foundation

/// Local growth rules. This is deliberately file-based and conservative:
/// memory/skills can grow automatically, but capability/persona changes only
/// become proposal files for the owner to approve.
@MainActor
final class Evolution {
    struct Settlement {
        let stageChanged: Bool
        let oldStage: String
        let newStage: String
        let proposal: Proposal?

        var summary: String {
            if stageChanged {
                return "\(oldStage)→\(newStage)"
            }
            return newStage
        }
    }

    struct Proposal {
        let id: String
        let title: String
        let path: URL
    }

    private let memory: Memory

    init(memory: Memory) {
        self.memory = memory
    }

    /// Apply nightly experience settlement and generate approval proposals for
    /// stage changes. It never silently unlocks stronger capabilities.
    func settleAfterDream(state: PetState, eventCount: Int) -> Settlement {
        do {
            return try settleAfterDreamRequired(state: state, eventCount: eventCount)
        } catch {
            Log.info("evolution", "夜间结算保存失败:\(error)")
            Audit.record(kind: "evolution.settle_failed", summary: "夜间成长结算失败",
                         detail: ["error": "\(error)"])
            let current = GrowthStage(rawStage: state.stage).displayName
            return Settlement(stageChanged: false, oldStage: current, newStage: current, proposal: nil)
        }
    }

    func settleAfterDreamRequired(state: PetState, eventCount: Int) throws -> Settlement {
        var next = state
        let oldStage = GrowthStage(rawStage: state.stage)

        next.days_together += 1
        next.events_seen += eventCount
        next.bond = min(1, max(next.bond, inferredBond(from: state)))
        next.trust = min(1, inferredTrust(from: next))

        let target = eligibleStage(for: next)
        var proposal: Proposal?
        if target.order > oldStage.order {
            next.pending_stage = target.rawValue
            proposal = writeStageProposal(from: oldStage, to: target, state: next)
        }

        try next.saveRequired()
        pruneExpiredProposals()

        return Settlement(
            stageChanged: target.order > oldStage.order,
            oldStage: oldStage.displayName,
            newStage: target.order > oldStage.order ? target.displayName : oldStage.displayName,
            proposal: proposal
        )
    }

    /// Owner approval hook for future UI. It only promotes a stage that was
    /// already recorded as pending by settlement.
    func approvePendingStage() -> Bool {
        var state = PetState.load()
        guard let pending = state.pending_stage,
              let target = GrowthStage(rawValue: pending),
              GrowthStage(rawStage: state.stage) != target else { return false }
        state.stage = target.rawValue
        state.pending_stage = nil
        do {
            try state.saveRequired()
        } catch {
            Log.info("evolution", "批准进化保存失败:\(error)")
            return false
        }
        appendBond("主人批准咕咕长成了\(target.displayName)。")
        return true
    }

    func pendingProposals() -> [Proposal] {
        pruneExpiredProposals()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.proposals, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let title = proposalTitle(at: url) else { return nil }
                return Proposal(id: url.deletingPathExtension().lastPathComponent, title: title, path: url)
            }
    }

    func pruneExpiredProposals(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Paths.proposals,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-7 * 86400)
        for file in files where file.pathExtension == "md" {
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? now
            if date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func eligibleStage(for state: PetState) -> GrowthStage {
        let current = GrowthStage(rawStage: state.stage)
        let skillCount = memory.skillCount()
        let highest: GrowthStage

        if current.order < GrowthStage.spirit.order,
           state.days_together >= 60,
           state.trust >= 0.8,
           state.bond >= 0.6,
           skillCount >= 8 {
            highest = .spirit
        } else if current.order < GrowthStage.adult.order,
                  state.days_together >= 14,
                  state.events_seen >= 500,
                  state.interactions >= 50,
                  skillCount >= 3 {
            highest = .adult
        } else if current.order < GrowthStage.fledgling.order,
                  state.events_seen >= 100 || state.interactions >= 10 {
            highest = .fledgling
        } else {
            highest = current
        }

        guard highest.order > current.order,
              let next = GrowthStage.allCases.first(where: { $0.order == current.order + 1 }) else {
            return current
        }
        return next
    }

    private func inferredBond(from state: PetState) -> Double {
        let interactionScore = min(0.4, Double(state.interactions) / 250.0)
        let dayScore = min(0.25, Double(state.days_together) / 240.0)
        return max(state.bond, 0.1 + interactionScore + dayScore)
    }

    private func inferredTrust(from state: PetState) -> Double {
        let skillScore = min(0.25, Double(memory.skillCount()) / 40.0)
        let dayScore = min(0.25, Double(state.days_together) / 240.0)
        let bondScore = min(0.3, state.bond * 0.3)
        return max(state.trust, 0.2 + skillScore + dayScore + bondScore)
    }

    private func writeStageProposal(from old: GrowthStage, to new: GrowthStage, state: PetState) -> Proposal {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let id = "stage-\(old.rawValue)-to-\(new.rawValue)-\(df.string(from: Date()))"
        let title = "请求长成\(new.displayName)"
        let url = Paths.proposals.appendingPathComponent("\(id).md")
        let body = """
        # \(title)
        kind: stage
        target: state.json

        状态:待主人批准
        生成时间:\(ISO8601DateFormatter().string(from: Date()))

        咕咕觉得自己从\(old.displayName)长到\(new.displayName)的条件已经接近成熟。

        当前指标:
        - 相处天数:\(state.days_together)
        - 见过事件:\(state.events_seen)
        - 互动次数:\(state.interactions)
        - 羁绊:\(String(format: "%.2f", state.bond))
        - 信任:\(String(format: "%.2f", state.trust))
        - 技能数:\(memory.skillCount())

        需要主人确认后才会生效。批准后只提升阶段;记忆、安全内核和现有边界保持不变。
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return Proposal(id: id, title: title, path: url)
    }

    private func proposalTitle(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)) }
    }

    private func appendBond(_ line: String) {
        let url = Paths.memoryDir.appendingPathComponent("bond.md")
        let date = ISO8601DateFormatter().string(from: Date())
        let entry = "- \(date) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: entry.data(using: .utf8)!)
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
