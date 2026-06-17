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

    // 灵光额度跟踪(按天滚动)。
    private var sparkDay = ""
    private var sparkUsedToday = 0
    private var lastSparkAt = Date.distantPast

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

        // Nightly dream distills the previous memory day. If the app was not
        // running at 03:00–05:00, the first later evaluation catches up.
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

        // 灵光择机:在抽干好奇心之前,基于当下好奇心 + 每日额度/冷却,决定要不要借更强的脑子。
        let curiosityNow = EventBus.shared.curiosity
        let useSpark = decideSpark(curiosity: curiosityNow)

        do {
            let decision = try await brain.heartbeat(
                rhythm: rhythmSensor.promptLine(),
                screen: screenSensor.promptLine(),
                affect: affect.promptLine(),
                skills: brain.memory.activeSkills(rhythm: rhythm),
                useSpark: useSpark
            )
            lastHeartbeat = Date()
            EventBus.shared.drainCuriosity()
            if useSpark { recordSparkUse() }
            Log.info("heartbeat", "mood=\(decision.mood) action=\(decision.action)\(useSpark ? " ✨spark" : "") speech=\(decision.speech.isEmpty ? "-" : decision.speech)")
            brain.memory.appendNote(decision.memoryNote)
            onDecision?(decision)
        } catch {
            Log.info("heartbeat", "失败(发呆): \(error)")
            // failure = the pet just stares into space; L0 keeps living
        }
    }

    /// 灵光额度按天滚动:跨天清零。
    private func rolloverSparkIfNeeded() {
        let today = Memory.dayString(for: Date())
        if sparkDay != today {
            sparkDay = today
            sparkUsedToday = 0
        }
    }

    private func decideSpark(curiosity: Double) -> Bool {
        rolloverSparkIfNeeded()
        return SparkPolicy.shouldSpark(.init(
            enabled: config.sparkEnabled,
            curiosity: curiosity,
            heartbeatThreshold: curiosityThreshold,
            usedToday: sparkUsedToday,
            dailyLimit: config.sparkDailyLimit,
            secondsSinceLastSpark: Date().timeIntervalSince(lastSparkAt),
            cooldown: config.sparkCooldown
        ))
    }

    private func recordSparkUse() {
        rolloverSparkIfNeeded()
        sparkUsedToday += 1
        lastSparkAt = Date()
    }

    private func maybeDream() {        guard let targetDate = dreamTargetDate(), !dreamInFlight else { return }
        let memoryDay = Memory.dayString(for: targetDate)
        guard lastDreamDay != memoryDay else { return }
        dreamInFlight = true
        Task {
            defer { Task { @MainActor in self.dreamInFlight = false } }
            do {
                if config.dreamUseBatch {
                    if DreamBatchStore.load() != nil {
                        if let state = try await brain.refreshDreamBatchStatus(),
                           let result = try await brain.applyReadyDreamBatch(state) {
                            Log.info("dream", "Batch 梦境应用完成,阶段: \(result.evolutionSummary), 新技能: \(result.newSkill ?? "无"), 提案: \(result.proposalTitle ?? "无")")
                            await runDueAutonomyTasks()
                            pendingMorningWords = morningWords(from: result)
                            markDreamDone(for: state.memoryDay)
                        }
                    } else {
                        _ = try await brain.submitDreamBatch(for: targetDate)
                    }
                    return
                }
                let result = try await brain.dream(for: targetDate)
                Log.info("dream", "梦境整理完成,阶段: \(result.evolutionSummary), 新技能: \(result.newSkill ?? "无"), 提案: \(result.proposalTitle ?? "无")")
                await runDueAutonomyTasks()
                // morning words delivered when owner returns (cached here)
                pendingMorningWords = morningWords(from: result)
                markDreamDone(for: memoryDay)
            } catch {
                Log.info("dream", "梦境失败: \(error)")
            }
        }
    }

    private var pendingMorningWords: String? = nil

    /// Run owner-approved deferred tasks for real (via the local tool layer),
    /// not the offline stub. Failures (e.g. permission off) are recorded by the
    /// queue's audit trail rather than silently marked done.
    private func runDueAutonomyTasks() async {
        do {
            let queue = AutonomyTaskQueue(runner: AutonomyTaskQueue.toolRunner(config: config))
            let results = try await queue.runDue(limit: 5)
            if !results.isEmpty {
                Log.info("autonomy", "夜间任务完成 \(results.filter { $0.succeeded }.count)/\(results.count)")
            }
        } catch {
            Log.info("autonomy", "夜间任务执行失败: \(error)")
        }
    }

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

    private func dreamTargetDate(now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        let yesterdayKey = Memory.dayString(for: yesterday)
        guard lastDreamDay != yesterdayKey else { return nil }

        if (3..<5).contains(hour) {
            return yesterday
        }
        if hour >= 5, hasDreamMaterial(for: yesterday) {
            return yesterday
        }
        return nil
    }

    private func hasDreamMaterial(for date: Date) -> Bool {
        !EventBus.lines(for: date).isEmpty || !brain.memory.notes(for: date).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reloadConfigIfNeeded() {
        let currentMTime = configMTime()
        guard currentMTime != lastConfigMTime else { return }
        lastConfigMTime = currentMTime
        config = Config.load()
        brain.config = config
        L.current = config.language == "zh" ? .zh : .en
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
        let prompt = L.dreamProposal(title)
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
    var schemaVersion: Int = 2
    var lastDreamDay: String

    static func load() -> SchedulerState {
        if let data = try? Data(contentsOf: Paths.schedulerState),
           let state = try? JSONDecoder().decode(SchedulerState.self, from: data) {
            return state
        }
        return SchedulerState(lastDreamDay: "")
    }

    func save() {
        var current = self
        current.schemaVersion = 2
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: Paths.schedulerState)
        }
    }
}

private extension SchedulerState {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastDreamDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let storedDay = try c.decodeIfPresent(String.self, forKey: .lastDreamDay) ?? ""
        // Version 1 stored the calendar day when the dream ran. Version 2
        // stores the memory day that was distilled, so old values cannot be
        // compared safely.
        lastDreamDay = schemaVersion >= 2 ? storedDay : ""
    }
}
