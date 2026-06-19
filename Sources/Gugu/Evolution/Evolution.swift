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
        // 注意:传入的 state 是 await(brain.dream)之前 load 的快照,可能已被
        // 期间的 poke/pet/recordBondGain 写入磁盘的 interactions/bond 增量超过。
        // 这里用 mutate 在 save 前一刻重新 load 最新盘值,避免陈旧快照覆盖。
        // - days_together / events_seen 是累加增量:基于 s. 当前值 += ,绝不基于旧 state。
        // - bond / trust 是从当前状态算出的"绝对值",且经 max 保证单调不减,基于最新 s 计算。
        // - stage 不变(只动 pending_stage),oldStage 也按最新 s.stage 取。
        var oldStage = GrowthStage(rawStage: state.stage)
        var target = oldStage
        var proposal: Proposal?

        try PetState.mutateRequired { s in
            oldStage = GrowthStage(rawStage: s.stage)

            s.days_together += 1
            s.events_seen += eventCount
            s.bond = min(1, max(s.bond, self.inferredBond(from: s)))
            s.trust = min(1, self.inferredTrust(from: s))

            target = self.eligibleStage(for: s)
            if target.order > oldStage.order {
                s.pending_stage = target.rawValue
                // 查重:同一目标形态已有待批提案就不再生成,避免出现多个"长成雏鸟"。
                if !self.stageProposalExists(target: target) {
                    proposal = self.writeStageProposal(from: oldStage, to: target, state: s)
                } else {
                    proposal = nil
                }
            }
        }

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
        appendBond(L.evolvedTo(target.displayName))
        return true
    }

    func pendingProposals() -> [Proposal] {
        pruneExpiredProposals()
        pruneStaleStageProposals()   // 清掉已达成/重复的阶段提案,避免菜单里卡一条点不动的
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

    /// 解析阶段提案文件名里的目标形态:stage-<old>-to-<new>-<时间戳>.md
    private func stageProposalTarget(_ url: URL) -> GrowthStage? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count >= 4, parts[0] == "stage", parts[2] == "to" else { return nil }
        return GrowthStage(rawValue: String(parts[3]))
    }

    /// 是否已存在指向某目标形态的阶段提案(生成时查重用)。
    private func stageProposalExists(target: GrowthStage) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.proposals, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension == "md" && stageProposalTarget($0)?.order == target.order }
    }

    /// 清除过时的阶段提案:目标形态已达到或已超过(重复生成、或已被批准过的残留)。
    /// 这类提案再也无法被批准(没有对应的待定阶段),留着只会在菜单里卡一条点不动的。
    func pruneStaleStageProposals() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.proposals, includingPropertiesForKeys: nil) else { return }
        let current = GrowthStage(rawStage: PetState.load().stage)
        for file in files where file.pathExtension == "md" {
            guard let target = stageProposalTarget(file) else { continue }
            if current.order >= target.order {
                try? fm.removeItem(at: file)
                Audit.record(kind: "proposal.prune", summary: "清除过时阶段提案:\(file.lastPathComponent)",
                             detail: ["current": current.rawValue, "target": target.rawValue])
            }
        }
    }

    private func eligibleStage(for state: PetState) -> GrowthStage {        let current = GrowthStage(rawStage: state.stage)
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
        let title = L.evolutionProposalTitle(new.displayName)
        let url = Paths.proposals.appendingPathComponent("\(id).md")
        let body = """
        # \(title)
        kind: stage
        target: state.json

        \(L.proposalStatusPending)
        \(L.proposalGeneratedAt(ISO8601DateFormatter().string(from: Date())))

        \(L.proposalGrowthReason(old.displayName, new.displayName))

        \(L.proposalMetricsHeader)
        \(L.proposalMetricDays(state.days_together))
        \(L.proposalMetricEvents(state.events_seen))
        \(L.proposalMetricInteractions(state.interactions))
        \(L.proposalMetricBond(String(format: "%.2f", state.bond)))
        \(L.proposalMetricTrust(String(format: "%.2f", state.trust)))
        \(L.proposalMetricSkills(memory.skillCount()))

        \(L.proposalStageFooter)
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
