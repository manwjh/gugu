import AppKit
import Foundation

/// App composition root: wires senses → affect → scheduler → brain → body.
@MainActor
final class GuguApp: NSObject, NSApplicationDelegate {
    var config: Config!
    var pet: PetController!
    var home: HomeController!
    var brain: Brain!
    var budget: Budget!
    var affect: Affect!
    var rhythmSensor: RhythmSensor!
    var screenSensor: ScreenSensor!
    var visionSensor: VisionSensor!
    var voice: Voice!
    var listener: Listener!
    var scheduler: Scheduler!
    var console: Console!
    var visionDebug: VisionDebugWindow!
    private var minuteTimer: Timer?
    private var perceptionTimer: Timer?

    /// 本次会话是否已经吐过一条引导提示(每次启动至多一条,避免话痨)。
    private var hintShownThisSession = false
    /// 上次"软提示"(引导/里程碑)的时间,做个全局冷却。
    private var lastSoftPromptAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        L.current = config.language == "zh" ? .zh : .en
        let state = PetState.load()
        budget = Budget(dailyTokens: GrowthStage.adjustedDailyTokens(base: config.dailyTokens,
                                                                     stage: GrowthStage(rawStage: state.stage)))
        affect = Affect()

        brain = Brain(config: config, budget: budget)
        rhythmSensor = RhythmSensor()
        screenSensor = ScreenSensor(blacklist: config.blacklistApps)
        visionSensor = VisionSensor()
        voice = Voice()
        listener = Listener()
        scheduler = Scheduler(brain: brain, affect: affect, rhythm: rhythmSensor,
                              screen: screenSensor, budget: budget, config: config)
        pet = PetController()
        pet.refreshGrowthStage()
        home = HomeController()
        home.onFrameChange = { [weak self] frame in self?.pet.updateHomeFrame(frame) }
        home.onPlatformsChange = { [weak self] platforms in self?.pet.updatePlatforms(platforms) }
        console = Console(app: self)
        visionDebug = VisionDebugWindow()
        visionDebug.previewProvider = { [weak self] in self!.visionSensor.makePreviewLayer() }
        pet.onStateChange = { [weak self] _ in
            self?.console.refreshMenu()
        }

        wire()

        if config.senseInputRhythm { rhythmSensor.start() }
        if config.senseScreen { screenSensor.start() }
        visionSensor.startIfPossible()   // no-op unless owner enabled it
        listener.startIfPossible()       // no-op unless owner enabled it
        scheduler.start()
        startMinuteLoop()
        startPerceptionLoop()
        Paths.pruneOldEvents()

        Log.info("app", "咕咕醒了。\(budget.statusLine)")
        EventBus.shared.post(kind: "wake", summary: L.eventWake, weight: 10)

        // Check if API key is configured (gentle nudge for first-time users)
        let needsSetup = config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty

