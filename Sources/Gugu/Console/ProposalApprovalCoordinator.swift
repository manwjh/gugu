import AppKit
import GuguKernel

/// Approving evolution proposals: opens the proposals folder, applies an approved
/// proposal file, then refreshes everything (config out via app.reloadConfigFromDisk,
/// growth celebration, learned-move replay, EventBus, menu refresh).
///
/// Console keeps thin @objc shells (menu items target the Console instance) that
/// forward into this coordinator.
@MainActor
final class ProposalApprovalCoordinator {
    private weak var app: GuguApp?

    init(app: GuguApp?) {
        self.app = app
    }

    func openProposals() {
        NSWorkspace.shared.open(Paths.proposals)
    }

    func approveNextProposal() {
        guard let app else { return }
        if let proposal = Evolution(memory: app.brain.memory).pendingProposals().first {
            approve(at: proposal.path)
        }
    }

    /// 批准指定提案文件并刷新一切相关状态。供"批准下一个"与"逐条批准"共用。
    func approve(at path: URL) {
        guard let app else { return }
        do {
            let applied = try ProposalEngine().applyApprovedProposal(at: path)
            app.reloadConfigFromDisk()   // 唯一出口:config + brain + persona + 黑名单 + budget + L.current
            if let newStage = applied.newStage {
                app.pet.celebrateEvolution(to: newStage)
            } else {
                app.pet.say(L.proposalApproved(applied.title))
            }
            // 学会新动作:计入进度(驱动里程碑),并立刻演一遍给主人看。
            if path.lastPathComponent.hasPrefix("move-") {
                app.afterInteraction(.learnedMove, surface: false)
                let moveName = applied.target.deletingPathExtension().lastPathComponent
                if MoveLibrary.shared.move(named: moveName) != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak app] in
                        app?.pet.perform(action: moveName)
                    }
                }
            }
            EventBus.shared.post(kind: "proposal", summary: L.eventProposalApproved(applied.title), weight: 25)
        } catch {
            app.pet.say(L.proposalFailed)
            Log.info("proposal", "批准失败: \(error)")
        }
        app.console?.refreshMenu()
    }
}
