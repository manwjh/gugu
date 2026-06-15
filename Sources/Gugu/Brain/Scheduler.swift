import Foundation

/// Heartbeat scheduler: threshold-triggered, never polling.
/// Curiosity accumulates from events; a heartbeat fires when over threshold
/// AND not frozen (owner focused) AND min-interval elapsed AND budget allows.
@MainActor
final class Scheduler {
    private let brain: Brain
    private let affect: Affect
    private let rhythmSensor: RhythmSensor
    private let screenSensor: ScreenSensor
    private let budget: Budget
    private var config: Config

    private var lastHeartbeat = Date.distantPast
    private var lastDreamDay = SchedulerState.load().lastDreamDay
    private var timer: Timer?
    private(set) var frozen = false
    private var lastConfigMTime: Date?
    private var heartbeatInFlight = false
    private var dreamInFlight = false

    /// Called with each heartbeat decision so the body can act it out.
    var onDecision: ((HeartbeatDecision) -> Void)?
    /// Called when the pet wakes up from a dream with morning words.
    var onMorning: ((String) -> Void)?
    /// Called when budget forces sleep.
    var onBudgetSleep: (() -> Void)?

    private let curiosityThreshold: Double = 30

    init(brain: Brain, affect: Affect, rhythm: RhythmSensor, screen: ScreenSensor,
         budget: Budget, config: Config) {
        self.brain = brain
        self.affect = affect
        self.rhythmSensor = rhythm
        self.screenSensor = screen
        self.budget = budget
        self.config = config
    }

    func start() {
        lastConfigMTime = configMTime()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// External nudge (poke / chat) can lower the bar but never bypass freeze.
    func requestHeartbeat(force: Bool = false) {
        Task { await evaluate(force: force) }
    }

    private func evaluate(force: Bool = false) async {
        reloadConfigIfNeeded()
        budget.rolloverIfNeeded()

        // nightly dream at 03:00–04:00 (or first eval after)
        maybeDream()

        // freeze while owner is focused — the single biggest cost lever
        let rhythm = rhythmSensor.rhythm
        frozen = config.freezeWhenFocused && (rhythm == .focused || rhythm == .busy)
        if frozen && !force { return }

        // budget gate
        if budget.degradeLevel >= 2 {
            onBudgetSleep?()
            return
        }

        // sleepy hours: pet sleeps, no heartbeats
        if affect.isSleepyTime && !force { return }

        let since = Date().timeIntervalSince(lastHeartbeat)
        if !force {
            guard since >= config.heartbeatMin else { return }
            let overMax = since >= config.heartbeatMax
            let curious = EventBus.shared.curiosity >= curiosityThreshold
            guard curious || overMax else { return }
        }

        guard !heartbeatInFlight else { return }
        heartbeatInFlight = true
        defer { heartbeatInFlight = false }

        do {
            let decision = try await brain.heartbeat(
                rhythm: rhythmSensor.promptLine(),
                screen: screenSensor.promptLine(),
                affect: affect.promptLine(),
                skills: brain.memory.activeSkills(rhythm: rhythm)
            )
            lastHeartbeat = Date()
            EventBus.shared.drainCuriosity()
            Log.info("heartbeat", "mood=\(decision.mood) action=\(decision.action) speech=\(decision.speech.isEmpty ? "-" : decision.speech)")
            brain.memory.appendNote(decision.memoryNote)
            onDecision?(decision)
        } catch {
            Log.info("heartbeat", "失败(发呆): \(error)")
            // failure = the pet just stares into space; L0 keeps living
        }
    }

    private func maybeDream() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 3 && hour < 5, lastDreamDay != today, !dreamInFlight else { return }
        dreamInFlight = true
        Task {
            defer { Task { @MainActor in self.dreamInFlight = false } }
            do {
                if config.dreamUseBatch {
                    if DreamBatchStore.load() != nil {
                        if let state = try await brain.refreshDreamBatchStatus(),
                           let result = try await brain.applyReadyDreamBatch(state) {
                            Log.info("dream", "Batch 梦境应用完成,阶段: \(result.evolutionSummary), 新技能: \(result.newSkill ?? "无"), 提案: \(result.proposalTitle ?? "无")")
                            let taskResults = try await AutonomyTaskQueue().runDue(limit: 5)
                            if !taskResults.isEmpty {
                                Log.info("autonomy", "夜间任务完成 \(taskResults.filter { $0.succeeded }.count)/\(taskResults.count)")
                            }
                            pendingMorningWords = morningWords(from: result)
                            markDreamDone(for: today)
                        }
                    } else {
                        _ = try await brain.submitDreamBatch()
                    }
                    return
                }
                let result = try await brain.dream()
                Log.info("dream", "梦境整理完成,阶段: \(result.evolutionSummary), 新技能: \(result.newSkill ?? "无"), 提案: \(result.proposalTitle ?? "无")")
                let taskResults = try await AutonomyTaskQueue().runDue(limit: 5)
                if !taskResults.isEmpty {
                    Log.info("autonomy", "夜间任务完成 \(taskResults.filter { $0.succeeded }.count)/\(taskResults.count)")
                }
                // morning words delivered when owner returns (cached here)
                pendingMorningWords = morningWords(from: result)
                markDreamDone(for: today)
            } catch {
                Log.info("dream", "梦境失败: \(error)")
            }
        }
    }

    private var pendingMorningWords: String? = nil

    /// Call when owner returns in the morning; delivers dream output once.
    func deliverMorningWordsIfAny() {
        if let words = pendingMorningWords, !words.isEmpty {
            pendingMorningWords = nil
            onMorning?(words)
        }
    }

    /// Manual dream trigger (debug / selftest).
    func dreamNow() async throws -> Brain.DreamResult {
        try await brain.dream()
    }

    private func markDreamDone(for day: String) {
        lastDreamDay = day
        SchedulerState(lastDreamDay: day).save()
    }

    private func reloadConfigIfNeeded() {
        let currentMTime = configMTime()
        guard currentMTime != lastConfigMTime else { return }
        lastConfigMTime = currentMTime
        config = Config.load()
        brain.config = config
        budget.dailyTokens = GrowthStage.adjustedDailyTokens(
            base: config.dailyTokens,
            stage: GrowthStage(rawStage: PetState.load().stage)
        )
        screenSensor.updateBlacklist(config.blacklistApps)
        brain.reloadPersona()
        Log.info("config", "配置已重新加载")
    }

    private func morningWords(from result: Brain.DreamResult) -> String {
        guard let title = result.proposalTitle else { return result.morningWords }
        let prompt = "我梦见自己好像能长大了。\(title),等你批准。"
        guard !result.morningWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return prompt
        }
        return "\(result.morningWords)\n\(prompt)"
    }

    private func configMTime() -> Date? {
        let values = try? Paths.config.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

private struct SchedulerState: Codable {
    var lastDreamDay: String

    static func load() -> SchedulerState {
        if let data = try? Data(contentsOf: Paths.schedulerState),
           let state = try? JSONDecoder().decode(SchedulerState.self, from: data) {
            return state
        }
        return SchedulerState(lastDreamDay: "")
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Paths.schedulerState)
        }
    }
}