        // immediate local greeting (zero-cost): warmer if we already know the owner
        let state0 = PetState.load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let greeting: String
            if needsSetup && state0.days_together <= 0 {
                // First-time user without API key: friendly setup hint
                greeting = L.greetingNeedsSetup
            } else if state0.days_together <= 0 {
                greeting = L.greetingNew
            } else if state0.bond > 0.5 {
                greeting = L.greetingBonded
            } else {
                greeting = L.greetingDefault
            }
            self.pet.say(greeting)
            self.pet.bird.flapWings(times: 2)
        }

        // first real heartbeat shortly after (forced past freeze)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.scheduler.requestHeartbeat(force: true)
        }
    }

    private func wire() {
        // 说话时朗读(若用户开了 TTS)
        pet.speakAloud = { [weak self] text, mood in self?.voice.speak(text, mood: mood) }
        voice.onWillSpeak = { [weak self] text in
            let seconds = min(8.0, max(1.4, Double(text.count) * 0.16 + 0.9))
            self?.listener.suppressInput(for: seconds)
            Perception.shared.setSpeaking(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { Perception.shared.setSpeaking(false) }
        }

        // 听到唤醒词后的语音指令 → 走对话链路(和打字聊天同一路径)
        listener.onWake = { [weak self] in
            self?.pet.bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pet.bird.tiltHead(false) }
        }
        listener.onCommand = { [weak self] command in
            self?.handleVoiceCommand(command)
        }
        listener.onStateChange = { [weak self] status in
            self?.handleListenerStatus(status)
        }

        // heartbeat decisions → body acts them out
        scheduler.onDecision = { [weak self] decision in
            guard let self else { return }
            self.pet.perform(action: decision.action)
            if !decision.speech.isEmpty {
                self.pet.say(decision.speech, mood: decision.mood)
            }
            self.console.refreshMenu()
        }
        scheduler.onMorning = { [weak self] words in
            self?.pet.say(words)
        }
        scheduler.onBudgetSleep = { [weak self] in
            guard let self, !self.pet.isSleeping else { return }
            self.pet.say(L.budgetSleepy)
            self.pet.sleep()
        }
        // 调度器发现 config.yaml 文件变了 → 走唯一出口应用副作用(它自己不再越权管理)
        scheduler.onConfigFileChanged = { [weak self] in self?.reloadConfigFromDisk() }

        // direct interactions → affect + events (+ maybe a quick heartbeat)
        pet.onPoke = { [weak self] in
            guard let self else { return }
            self.affect.poked()
            EventBus.shared.post(kind: "poke", summary: L.eventPoke, weight: 20)
            PetState.mutate { $0.interactions += 1 }
            self.afterInteraction(.poke)
        }
        pet.onPet = { [weak self] in
            guard let self else { return }
            self.affect.petted()
            EventBus.shared.post(kind: "petted", summary: L.eventPetted, weight: 22)
            PetState.mutate { $0.interactions += 1; $0.bond = min(1, $0.bond + Affect.bondGainPetted) }
            self.afterInteraction(.pet)
        }
        pet.onThrown = { [weak self] in
            guard let self else { return }
            self.affect.thrown()
            EventBus.shared.post(kind: "thrown", summary: L.eventThrown, weight: 25)
            self.afterInteraction(.throwOut)
        }
        pet.menuProvider = { [weak self] in
            self?.console.buildQuickMenu() ?? NSMenu()
        }
        // idle 自娱自乐:读取当下心情 + 偶尔挑一个学会/内置动作来玩
        pet.idleMoodProvider = { [weak self] in
            guard let self else { return (energy: 0.7, valence: 0.15) }
            return (energy: self.affect.energy, valence: self.affect.valence)
        }
        pet.idlePlayMoveProvider = {
            MoveLibrary.shared.moves.randomElement()?.name
        }
        // idle 自发情绪流露:大多沉默,偶尔按当下 affect 冒一个漫符,让心情"看得见"。
        pet.idleManpuProvider = { [weak self] in
            guard let self else { return nil }
            let roll = Double.random(in: 0...1)
            if roll > 0.12 { return nil }                       // ~12% 才流露,避免刷屏
            if self.affect.isGrudging { return .anger }         // 还在气头上
            if self.affect.energy < 0.3 { return .sweat }       // 累了
            if self.affect.valence > 0.45 {                     // 心情很好:哼唱或冒心
                return roll < 0.05 ? .music : .love
            }
            return nil
        }

        // rhythm transitions wake/greet behavior
        rhythmSensor.onRhythmChange = { [weak self] old, new in
            guard let self else { return }
            if old == .away && new != .away {
                // owner returned: deliver morning words if a dream is pending
                self.affect.ownerReturned()
                if self.pet.isSleeping && !self.affect.isSleepyTime { self.pet.wake() }
                self.scheduler.deliverMorningWordsIfAny()
            }
            if new == .away && !self.pet.isSleeping {
                // nobody is watching: live a little, nap a little
                if Double.random(in: 0...1) < 0.4 { self.pet.sleep() }
            }
            self.console.refreshMenu()
        }

        // vision (opt-in): presence + smile → events the bird can react to.
        // 注:连续感知(在座/表情/手型/手位/物品)统一走 onFrame → Perception;
        // 下面这些回调只负责"反射动作 + 事件流",不再各自喂 Perception(消除碎片化)。
        visionSensor.onPresence = { [weak self] present in
            guard let self else { return }
            if present {
                self.affect.ownerReturned()
                if self.pet.isSleeping && !self.affect.isSleepyTime { self.pet.wake() }
                EventBus.shared.post(kind: "see_return", summary: L.eventSeeReturn, weight: 28)
            } else {
                EventBus.shared.post(kind: "see_leave", summary: L.eventSeeLeave, weight: 5)
            }
        }
        visionSensor.onSmile = { [weak self] in
            guard let self else { return }
            self.affect.petted()  // a smile warms the bird like a pat
            self.pet.bird.showBlush(true)
            self.pet.bird.showManpu(.love)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pet.bird.showBlush(false) }
            EventBus.shared.post(kind: "see_smile", summary: L.eventSeeSmile, weight: 18)
        }
        visionSensor.onExpression = { expression in
            switch expression {
            case .smile:
                break // onSmile keeps the legacy smile behavior.
            case .surprised:
                EventBus.shared.post(kind: expression.eventKind, summary: expression.summary, weight: 10)
            case .sleepy:
                EventBus.shared.post(kind: expression.eventKind, summary: expression.summary, weight: 12)
            }
        }
        visionSensor.onGesture = { [weak self] gesture in
            guard let self else { return }
            switch gesture {
            case .wave:
                self.pet.bird.flapWings(times: 4)
            case .thumbsUp, .ok:
                self.pet.bird.showBlush(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.pet.bird.showBlush(false) }
            case .openPalm:
                self.pet.bird.tiltHead(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pet.bird.tiltHead(false) }
            case .pointing:
                self.pet.bird.peckOnce()
            case .flyUp:
                self.pet.flyUpward()              // 手向上挥 → 真的朝上飞一段(方向对应手势)
                self.pet.bird.showManpu(.surprise)
            }
            EventBus.shared.post(kind: gesture.eventKind, summary: gesture.summary, weight: 16)
        }
        // 物品:不再逐个常驻上报(背景里的笔记本/键盘会刷屏、稀释主人模型)。
        // 改由下面 onVideoEvent 的"新出现/移动/消失"(新颖度)触发,只在变化时反应。
        visionSensor.onVideoEvent = { [weak self] event, label in
            guard let self else { return }
            switch event {
            case .personApproached:
                if self.pet.isSleeping && !self.affect.isSleepyTime { self.pet.wake() }
                self.pet.bird.tiltHead(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pet.bird.tiltHead(false) }
            case .personMovedAway:
                self.pet.bird.flapWings(times: 2)
            case .personMovedLeft, .personMovedRight:
                break
            case .handReachedTowardCamera:
                self.pet.bird.flapWings(times: 5, fast: true)
            case .objectAppeared:
                // 按"有意思程度"分级反应:动物→吃一惊、食物/杯子→啄、其它新东西→好奇。
                let l = label ?? ""
                if ["猫", "狗", "鸟"].contains(l) {
                    self.pet.bird.showManpu(.surprise)
                    self.pet.bird.tiltHead(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pet.bird.tiltHead(false) }
                } else if ["杯子", "碗", "香蕉", "苹果", "橙子"].contains(l) {
                    self.pet.bird.peckOnce()
                } else {
                    self.pet.bird.showManpu(.question)
                }
            case .objectDisappeared, .objectMoved:
                break
            }
            let weight: Int
            switch event {
            case .handReachedTowardCamera: weight = 18
            case .personApproached, .personMovedAway: weight = 12
            case .personMovedLeft, .personMovedRight: weight = 6
            case .objectAppeared:
                let l = label ?? ""
                if ["猫", "狗", "鸟"].contains(l) { weight = 16 }                       // 动物最有意思
                else if ["杯子", "碗", "香蕉", "苹果", "橙子", "手机", "书"].contains(l) { weight = 11 }  // 手持常见物
                else { weight = 8 }
            case .objectDisappeared, .objectMoved: weight = 8
            }
            EventBus.shared.post(kind: event.eventKind, summary: event.summary(label: label), weight: weight)
        }
        // 每帧连续快照:视觉感知的唯一入口。喂 Perception(语义已平滑)+ 调试窗口。
        visionSensor.onFrame = { [weak self] f in
            guard let self else { return }
            Perception.shared.updateVision(present: f.ownerPresent, expression: f.expression,
                                           gesture: f.gesture, handX: f.handX,
                                           objectsNow: f.objectsNow)
            self.visionDebug.update(f)
        }
    }

    /// 打开/关闭视觉调试窗口(实时看摄像头的原始识别数值)。
    func toggleVisionDebug() {
        visionDebug.toggle()
        console.refreshMenu()
    }

    /// 语音指令(听到"咕咕"后那一句)→ 和打字聊天同一条对话链路。
    private func handleVoiceCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Perception.shared.heardOrTyped(trimmed, via: "说")
        EventBus.shared.post(kind: "voice", summary: L.eventVoice(String(trimmed.prefix(40))), weight: 0)
        affect.chatted()
        PetState.recordBondGain(Affect.bondGainChatted)
        afterChat()
        if pet.isSleeping { pet.wake() }
        pet.bird.tiltHead(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pet.bird.tiltHead(false) }
        if let local = brain.handleLocalCommand(trimmed) {
            if local.action != "idle" { pet.perform(action: local.action) }
            if !local.reply.isEmpty { pet.say(local.reply) }
            return
        }
        if tryStartLearnMove(trimmed) { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.brain.chat(trimmed,
                                                       rhythmLine: self.rhythmSensor.promptLine(),
                                                       mood: self.affect.promptLine(),
                                                       localCapabilities: self.localCapabilitiesContext())
                if result.action != "idle" { self.pet.perform(action: result.action) }
                // 避免双重声音:如果动作包含 say 步骤,让动作自己说话,不再朗读 reply
                let actionHasSpeech = self.actionContainsSay(result.action)
                if !result.reply.isEmpty && !actionHasSpeech {
                    self.pet.say(result.reply)
                }
            } catch {
                Log.info("voice", "对话失败: \(error)")
                let msg = Brain.userMessage(for: error, config: self.brain.config)
                self.pet.say(msg)
            }
        }
    }

    /// 主人想教咕咕一个新动作时的入口(打字/语音共用)。
    /// 命中则启动"学习"链路:模型出草稿 → 生成 move_add 提案 → 它开口请主人批准。
    /// 返回 true 表示已接管,调用方不必再走普通对话。
    func tryStartLearnMove(_ text: String) -> Bool {
        guard let intent = LearnMoveParser.parse(text) else { return false }
        Log.info("learn_move", "识别到学习请求,意图:\(intent)")
        // 已经会了就直接演,不重复学。
        if let existing = MoveLibrary.shared.move(named: intent)
            ?? MoveLibrary.shared.matchTrigger(in: intent) {
            pet.say(L.learnAlreadyKnow)
            pet.perform(action: existing.name)
            return true
        }
        pet.bird.tiltHead(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.pet.bird.tiltHead(false) }
        pet.say(L.learnTrying(intent))
        Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await self.brain.learnMove(intent: intent)
                guard draft.feasible, !draft.move.steps.isEmpty else {
                    Log.info("learn_move", "放弃:feasible=\(draft.feasible) steps=\(draft.move.steps.count)")
                    self.pet.bird.showManpu(.question)   // 没整明白怎么做:困惑
                    self.pet.say(L.learnCantDo)
                    return
                }
                let proposalURL = try ProposalEngine().writeMoveProposal(draft.move)
                Log.info("learn_move", "已生成提案:\(proposalURL.lastPathComponent)")
                EventBus.shared.post(kind: "learn_move",
                                     summary: "咕咕想学会「\(draft.move.name)」,生成了待批准提案",
                                     weight: 15)
                self.pet.say(L.learnGotDraft(draft.move.name))
                self.console.refreshMenu()
            } catch {
                Log.info("learn_move", "学习失败: \(error)")
                let msg = Brain.userMessage(for: error, config: self.brain.config)
                self.pet.say(msg)
            }
        }
        return true
    }

    /// 检查动作是否包含 say 步骤(用于避免双重声音)。
    private func actionContainsSay(_ actionName: String) -> Bool {
        guard let move = MoveLibrary.shared.move(named: actionName) else { return false }
        return move.steps.contains { $0.op == "say" }
    }

    /// 互动类型,驱动进度计数 + 引导/里程碑。
    enum InteractionKind { case poke, pet, throwOut, chat, learnedMove }

    /// 每次互动后:更新软进度计数,然后**择机**冒一个里程碑或一条引导提示。
    /// 里程碑优先(更有奖励感);其次引导;大多数时候什么都不冒。全本地零成本。
    /// `surface=false` 只记账不冒泡(用于聊天——回复本身已经是响应,避免抢话)。
    func afterInteraction(_ kind: InteractionKind, surface: Bool = true) {
        var progress = ProgressState.load()
        switch kind {
        case .poke: progress.pokeCount += 1
        case .pet: progress.petCount += 1
        case .throwOut: progress.throwCount += 1
        case .chat: progress.chatCount += 1
        case .learnedMove: progress.movesLearned += 1
        }
        progress.save()

        guard surface else { return }

        // 里程碑:跨过阈值就庆祝(高水位保证只一次)。摔出去那一下不庆祝(它在生气)。
        if kind != .throwOut {
            let petState = PetState.load()
            let reached = Milestones.newlyReached(progress: progress, state: petState)
            if let m = reached.first {
                for r in reached { progress.markMilestoneReached(r.id) }
                progress.save()
                celebrateMilestone(m)
                return
            }
        }

        // 引导:每会话至多一条、全局冷却 ≥45s、被生气时不提。
        maybeShowHint(progress: progress, suppress: kind == .throwOut)
    }

    /// 聊天后单独调用:记一次聊天,并在稍后(不抢回复)择机冒一个里程碑。
    func afterChat() {
        afterInteraction(.chat, surface: false)
        // 给聊天回复留出时间,再看看有没有里程碑要庆祝。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            let progress = ProgressState.load()
            let reached = Milestones.newlyReached(progress: progress, state: PetState.load())
            guard let m = reached.first else { return }
            var p = progress
            for r in reached { p.markMilestoneReached(r.id) }
            p.save()
            self.celebrateMilestone(m)
        }
    }

    private func celebrateMilestone(_ m: Milestone) {
        lastSoftPromptAt = Date()
        pet.bird.showBlush(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.pet.bird.showBlush(false) }
        if let move = m.move, MoveLibrary.shared.move(named: move) != nil {
            pet.perform(action: move)
        } else {
            pet.bird.flapWings(times: 3)
        }
        pet.say(m.words)
        EventBus.shared.post(kind: "milestone", summary: "里程碑:\(m.id) — \(m.words)", weight: 0)
    }

    private func maybeShowHint(progress: ProgressState, suppress: Bool) {
        guard !suppress, !hintShownThisSession else { return }
        guard Date().timeIntervalSince(lastSoftPromptAt) > 45 else { return }
        guard !affect.isGrudging, !pet.isSleeping else { return }
        guard let hint = Discovery.nextHint(progress) else { return }
        hintShownThisSession = true
        lastSoftPromptAt = Date()
        var p = progress
        p.markHintShown(hint.id)
        p.save()
        pet.bird.tiltHead(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.pet.bird.tiltHead(false) }
        pet.say(hint.text)
    }

    func setVoiceConversationEnabled(_ enabled: Bool) {        if enabled {
            if !voice.enabled {
                voice.enabled = true
            }
            listener.enabled = true
            pet.bird.setViewDirection(.front)
            pet.bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.pet.bird.tiltHead(false) }
        } else {
            listener.enabled = false
            voice.stop()
            pet.say(L.stopListening)
        }
    }

    private func handleListenerStatus(_ status: ListenerStatus) {
        console.refreshMenu()
        switch status {
        case .listening:
            pet.bird.setViewDirection(.front)
            pet.bird.tiltHead(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pet.bird.tiltHead(false) }
        case .unavailable(let reason):
            pet.say(L.micUnavailable + reason)
        default:
            break
        }
    }

    private func startMinuteLoop() {
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.affect.tickMinute()
                // 疲惫时偶尔冒一颗汗滴(醒着、有人在看才显,避免空播)
                if !self.pet.isSleeping && self.affect.energy < 0.3
                    && self.rhythmSensor.rhythm != .away && Double.random(in: 0...1) < 0.3 {
                    self.pet.bird.showManpu(.sweat)
                }
                // night sleep: pet sleeps during sleepy hours regardless of budget
                if self.affect.isSleepyTime && !self.pet.isSleeping {
                    self.pet.sleep()
                } else if !self.affect.isSleepyTime && self.pet.isSleeping
                            && self.budget.degradeLevel < 2
                            && self.rhythmSensor.rhythm != .away {
                    self.pet.wake()
                }
            }
        }
        RunLoop.main.add(minuteTimer!, forMode: .common)
    }

    /// 每 ~2.5s 刷新感知上下文里的环境型字段(鼠标/咕咕世界/电脑本体/情绪)。
    private func startPerceptionLoop() {
        perceptionTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let g = self.pet.window.frame
                let m = NSEvent.mouseLocation
                let nearGugu = hypot(m.x - g.midX, m.y - g.midY) < 140
                Perception.shared.setListening(self.listener.enabled)
                Perception.shared.tickAmbient(
                    mouseNearGugu: nearGugu,
                    guguState: self.pet.state.rawValue,
                    guguInRoom: self.pet.isInHome,
                    frontApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                    rhythm: self.rhythmSensor.rhythm.displayName,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    energy: self.affect.energy,
                    valence: self.affect.valence)
            }
        }
        RunLoop.main.add(perceptionTimer!, forMode: .common)
    }

    /// 打开/关闭小窝:开则咕咕飞入并被限制在框内;关则咕咕飞回桌面。
    func toggleHome() {
        if home.isOpen {
            pet.leaveHome()
            home.close()
        } else {
            home.open()
            pet.updatePlatforms(home.platforms)   // 同步上次画的平台
            pet.enterHome(frame: home.frame)
            maybeShowHomeHint()
        }
        console.refreshMenu()
    }

    /// 首次进入小窝且还没画过平台时,引导一次画笔用法(只一次,记在 UserDefaults)。
    private func maybeShowHomeHint() {
        guard home.platforms.isEmpty,
              !UserDefaults.standard.bool(forKey: "gugu.homeHintShown") else { return }
        UserDefaults.standard.set(true, forKey: "gugu.homeHintShown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.pet.say(L.homeHint)
        }
    }

    func localCapabilitiesContext() -> String {
        Brain.localCapabilitiesContext(
            cameraEnabled: visionSensor.enabled,
            localObjectRecognitionAvailable: visionSensor.objectModelLoaded,
            listeningEnabled: listener.enabled,
            voiceEnabled: voice.enabled
        )
    }

    func refreshGrowthState() {
        let stage = GrowthStage(rawStage: PetState.load().stage)
        budget.dailyTokens = GrowthStage.adjustedDailyTokens(base: config.dailyTokens, stage: stage)
        pet.refreshGrowthStage()
        console.refreshMenu()
    }

    /// 配置应用的唯一权威出口:读盘 → 推给所有依赖者。
    /// 设置窗口保存、提案批准、调度器发现文件变更,统统汇流到这里,
    /// 三处副作用收成一份,任何一处遗漏(如曾经漏掉的 L.current)都消除。
    func reloadConfigFromDisk() {
        config = Config.load()
        L.current = config.language == "zh" ? .zh : .en
        brain.config = config
        brain.reloadPersona()
        screenSensor.updateBlacklist(config.blacklistApps)
        scheduler.updateConfig(config)   // 推新 config + 同步 mtime 基线(不重复触发)
        refreshGrowthState()             // budget + pet + menu
        Log.info("config", L.configReloaded)
    }
}

