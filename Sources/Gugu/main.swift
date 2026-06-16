import AppKit
import Foundation

/// App composition root: wires senses → affect → scheduler → brain → body.
@MainActor
final class GuguApp: NSObject, NSApplicationDelegate {
    var config: Config!
    var pet: PetController!
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
    private var minuteTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        let state = PetState.load()
        budget = Budget(dailyTokens: GrowthStage.adjustedDailyTokens(base: config.dailyTokens,
                                                                     stage: GrowthStage(rawStage: state.stage)))
        affect = Affect()
        affect.bond = state.bond

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
        console = Console(app: self)
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
        Paths.pruneOldEvents()

        Log.info("app", "咕咕醒了。\(budget.statusLine)")
        EventBus.shared.post(kind: "wake", summary: "咕咕来到了主人的桌面", weight: 10)

        // immediate local greeting (zero-cost): warmer if we already know the owner
        let state0 = PetState.load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let greeting: String
            if state0.days_together <= 0 {
                greeting = "咕?(歪头看了看你)"
            } else if state0.bond > 0.5 {
                greeting = "你来啦!"
            } else {
                greeting = "咕咕。"
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
            self.pet.say("(今天想了好多事,有点困了…)")
            self.pet.sleep()
        }

        // direct interactions → affect + events (+ maybe a quick heartbeat)
        pet.onPoke = { [weak self] in
            guard let self else { return }
            self.affect.poked()
            EventBus.shared.post(kind: "poke", summary: "主人戳了你一下", weight: 20)
            var state = PetState.load(); state.interactions += 1; state.save()
        }
        pet.onPet = { [weak self] in
            guard let self else { return }
            self.affect.petted()
            EventBus.shared.post(kind: "petted", summary: "主人摸了摸你", weight: 22)
            var state = PetState.load(); state.interactions += 1; state.bond = self.affect.bond; state.save()
        }
        pet.onThrown = { [weak self] in
            guard let self else { return }
            self.affect.thrown()
            EventBus.shared.post(kind: "thrown", summary: "主人把你扔了出去,摔了个跟头", weight: 25)
        }
        pet.menuProvider = { [weak self] in
            self?.console.buildMenu() ?? NSMenu()
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

        // vision (opt-in): presence + smile → events the bird can react to
        visionSensor.onPresence = { [weak self] present in
            guard let self else { return }
            if present {
                self.affect.ownerReturned()
                if self.pet.isSleeping && !self.affect.isSleepyTime { self.pet.wake() }
                EventBus.shared.post(kind: "see_return", summary: "你看见主人回到座位上了", weight: 28)
            } else {
                EventBus.shared.post(kind: "see_leave", summary: "你看见主人离开了座位", weight: 5)
            }
        }
        visionSensor.onSmile = { [weak self] in
            guard let self else { return }
            self.affect.petted()  // a smile warms the bird like a pat
            self.pet.bird.showBlush(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pet.bird.showBlush(false) }
            EventBus.shared.post(kind: "see_smile", summary: "你看见主人在笑", weight: 18)
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
            }
            EventBus.shared.post(kind: gesture.eventKind, summary: gesture.summary, weight: 16)
        }
        visionSensor.onObject = { object in
            EventBus.shared.post(kind: "object_seen", summary: object.summary, weight: 6)
        }
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
            case .objectAppeared, .objectDisappeared, .objectMoved:
                break
            }
            let weight: Int
            switch event {
            case .handReachedTowardCamera: weight = 18
            case .personApproached, .personMovedAway: weight = 12
            case .personMovedLeft, .personMovedRight: weight = 6
            case .objectAppeared, .objectDisappeared, .objectMoved: weight = 8
            }
            EventBus.shared.post(kind: event.eventKind, summary: event.summary(label: label), weight: weight)
        }
    }

    /// 语音指令(听到"咕咕"后那一句)→ 和打字聊天同一条对话链路。
    private func handleVoiceCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        EventBus.shared.post(kind: "voice", summary: "主人对你说:\(String(trimmed.prefix(40)))", weight: 0)
        affect.chatted()
        if pet.isSleeping { pet.wake() }
        pet.bird.tiltHead(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pet.bird.tiltHead(false) }
        if let local = brain.handleLocalCommand(trimmed) {
            if local.action != "idle" { pet.perform(action: local.action) }
            if !local.reply.isEmpty { pet.say(local.reply) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.brain.chat(trimmed,
                                                       rhythmLine: self.rhythmSensor.promptLine(),
                                                       mood: self.affect.promptLine(),
                                                       localCapabilities: self.localCapabilitiesContext())
                if result.action != "idle" { self.pet.perform(action: result.action) }
                if !result.reply.isEmpty { self.pet.say(result.reply) }  // say→气泡+朗读
            } catch {
                Log.info("voice", "对话失败: \(error)")
                self.pet.say("我刚才没听明白,你再说一遍。")
            }
        }
    }

    func setVoiceConversationEnabled(_ enabled: Bool) {
        if enabled {
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
            pet.say("好,我先不听了。")
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
            pet.say("麦克风现在用不了。\(reason)")
        default:
            break
        }
    }

    private func startMinuteLoop() {
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.affect.tickMinute()
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

    func localCapabilitiesContext() -> String {
        Brain.localCapabilitiesContext(
            cameraEnabled: visionSensor.enabled,
            localObjectRecognitionAvailable: visionSensor.objectRecognitionAvailable,
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