// MARK: - Entry point

/// Holds the app delegate alive (NSApplication.delegate is a weak reference).
@MainActor
enum AppLifetime {
    static var retainedDelegate: GuguApp?
}

let args = CommandLine.arguments

if args.contains("--selftest-offline"),
   (ProcessInfo.processInfo.environment["GUGU_HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    print("offline selftest requires GUGU_HOME=/private/tmp/gugu-selftest to avoid touching your real Gugu data")
    exit(2)
}

do {
    try Paths.bootstrap()
    try Config.writeDefaultsIfMissing(
        apiURL: "https://taas.hk",
        apiKey: ""
    )
} catch {
    print("bootstrap failed: \(error)")
    exit(1)
}

if args.contains("--selftest") {
    runSelfTest()   // never returns
} else if args.contains("--selftest-offline") {
    runOfflineSelfTest()   // never returns
} else if args.contains("--audit-report") {
    MainActor.assumeIsolated {
        print(Audit.report().path)
        exit(0)
    }
} else if let idx = args.firstIndex(of: "--detect"), idx + 1 < args.count {
    // 离线检测测试:对一张图片跑物品识别,打印标签/置信度/中文映射。
    let path = args[idx + 1]
    MainActor.assumeIsolated {
        let r = VisionSensor.debugDetect(imagePath: path)
        print("模型已加载: \(r.loaded)")
        if r.results.isEmpty {
            print("(没有检测到目标)")
        } else {
            for item in r.results {
                print(String(format: "  %@  %.2f  → %@", item.label, item.conf, item.zh ?? "(未映射)"))
            }
        }
        exit(0)
    }
} else if let idx = args.firstIndex(of: "--restore-latest"), idx + 1 < args.count {
    MainActor.assumeIsolated {
        do {
            let restored = try SnapshotStore.restoreLatest(for: args[idx + 1])
            print("restored \(restored.path)")
            exit(0)
        } catch {
            print("restore failed: \(error)")
            exit(1)
        }
    }
} else if let idx = args.firstIndex(of: "--render"), idx + 2 < args.count {
    // --render <pose> <path>  (offscreen artwork verification)
    let pose = args[idx + 1]
    let path = args[idx + 2]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        DispatchQueue.main.async { runRender(pose: pose, to: path) }
    }
    app.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = GuguApp()
        AppLifetime.retainedDelegate = delegate          // app.delegate is weak; keep it alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, menu-bar only
        app.run()
    }
}
