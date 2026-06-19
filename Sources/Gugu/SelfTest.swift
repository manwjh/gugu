import Foundation
import GuguKernel

/// Headless full-pipeline test: config → real heartbeat → chat → dream → budget.
/// Exits 0 if every stage passes; prints a labeled transcript.
func runSelfTest() {
    Task { @MainActor in
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✅" : "❌") [\(name)] \(detail)")
            if !ok { failures += 1 }
        }

        print("=== 咕咕 selftest ===")

        // 1. Config
        let config = Config.load()
        check("config", !config.apiKey.isEmpty && config.apiURL.contains("http"),
              "url=\(config.apiURL) instinct=\(config.instinct.id) conv=\(config.conversation.id)")

        let budget = Budget(dailyTokens: config.dailyTokens)
        let brain = Brain(config: config, budget: budget)
        let tokensBefore = budget.usage.total

        // seed some plausible events
        EventBus.shared.post(kind: "app_switch", summary: "主人切到了 Xcode", weight: 8)
        EventBus.shared.post(kind: "rhythm", summary: "主人刚停下来歇口气(之前高强度敲了约45分钟)", weight: 35)

        // 2. Heartbeat (real API, structured output)
        do {
            let d = try await brain.heartbeat(
                rhythm: "当前节奏:歇口气;现在 22:40",
                screen: "前台 App:Xcode",
                affect: "你状态平平,普普通通的一天",
                skills: []
            )
            let validMood = ["开心", "平静", "好奇", "心疼", "无聊", "困", "委屈"].contains(d.mood)
            let validAction = ["idle", "walk", "approach", "retreat", "perch", "sleep", "dance", "stare", "peck", "groom"].contains(d.action)
            check("heartbeat", validMood && validAction,
                  "mood=\(d.mood) action=\(d.action) speech=「\(d.speech)」 note=「\(d.memoryNote)」")
        } catch {
            check("heartbeat", false, "\(error)")
        }

        // 3. Chat (real API, conversation tier, structured reply+action)
        do {
            let r = try await brain.chat("咕咕,你今天看到我在干嘛?", rhythmLine: "当前节奏:歇口气;现在 22:41")
            check("chat", !r.reply.isEmpty, "回复:「\(r.reply.prefix(120))」 action=\(r.action)")
        } catch {
            check("chat", false, "\(error)")
        }

        // 3b. "过来" should yield a VALID action from the schema enum. Gugu's
        // persona is deliberately willful ("有脾气, 不一定听话"), so a movement
        // action (come/approach…) and a refusal (idle/retreat) are BOTH correct —
        // asserting it must move makes the test flaky. We verify schema adherence:
        // the model returns a legal action, not that it obeys.
        do {
            let r = try await brain.chat("咕咕,过来", rhythmLine: "当前节奏:歇口气;现在 22:42")
            let validActions = ["idle", "come", "approach", "walk", "fly", "perch",
                                "settle", "dance", "hop", "nod", "stare", "peck",
                                "groom", "retreat", "sleep"]
            check("chat→action", validActions.contains(r.action),
                  "「过来」→ action=\(r.action) reply=「\(r.reply.prefix(40))」")
        } catch {
            check("chat→action", false, "\(error)")
        }

        // 3c. learnMove (real API): 主人口头教动作 → 模型产出可校验的 steps。
        // 这是"动作进化"在真实通道上的端到端验收:不只解析成功,steps 还要能过校验器。
        do {
            let draft = try await brain.learnMove(intent: "招手")
            let validated = (try? MetaActionValidator.validate(steps: draft.move.steps)) ?? []
            check("learn_move", draft.feasible && !draft.move.steps.isEmpty && !validated.isEmpty,
                  "name=\(draft.move.name) feasible=\(draft.feasible) steps=\(draft.move.steps.count) ops=\(draft.move.steps.map { $0.op }.joined(separator: ","))")
        } catch {
            check("learn_move", false, "\(error)")
        }

        // 4. Dream (real API, memory distillation)
        do {
            brain.memory.appendNote("主人今晚在用 Xcode 写 Swift,挺专注的")
            let r = try await brain.dream()
            let ownerMd = (try? String(contentsOf: Paths.memoryDir.appendingPathComponent("owner.md"), encoding: .utf8)) ?? ""
            check("dream", !ownerMd.isEmpty && ownerMd != "(还不认识主人,慢慢来)",
                  "morning=「\(r.morningWords)」 skill=\(r.newSkill ?? "无") owner.md=「\(ownerMd.prefix(80))」")
        } catch {
            check("dream", false, "\(error)")
        }

        // 5. Budget metering (tokens only)
        let tokensAfter = budget.usage.total
        check("budget", tokensAfter > tokensBefore,
              "本次测试约 \(tokensAfter - tokensBefore) tokens(累计 \(tokensAfter) tokens,\(budget.usage.calls) 次调用)")

        // 6. Memory digest sanity
        let digest = brain.memory.digest()
        check("memory", !digest.isEmpty, "digest=「\(digest.prefix(100))」")

        print(failures == 0 ? "=== 全部通过 ===" : "=== \(failures) 项失败 ===")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}

/// Offline regression test for the local pipeline. It does not call any model API;
/// it validates config bootstrap, structured JSON parsing, budget accounting,
/// memory/skill file behavior, and state persistence with deterministic fixtures.
func runOfflineSelfTest() {
    Task { @MainActor in
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✅" : "❌") [\(name)] \(detail)")
            if !ok { failures += 1 }
        }

        print("=== 咕咕 offline selftest ===")

        // This suite asserts Chinese display strings; pin language so localized
        // names (formerly hard-coded) resolve to zh regardless of host defaults.
        L.current = .zh

        do {
            try Paths.bootstrap()
            try Config.writeDefaultsIfMissing(apiURL: "https://example.invalid", apiKey: "")
        } catch {
            check("bootstrap", false, "\(error)")
        }

        let config = Config.load()
        check("config", config.apiURL.contains("http") && config.petName == "咕咕",
              "url=\(config.apiURL) key=\(config.apiKey.isEmpty ? "(未配置)" : "(已配置)")")
        check("config.tools", !config.toolLocalNotifications && !config.dreamUseBatch,
              "notifications=\(config.toolLocalNotifications) dream_batch=\(config.dreamUseBatch)")
        let infoPlist = (try? String(contentsOf: URL(fileURLWithPath: "Info.plist"), encoding: .utf8)) ?? ""
        check("permissions.plist",
              infoPlist.contains("NSCameraUsageDescription")
                && infoPlist.contains("NSMicrophoneUsageDescription")
                && infoPlist.contains("NSSpeechRecognitionUsageDescription"),
              "camera/microphone/speech recognition usage descriptions")
        let appInfoPlist = (try? String(contentsOf: URL(fileURLWithPath: "Gugu.app/Contents/Info.plist"), encoding: .utf8)) ?? ""
        if !appInfoPlist.isEmpty {
            check("permissions.app_plist",
                  appInfoPlist.contains("NSSpeechRecognitionUsageDescription")
                    && appInfoPlist.contains("CFBundleExecutable")
                    && appInfoPlist.contains("CFBundlePackageType"),
                  "app bundle plist is in sync")
        }
        let capabilityContext = Brain.localCapabilitiesContext(cameraEnabled: true,
                                                               localObjectRecognitionAvailable: false,
                                                               listeningEnabled: false,
                                                               voiceEnabled: true)
        check("capabilities.context",
              capabilityContext.contains("摄像头感知:代码已实现")
                && capabilityContext.contains("当前已开启")
                && capabilityContext.contains("手势")
                && capabilityContext.contains("视频事件")
                && capabilityContext.contains("本地物品识别")
                && capabilityContext.contains("内置识别")
                && capabilityContext.contains("语音识别:代码已实现")
                && capabilityContext.contains("当前未开启")
                && capabilityContext.contains("不要假装看到了具体画面"),
              "local senses are described without overstating observations")
        check("paths.models",
              FileManager.default.fileExists(atPath: Paths.modelsDir.path),
              Paths.modelsDir.path)
        do {
            // 物品识别现在用系统内置(无需安装模型),始终可用。
            let vision = VisionSensor()
            check("vision.builtin_recognition", vision.objectRecognitionAvailable,
                  "available=\(vision.objectRecognitionAvailable)")
        }
        let initialStage = GrowthStage(rawStage: PetState.load().stage)
        check("growth.initial",
              initialStage == .hatchling,
              "stage=\(initialStage.displayName)")
        check("growth.context",
              Brain.growthContext().contains("当前形态:幼鸟")
                && Brain.growthContext().contains("幼鸟"),
              "growth context is included for prompts")
        check("growth.budget",
              GrowthStage.adjustedDailyTokens(base: 200_000, stage: .hatchling) < 200_000
                && GrowthStage.adjustedDailyTokens(base: 200_000, stage: .spirit) > 200_000,
              "stage budget multipliers")
        let visualBird = BirdNode()
        visualBird.setViewDirection(.front, animated: false)
        let frontView = visualBird.debugAppearance()
        visualBird.setViewDirection(.side, animated: false)
        let sideView = visualBird.debugAppearance()
        visualBird.setViewDirection(.back, animated: false)
        let backView = visualBird.debugAppearance()
        check("bird.views",
              frontView.direction == .front
                && frontView.visibleEyes == 2
                && frontView.beakVisible
                && frontView.bellyVisible
                && sideView.direction == .side
                && sideView.visibleEyes == 1
                && sideView.beakVisible
                && backView.direction == .back
                && backView.visibleEyes == 0
                && !backView.beakVisible
                && !backView.bellyVisible
                && backView.backDetailsVisible
                && frontView.closedEyeMarksVisible == 0
                && !frontView.sleepZVisible,
              "front=\(frontView.visibleEyes) eyes side=\(sideView.visibleEyes) eye backDetails=\(backView.backDetailsVisible)")
        let sleepBird = BirdNode()
        sleepBird.setViewDirection(.front, animated: false)
        sleepBird.setEyesClosed(true, animated: false)
        sleepBird.startSleepZzz()
        let sleepAppearance = sleepBird.debugAppearance()
        sleepBird.setEyesClosed(false, animated: false)
        sleepBird.stopSleepZzz()
        let awakeAppearance = sleepBird.debugAppearance()
        check("sleep.display_state",
              sleepAppearance.direction == .front
                && sleepAppearance.visibleEyes == 0
                && sleepAppearance.closedEyeMarksVisible == 2
                && sleepAppearance.sleepZVisible
                && awakeAppearance.visibleEyes == 2
                && awakeAppearance.closedEyeMarksVisible == 0
                && !awakeAppearance.sleepZVisible,
              "sleep eyes=\(sleepAppearance.visibleEyes) lids=\(sleepAppearance.closedEyeMarksVisible) z=\(sleepAppearance.sleepZVisible); awake eyes=\(awakeAppearance.visibleEyes)")
        check("vision.events",
              VisionExpression.sleepy.summary.contains("累")
                && VisionGesture.wave.summary.contains("挥手")
                && VideoUnderstandingEvent.handReachedTowardCamera.summary().contains("靠近")
                && VisionObjectObservation(label: "cup", confidence: 0.8).summary.contains("杯子"),
              "local vision event summaries")
        check("vision.video_tracker_reset",
              VisionDebugSelfTest.videoTrackerResetsStaleTracks(),
              "face tracks are not bridged across missing frames")
        check("vision.object_appeared_gate",
              VisionDebugSelfTest.objectAppearedRequiresStableFrames(),
              "object appeared requires consecutive local sightings")
        check("vision.object_reappearance",
              VisionDebugSelfTest.objectReappearanceDoesNotBecomeMovement(),
              "object reappearance starts a new motion track")
        check("vision.frame_gate",
              VisionDebugSelfTest.frameGateRejectsOldGenerations(),
              "camera callbacks from old sessions are ignored")

        let batchState = DreamBatchState(
            batchID: "batch_offline",
            customID: "dream_offline",
            memoryDay: "2026-01-02",
            status: "in_progress",
            createdAt: Date(),
            resultURL: nil
        )
        DreamBatchStore.save(batchState)
        let loadedBatch = DreamBatchStore.load()
        check("dream.batch_store",
              loadedBatch?.batchID == "batch_offline" && loadedBatch?.memoryDay == "2026-01-02",
              loadedBatch?.status ?? "(nil)")
        DreamBatchStore.clear()

        do {
            let text = """
            模型有时候会多说两句。
            {"mood":"好奇","action":"approach","speech":"刚停下来呀?","memory_note":"主人停下来休息时可以轻轻靠近"}
            """
            let d = try Brain.parseHeartbeat(text)
            check("heartbeat.parse", d.mood == "好奇" && d.action == "approach" && !d.speech.isEmpty,
                  "mood=\(d.mood) action=\(d.action) speech=「\(d.speech)」")
        } catch {
            check("heartbeat.parse", false, "\(error)")
        }

        check("local_command.note",
              LocalCommandParser.parse("咕咕,帮我记一下今天把离线测试补齐了")?.kind == .note,
              "note parser")
        let reminder = LocalCommandParser.parse("咕咕,提醒我明天看审计报告")
        check("local_command.reminder",
              reminder?.kind == .reminder && reminder?.dueText == "明天",
              "reminder parser")

        // DueDateParser: fuzzy time words → concrete fire time (deterministic).
        do {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            // Reference: 2026-06-15 (Monday) 10:00
            var refComps = DateComponents()
            refComps.year = 2026; refComps.month = 6; refComps.day = 15
            refComps.hour = 10; refComps.minute = 0
            let now = cal.date(from: refComps)!
            func hm(_ d: Date?) -> (Int, Int, Int)? {
                guard let d else { return nil }
                let c = cal.dateComponents([.day, .hour, .minute], from: d)
                return (c.day!, c.hour!, c.minute!)
            }
            let tomorrow = hm(DueDateParser.parse("明天", now: now, calendar: cal))
            let tonight = hm(DueDateParser.parse("今晚", now: now, calendar: cal))
            let wed = hm(DueDateParser.parse("周三", now: now, calendar: cal))
            let ok = tomorrow! == (16, 9, 0)   // 次日 09:00
                && tonight! == (15, 20, 0)     // 当天 20:00
                && wed! == (17, 9, 0)          // 本周三(6/17) 09:00
            check("due_date.parse", ok, "明天=\(tomorrow!) 今晚=\(tonight!) 周三=\(wed!)")
        }
        check("local_command.deferred",
              LocalCommandParser.parse("咕咕,今晚提醒我看审计报告")?.deferred == true,
              "deferred parser")
        let cleanedSpeech = PetController.desktopSpeech(from: "（低头理羽毛）这根快掉了。就这样。第三句不用显示。")
        check("desktop_speech.clean", !cleanedSpeech.contains("低头") && cleanedSpeech.contains("这根快掉了"),
              cleanedSpeech)
        let ttsText = Voice.stripStageDirections("（歪头）「今天不错！」*拍翅膀*再试一次。")
        let ttsPieces = Voice.splitSentences(ttsText)
        check("voice.tts_text",
              ttsText == "今天不错！再试一次。" && ttsPieces == ["今天不错！", "再试一次。"],
              "\(ttsText) -> \(ttsPieces.joined(separator: "|"))")
        let longTtsPieces = Voice.splitSentences("这是一段比较长的咕咕语音,需要拆成更短的片段来读,这样听起来不会像系统读屏。")
        check("voice.tts_chunk",
              longTtsPieces.count >= 2 && longTtsPieces.allSatisfy { $0.count <= 28 },
              longTtsPieces.joined(separator: "|"))
        let voiceListener = Listener()
        var heardVoiceCommands: [String] = []
        voiceListener.onCommand = { heardVoiceCommands.append($0) }
        voiceListener.debugFeedTranscript("过来看看", isFinal: true)
        voiceListener.debugFeedTranscript("过来看看", isFinal: true)
        voiceListener.debugFeedTranscript("过来看看再跳一下", isFinal: true)
        check("voice.conversation",
              heardVoiceCommands == ["过来看看", "再跳一下"],
              heardVoiceCommands.joined(separator: "|"))
        let wakeListener = Listener()
        var wakeCommand = ""
        wakeListener.onCommand = { wakeCommand = $0 }
        wakeListener.debugFeedTranscript("咕咕 帮我记一下今天把语音会话补齐了", isFinal: true)
        check("voice.wake_optional",
              wakeCommand == "帮我记一下今天把语音会话补齐了",
              wakeCommand)
        let suppressListener = Listener()
        var suppressedCount = 0
        suppressListener.onCommand = { _ in suppressedCount += 1 }
        suppressListener.suppressInput(for: 1)
        suppressListener.debugFeedTranscript("我在听直接跟我说就行", isFinal: true)
        suppressListener.stop()
        check("voice.echo_suppression",
              suppressedCount == 0,
              "suppressed=\(suppressedCount)")
        check("voice.listener_status",
              suppressListener.status == .off,
              "\(suppressListener.status)")

        let lockedExecutor = LocalToolExecutor(config: config)
        let deniedNote = lockedExecutor.execute(.init(name: "notes.add", arguments: ["text": "未授权不应写入"]))
        check("tool.denied", !deniedNote.ok && !deniedNote.allowed,
              deniedNote.message)

        let budget = Budget(dailyTokens: 1000)
        let before = budget.usage.total
        budget.record(inputChars: 320, outputChars: 64, tier: config.instinct)
        check("budget", budget.usage.total > before && budget.usage.calls > 0,
              "delta=\(budget.usage.total - before) total=\(budget.usage.total)")

        let localBrain = Brain(config: config, budget: budget)
        let deferredReply = localBrain.handleLocalCommand("咕咕,今晚提醒我看离线任务队列")
        check("brain.local_deferred", deferredReply?.reply.contains("夜里") == true,
              deferredReply?.reply ?? "(nil)")
        do {
            let batchDream = try localBrain.applyDreamBatchText("""
            {"owner":"主人在补 Batch 骨架","projects":"Gugu 离线梦境测试","self":"我会做梦了","new_skill_name":"","new_skill_body":"","morning_words":"我把梦收好了"}
            """)
            check("dream.batch_apply", batchDream.morningWords == "我把梦收好了",
                  batchDream.evolutionSummary)
        } catch {
            check("dream.batch_apply", false, "\(error)")
        }
        do {
            let batchLine = """
            {"custom_id":"dream_offline","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"{\\"owner\\":\\"主人在审查完成度\\",\\"projects\\":\\"补 Batch 闭环\\",\\"self\\":\\"我会等结果再做梦\\",\\"new_skill_name\\":\\"\\",\\"new_skill_body\\":\\"\\",\\"morning_words\\":\\"梦境结果回来了\\"}"}]}}}
            """
            let dreamText = try Brain.extractDreamTextFromBatchResults(batchLine, customID: "dream_offline")
            check("dream.batch_jsonl", dreamText.contains("梦境结果回来了"),
                  dreamText)
        } catch {
            check("dream.batch_jsonl", false, "\(error)")
        }

        let memory = Memory()
        do {
            try memory.writeRequired(file: "owner.md", content: "主人正在研发 macOS 桌面小鸟。")
            try memory.writeRequired(file: "projects.md", content: "当前重点是把本地回归测试补起来。")
            try memory.writeRequired(file: "self.md", content: "我是咕咕,会先安静观察。")
        } catch {
            check("memory.write", false, "\(error)")
        }
        let digest = memory.digest()
        check("memory.digest", digest.contains("主人") && digest.contains("近况") && digest.contains("我"),
              "digest=「\(digest.prefix(80))」")

        // bond.md milestones (append-only) flow into the heartbeat digest
        do {
            let bondURL = Paths.memoryDir.appendingPathComponent("bond.md")
            try "- 第一次见面,主人歪头看了看我。\n- 主人批准咕咕长成了雏鸟。\n"
                .write(to: bondURL, atomically: true, encoding: .utf8)
            let withBond = memory.digest()
            check("memory.bond_digest",
                  withBond.contains("一起经历") && withBond.contains("长成了雏鸟"),
                  "digest=「\(withBond.suffix(80))」")
        } catch {
            check("memory.bond_digest", false, "\(error)")
        }

        do {
            let capture1 = try memory.applyPinnedFact(.ownerName(name: "王哥", preferred: true),
                                                      source: "offline-test",
                                                      rawText: "我叫王哥")
            let capture2 = memory.capturePinnedFact(from: "我是深圳王哥", source: "offline-test")
            let pinned = PinnedMemory.load()
            check("memory.pinned_owner",
                  capture1.value == "王哥"
                    && capture2?.value == "深圳王哥"
                    && pinned.owner.preferredName == "王哥"
                    && pinned.owner.names.contains("深圳王哥")
                    && memory.digest().contains("固定记忆")
                    && memory.digest().contains("王哥"),
                  "preferred=\(pinned.owner.preferredName ?? "nil") names=\(pinned.owner.names.joined(separator: "|"))")
            check("memory.pinned_guard",
                  PinnedMemoryExtractor.extract(from: "我是开玩笑的") == nil
                    && PinnedMemoryExtractor.extract(from: "我是说这个方案") == nil,
                  "ambiguous 我是* not captured")
        } catch {
            check("memory.pinned_owner", false, "\(error)")
        }

        do {
            try memory.appendNoteRequired("离线自测确认本地记忆能写入")
            check("memory.note", memory.todayNotes().contains("离线自测"),
                  "dated notes 可读")
            try memory.clearNotes(for: Date())
            check("memory.note.clear", memory.todayNotes().isEmpty,
                  "dated notes 已清理")
        } catch {
            check("memory.note", false, "\(error)")
        }

        let fixedDreamDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC in local-safe tests.
        do {
            try memory.appendNoteRequired("昨天的记忆不应被今天清理", date: fixedDreamDate)
            try memory.appendNoteRequired("今天的记忆保留", date: Date())
            let beforeSnapshots = (try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("memory-owner.md.") }.count) ?? 0
            let applied = try localBrain.applyDreamBatchText("""
            {"owner":"主人昨天在检查记忆持久化","projects":"补齐梦境可靠性","self":"我会先备份再改记忆","new_skill_name":"深夜记忆备份","new_skill_body":"做梦前先留快照,失败就不清笔记。","morning_words":"昨晚的梦收好了"}
            """, for: fixedDreamDate)
            let afterSnapshots = (try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("memory-owner.md.") }.count) ?? 0
            check("dream.memory_apply",
                  applied.morningWords == "昨晚的梦收好了"
                    && memory.notes(for: fixedDreamDate, includeLegacy: false).isEmpty
                    && memory.todayNotes().contains("今天的记忆保留")
                    && afterSnapshots > beforeSnapshots,
                  "snapshots \(beforeSnapshots)→\(afterSnapshots)")
            try memory.clearNotes(for: Date())
        } catch {
            check("dream.memory_apply", false, "\(error)")
        }

        memory.addSkill(name: "深夜离线自测", body: "深夜调试时少说话,先确认本地链路稳不稳。")
        let skills = memory.activeSkills(rhythm: .focused)
        check("skills", skills.contains { $0.contains("深夜离线自测") } || memory.skillCount() > 0,
              "skill_count=\(memory.skillCount())")

        // use-it-or-lose-it: a long-unused skill is pruned, a fresh one survives
        do {
            memory.addSkill(name: "陈年旧经验", body: "很久没用到的经验。")
            memory.addSkill(name: "新鲜经验", body: "最近还在用的经验。")
            let staleURL = Paths.skillsDir.appendingPathComponent("陈年旧经验.md")
            let longAgo = Date().addingTimeInterval(-90 * 86400)   // 90 天前
            try? FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: staleURL.path)
            let dropped = memory.pruneStaleSkills(olderThanDays: 60)
            let fm = FileManager.default
            let staleGone = !fm.fileExists(atPath: staleURL.path)
            let freshKept = fm.fileExists(atPath: Paths.skillsDir.appendingPathComponent("新鲜经验.md").path)
            check("skills.prune", dropped.contains("陈年旧经验") && staleGone && freshKept,
                  "dropped=\(dropped)")
        }

        var state = PetState.load()
        let oldInteractions = state.interactions
        state.interactions += 1
        state.save()
        let reloaded = PetState.load()
        check("state", reloaded.interactions == oldInteractions + 1,
              "interactions \(oldInteractions)→\(reloaded.interactions)")

        var growing = reloaded
        growing.stage = "hatchling"
        growing.days_together = 14
        growing.events_seen = 520
        growing.interactions = 55
        growing.bond = 0.45
        growing.trust = 0.35
        growing.pending_stage = nil
        growing.save()
        memory.addSkill(name: "赶工时", body: "主人专注时不要打扰。")
        memory.addSkill(name: "周末", body: "周末可以多发呆陪着。")
        let settlement = Evolution(memory: memory).settleAfterDream(state: growing, eventCount: 5)
        let pending = Evolution(memory: memory).pendingProposals()
        check("evolution.proposal", settlement.stageChanged && settlement.summary == "幼鸟→雏鸟" && !pending.isEmpty,
              "settlement=\(settlement.summary) proposals=\(pending.count)")
        let engine = ProposalEngine()
        do {
            if let stage = pending.first {
                let applied = try engine.applyApprovedProposal(at: stage.path)
                check("evolution.applied_stage", applied.newStage == .fledgling,
                      "new_stage=\(applied.newStage?.displayName ?? "nil")")
            }
            let approvedState = PetState.load()
            check("evolution.approve", approvedState.stage == "fledgling" && approvedState.pending_stage == nil,
                  "stage=\(approvedState.stage)")
        } catch {
            check("evolution.approve", false, "\(error)")
        }

        let personaProposal = engine.writePersonaProposal(
            title: "记住主人喜欢短句",
            body: "- 主人更喜欢咕咕说短而具体的话。"
        )
        do {
            let applied = try engine.applyApprovedProposal(at: personaProposal)
            let persona = (try? String(contentsOf: Paths.persona, encoding: .utf8)) ?? ""
            check("proposal.persona", persona.contains("主人更喜欢咕咕说短而具体的话") && applied.snapshot.pathExtension == "bak",
                  "target=\(applied.target.lastPathComponent)")
        } catch {
            check("proposal.persona", false, "\(error)")
        }

        let badPersona = engine.writePersonaProposal(
            title: "危险 core 修改",
            body: "<!-- core -->\n改掉安全内核\n<!-- /core -->"
        )
        do {
            _ = try engine.applyApprovedProposal(at: badPersona)
            check("proposal.core_guard", false, "core proposal should be rejected")
        } catch {
            check("proposal.core_guard", true, "\(error)")
        }

        let configProposal = engine.writeConfigProposal(
            title: "降低离线测试预算",
            key: "budget.daily_tokens",
            value: "12345"
        )
        do {
            _ = try engine.applyApprovedProposal(at: configProposal)
            let cfg = Config.load()
            check("proposal.config", cfg.dailyTokens == 12345,
                  "daily_tokens=\(cfg.dailyTokens)")
        } catch {
            check("proposal.config", false, "\(error)")
        }

        let badConfig = engine.writeConfigProposal(
            title: "无效心跳配置",
            key: "heartbeat.min_interval",
            value: "1"
        )
        do {
            _ = try engine.applyApprovedProposal(at: badConfig)
            check("proposal.config_guard", false, "invalid config should be rejected")
        } catch {
            check("proposal.config_guard", true, "\(error)")
        }

        let toolURL = Paths.proposals.appendingPathComponent("tool-reminders.md")
        try? """
        # 请求学会记提醒
        kind: tool_permission
        target: config.yaml
        key: tools.reminders
        value: true
        """.write(to: toolURL, atomically: true, encoding: .utf8)
        do {
            _ = try engine.applyApprovedProposal(at: toolURL)
            let cfg = Config.load()
            check("proposal.tool", cfg.toolReminders,
                  "reminders=\(cfg.toolReminders)")
        } catch {
            check("proposal.tool", false, "\(error)")
        }

        let notifyProposal = engine.writeToolPermissionProposal(
            title: "请求学会发系统通知",
            key: "tools.local_notifications"
        )
        do {
            _ = try engine.applyApprovedProposal(at: notifyProposal)
            let cfg = Config.load()
            check("proposal.notification_tool", cfg.toolLocalNotifications,
                  "local_notifications=\(cfg.toolLocalNotifications)")
        } catch {
            check("proposal.notification_tool", false, "\(error)")
        }

        _ = engine.writeToolPermissionProposal(title: "请求学会记笔记", key: "tools.notes")
        if let noteProposal = Evolution(memory: memory).pendingProposals().first(where: { $0.id.hasPrefix("tool-") }) {
            _ = try? engine.applyApprovedProposal(at: noteProposal.path)
        }
        let notesExecutor = LocalToolExecutor(config: Config.load())
        let noteResult = notesExecutor.execute(.init(name: "notes.add", arguments: ["text": "工具执行器离线写入"]))
        check("tool.note", noteResult.ok && noteResult.file?.lastPathComponent == "notes.jsonl",
              noteResult.message)

        do {
            let queue = AutonomyTaskQueue()
            let task = try queue.enqueue(kind: .note, title: "离线队列任务", body: "确认队列能完成")
            let pendingTasks = try queue.listPending()
            let run = try await queue.runDue(limit: 3)
            check("autonomy.queue", pendingTasks.contains { $0.id == task.id } && run.contains { $0.task.id == task.id && $0.succeeded },
                  "task=\(task.id)")
        } catch {
            check("autonomy.queue", false, "\(error)")
        }

        // toolRunner: a deferred note task actually lands in notes.jsonl
        // (tools.notes was approved above), unlike the offline stub.
        do {
            let notesFile = Paths.root.appendingPathComponent("notes.jsonl")
            let before = (try? String(contentsOf: notesFile, encoding: .utf8))?.count ?? 0
            let queue = AutonomyTaskQueue(runner: AutonomyTaskQueue.toolRunner(config: Config.load()))
            let task = try queue.enqueue(kind: .note, title: "夜间任务真落地", body: "")
            let run = try await queue.runDue(limit: 3)
            let after = (try? String(contentsOf: notesFile, encoding: .utf8)) ?? ""
            let landed = run.contains { $0.task.id == task.id && $0.succeeded }
                && after.count > before && after.contains("夜间任务真落地")
            check("autonomy.tool_runner", landed, "note 真写入 notes.jsonl")
        } catch {
            check("autonomy.tool_runner", false, "\(error)")
        }

        let report = Audit.report()
        let reportText = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        check("audit.report", reportText.contains("今日审计") && reportText.contains("待批准提案"),
              report.lastPathComponent)

        do {
            _ = try SnapshotStore.restoreLatest(for: "config.yaml")
            let restored = Config.load()
            check("snapshot.restore", restored.dailyTokens == 12345 && restored.toolReminders && !restored.toolNotes,
                  "daily_tokens=\(restored.dailyTokens) reminders=\(restored.toolReminders) notes=\(restored.toolNotes) notifications=\(restored.toolLocalNotifications)")
        } catch {
            check("snapshot.restore", false, "\(error)")
        }

        // MARK: - 动作进化(meta-action / moves)

        // 元动作校验:合法编排通过并被夹紧;越界数值被 clamp 而非报错
        do {
            let raw = [
                MoveStep(op: "flap", times: 999, fast: true),       // times 越界 → clamp 到 30
                MoveStep(op: "move", dx: 9999, dy: -9999, dur: 99), // 位移/时长越界 → clamp
                MoveStep(op: "rotate", by: 6.283, dur: 0.5),
            ]
            let clamped = try MetaActionValidator.validate(steps: raw)
            let ok = clamped.count == 3
                && clamped[0].times == MoveLimits.maxFlap
                && clamped[1].dx == MoveLimits.maxTranslate
                && clamped[1].dy == -MoveLimits.maxTranslate
                && clamped[1].dur == MoveLimits.maxStepDuration
            check("move.validate_clamp", ok,
                  "times=\(clamped[0].times ?? -1) dx=\(clamped[1].dx ?? -1) dur=\(clamped[1].dur ?? -1)")
        } catch {
            check("move.validate_clamp", false, "\(error)")
        }

        // 结构性错误被挡:未知基元 / 空编排 / 步数超限
        do {
            var threwUnknown = false, threwEmpty = false, threwTooMany = false
            do { _ = try MetaActionValidator.validate(steps: [MoveStep(op: "explode")]) }
            catch { threwUnknown = true }
            do { _ = try MetaActionValidator.validate(steps: []) }
            catch { threwEmpty = true }
            do {
                let many = (0..<20).map { _ in MoveStep(op: "peck") }
                _ = try MetaActionValidator.validate(steps: many)
            } catch { threwTooMany = true }
            check("move.validate_reject", threwUnknown && threwEmpty && threwTooMany,
                  "unknown=\(threwUnknown) empty=\(threwEmpty) tooMany=\(threwTooMany)")
        }

        // 危险台词/朝向被挡;名字消毒
        do {
            var threwSay = false, threwDir = false, threwName = false
            do { _ = try MetaActionValidator.validate(steps: [MoveStep(op: "say", text: String(repeating: "啦", count: 50))]) }
            catch { threwSay = true }
            do { _ = try MetaActionValidator.validate(steps: [MoveStep(op: "view", dir: "sideways")]) }
            catch { threwDir = true }
            do { _ = try MetaActionValidator.sanitizedName("../../etc/passwd") }
            catch { threwName = true }
            let cleanName = (try? MetaActionValidator.sanitizedName("  翻跟头  ")) ?? ""
            check("move.guard", threwSay && threwDir && threwName && cleanName == "翻跟头",
                  "say=\(threwSay) dir=\(threwDir) name=\(threwName) clean=\(cleanName)")
        }

        // manpu 基元:合法情绪符号通过,未知 kind 被挡(进化只能选已有符号,不能造新的)
        do {
            let good = (try? MetaActionValidator.validate(steps: [MoveStep(op: "manpu", kind: "love")])) ?? []
            var threwBadKind = false
            do { _ = try MetaActionValidator.validate(steps: [MoveStep(op: "manpu", kind: "explosion")]) }
            catch { threwBadKind = true }
            check("move.manpu", good.count == 1 && good[0].kind == "love" && threwBadKind,
                  "good=\(good.count) threwBadKind=\(threwBadKind)")
        }

        // MoveLibrary:出厂内置动作被播种,可加载、可按名/触发词查
        do {
            let lib = MoveLibrary.shared
            lib.reload()
            let backflip = lib.move(named: "翻跟头")
            let byTrigger = lib.matchTrigger(in: "咕咕你给我翻跟头看看")
            check("move.library_builtins",
                  backflip != nil && backflip?.origin == "builtin"
                    && lib.moves.count >= 3
                    && byTrigger?.name == "翻跟头",
                  "builtins=\(lib.moves.count) backflip=\(backflip?.steps.count ?? -1)步 trigger=\(byTrigger?.name ?? "nil")")
        }

        // 解释器:能把编排编译成一个非空 SKAction(headless 也能跑)
        do {
            let bird = BirdNode()
            let steps = MoveLibrary.builtins[0].steps   // 翻跟头(含一个 say)
            let action = MoveInterpreter.compile(steps, on: bird) { _ in }
            // SKAction.sequence 的 duration 应为正,说明编排成功翻成了动画
            check("move.interpreter", action.duration > 0,
                  "compiled duration=\(String(format: "%.2f", action.duration))s steps=\(steps.count)")
        }

        // move_add 提案门控:写提案 → 批准 → 真正落盘到 moves/ 且可被库加载
        do {
            let draft = Move(name: "测试鞠躬", trigger: "鞠躬测试", steps: [
                MoveStep(op: "move", dy: -8, dur: 0.2),
                MoveStep(op: "scale", y: 0.85, dur: 0.2),
                MoveStep(op: "scale", y: 1.0, dur: 0.2),
                MoveStep(op: "say", text: "咕。"),
            ], origin: "learned")
            let url = try ProposalEngine().writeMoveProposal(draft)
            let applied = try ProposalEngine().applyApprovedProposal(at: url)
            MoveLibrary.shared.reload()
            let landed = MoveLibrary.shared.move(named: "测试鞠躬")
            check("move.proposal_apply",
                  applied.title.contains("测试鞠躬")
                    && landed != nil
                    && landed?.origin == "learned"
                    && landed?.steps.count == 4
                    && FileManager.default.fileExists(atPath: Paths.movesDir.appendingPathComponent("测试鞠躬.json").path),
                  "applied=\(applied.title) landed=\(landed?.name ?? "nil")")
        } catch {
            check("move.proposal_apply", false, "\(error)")
        }

        // 恶意 move_add 提案被挡:正文里塞越界/未知基元,批准时校验失败
        do {
            let badURL = Paths.proposals.appendingPathComponent("move-bad.md")
            try? """
            # 想学会新动作:坏动作
            kind: move_add
            target: moves/坏动作.json

            ---
            {"name":"坏动作","trigger":"坏","steps":[{"op":"explode"}],"origin":"learned"}
            """.write(to: badURL, atomically: true, encoding: .utf8)
            var rejected = false
            do { _ = try ProposalEngine().applyApprovedProposal(at: badURL) }
            catch { rejected = true }
            let notLanded = MoveLibrary.shared.move(named: "坏动作") == nil
            check("move.proposal_guard", rejected && notLanded,
                  "rejected=\(rejected) notLanded=\(notLanded)")
        }

        // 学习意图解析:口语请求 → 动作意图;非请求不误判
        do {
            let a = LearnMoveParser.parse("咕咕,学个翻跟头")
            let b = LearnMoveParser.parse("教你转个圈好不好")
            let c = LearnMoveParser.parse("你能学会作揖吗")
            let d = LearnMoveParser.parse("今天天气不错")   // 不是学动作请求
            check("learn_move.parse",
                  a == "翻跟头" && b == "转个圈" && c == "作揖" && d == nil,
                  "a=\(a ?? "nil") b=\(b ?? "nil") c=\(c ?? "nil") d=\(d.map { $0 } ?? "nil")")
        }

        // learnMove 草稿解析:模型 JSON → Move(含 feasible 标志与步骤)
        do {
            let json = """
            {"name":"作揖","trigger":"作揖","feasible":true,"steps":[
              {"op":"view","dir":"front"},
              {"op":"move","dy":-6,"dur":0.2},
              {"op":"move","dy":6,"dur":0.2},
              {"op":"say","text":"咕咕"}
            ]}
            """
            let draft = try Brain.parseMoveDraft(json, fallbackName: "作揖")
            let validated = try MetaActionValidator.validate(steps: draft.move.steps)
            check("learn_move.draft_parse",
                  draft.feasible && draft.move.name == "作揖"
                    && draft.move.steps.count == 4 && validated.count == 4,
                  "name=\(draft.move.name) feasible=\(draft.feasible) steps=\(draft.move.steps.count)")
        } catch {
            check("learn_move.draft_parse", false, "\(error)")
        }

        // 容错:模型把 steps 给成纯字符串数组(OpenAI json_object 模式下常见)也能解析
        do {
            let json = """
            {"name":"招手","trigger":"招手","feasible":true,"steps":["flap","wait","flap","say"]}
            """
            let draft = try Brain.parseMoveDraft(json, fallbackName: "招手")
            check("learn_move.tolerant_steps",
                  draft.move.steps.count == 4 && draft.move.steps.first?.op == "flap",
                  "steps=\(draft.move.steps.count) first=\(draft.move.steps.first?.op ?? "nil")")
        } catch {
            check("learn_move.tolerant_steps", false, "\(error)")
        }

        // MARK: - 可发现性 / 成长回路 / 行为多样性 / 触感

        // ProgressState 读写往返
        do {
            var p = ProgressState()
            p.pokeCount = 3
            p.markHintShown("poke")
            p.markMilestoneReached("bond_30")
            p.save()
            let loaded = ProgressState.load()
            check("progress.persist",
                  loaded.pokeCount == 3
                    && loaded.hasShownHint("poke")
                    && loaded.hasReachedMilestone("bond_30")
                    && !loaded.hasShownHint("pet"),
                  "poke=\(loaded.pokeCount) hints=\(loaded.hintsShown) ms=\(loaded.milestonesReached)")
        }

        // Discovery:按优先级择机,且已展示的不再出
        do {
            var fresh = ProgressState()
            let first = Discovery.nextHint(fresh)         // 应先教"戳"
            fresh.markHintShown("poke")
            fresh.pokeCount = 1
            let second = Discovery.nextHint(fresh)        // 戳过了 → 教"摸"
            fresh.markHintShown("pet"); fresh.petCount = 1
            fresh.markHintShown("learn"); fresh.markHintShown("chat")
            let none = Discovery.nextHint(fresh)          // 全展示过 → nil
            check("discovery.next_hint",
                  first?.id == "poke" && second?.id == "pet" && none == nil,
                  "first=\(first?.id ?? "nil") second=\(second?.id ?? "nil") none=\(none?.id ?? "nil")")
        }

        // Discovery:无关时不乱提(还没戳过却已经会动作,也不该先冒 learn)
        do {
            var p = ProgressState()
            p.pokeCount = 0
            let hint = Discovery.nextHint(p)
            check("discovery.relevance", hint?.id == "poke",
                  "hint=\(hint?.id ?? "nil")")
        }

        // Milestones:跨越检测 + 高水位只触发一次
        do {
            var p = ProgressState()
            p.pokeCount = 6; p.petCount = 4   // interactions=10
            var s = PetState.load()
            s.bond = 0.1; s.days_together = 0
            let first = Milestones.newlyReached(progress: p, state: s)
            let hasInteract10 = first.contains { $0.id == "interact_10" }
            // 标记已达成后,再算应为空
            var p2 = p
            for m in first { p2.markMilestoneReached(m.id) }
            let again = Milestones.newlyReached(progress: p2, state: s)
            check("milestones.cross_once",
                  hasInteract10 && again.allSatisfy { $0.id != "interact_10" },
                  "first=\(first.map { $0.id }) again=\(again.map { $0.id })")
        }

        // Milestones:羁绊与天数阈值
        do {
            let p = ProgressState()
            var s = PetState.load()
            s.bond = 0.55; s.days_together = 7
            let reached = Milestones.newlyReached(progress: p, state: s)
            let ids = Set(reached.map { $0.id })
            check("milestones.bond_days",
                  ids.contains("bond_30") && ids.contains("bond_50") && ids.contains("days_3") && ids.contains("days_7"),
                  "ids=\(ids.sorted())")
        }

        // IdleSelector:精力低偏静、精力高心情好可能玩动作、纯函数确定性
        do {
            let lowEnergy = IdleSelector.choose(roll: 0.05, energy: 0.2, valence: 0.0, availableMove: "翻跟头")
            let lowIsCalm: Bool = {
                switch lowEnergy { case .standStill, .groom, .tiltHead, .peck, .stretch: return true; default: return false }
            }()
            let play = IdleSelector.choose(roll: 0.05, energy: 0.8, valence: 0.5, availableMove: "翻跟头")
            let isPlay = play == .playMove("翻跟头")
            let noMove = IdleSelector.choose(roll: 0.05, energy: 0.8, valence: 0.5, availableMove: nil)
            let notPlayWhenNone = noMove != .playMove("翻跟头")
            check("idle.selector",
                  lowIsCalm && isPlay && notPlayWhenNone,
                  "low=\(lowEnergy) play=\(play) noMove=\(noMove)")
        }

        // PokeCombo:时间窗内累计、超窗清零、反应分级
        do {
            var combo = PokeCombo(window: 1.6)
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let c1 = combo.registerPoke(now: base)
            let c2 = combo.registerPoke(now: base.addingTimeInterval(0.5))
            let c3 = combo.registerPoke(now: base.addingTimeInterval(1.0))
            // 隔很久再戳 → 连击清零
            let cReset = combo.registerPoke(now: base.addingTimeInterval(10))
            let tiers = (
                PokeCombo.reaction(for: 1),
                PokeCombo.reaction(for: 3),
                PokeCombo.reaction(for: 6),
                PokeCombo.reaction(for: 9)
            )
            check("poke.combo",
                  c1 == 1 && c2 == 2 && c3 == 3 && cReset == 1
                    && tiers.0 == .mild && tiers.1 == .annoyed
                    && tiers.2 == .dizzy && tiers.3 == .flee,
                  "counts=\(c1),\(c2),\(c3),reset=\(cReset)")
        }

        // MARK: - 语言魅力(择机灵光模型)/ 共同能动性(联网框架)

        // SparkPolicy:高好奇心 + 有额度 + 过冷却才点亮;未配置则永不点亮
        do {
            let base = SparkPolicy.Inputs(enabled: true, curiosity: 60, heartbeatThreshold: 30,
                                          usedToday: 0, dailyLimit: 6,
                                          secondsSinceLastSpark: 9999, cooldown: 5400)
            let spark = SparkPolicy.shouldSpark(base)                          // 60 ≥ 30*2 → 点亮
            var lowCuriosity = base; lowCuriosity.curiosity = 40
            let noSparkLow = SparkPolicy.shouldSpark(lowCuriosity)             // 40 < 60 → 不点
            var cappedToday = base; cappedToday.usedToday = 6
            let noSparkCap = SparkPolicy.shouldSpark(cappedToday)              // 额度用尽 → 不点
            var cooling = base; cooling.secondsSinceLastSpark = 60
            let noSparkCool = SparkPolicy.shouldSpark(cooling)                 // 冷却未过 → 不点
            var disabled = base; disabled.enabled = false
            let noSparkOff = SparkPolicy.shouldSpark(disabled)                 // 未配置 → 永不点
            check("spark.policy",
                  spark && !noSparkLow && !noSparkCap && !noSparkCool && !noSparkOff,
                  "spark=\(spark) low=\(noSparkLow) cap=\(noSparkCap) cool=\(noSparkCool) off=\(noSparkOff)")
        }

        // 默认配置下灵光未启用(spark_id 为空)= 零行为变化、完全向后兼容
        do {
            let cfg = Config.load()
            check("spark.disabled_by_default",
                  !cfg.sparkEnabled && cfg.spark.id.isEmpty,
                  "sparkEnabled=\(cfg.sparkEnabled) id=「\(cfg.spark.id)」")
        }

        // web_search 工具:未授权时被拒、不落盘;授权后记录到 research_requests.jsonl
        do {
            var noWeb = Config.load()   // 默认 tools.web_search = false
            let denied = try LocalToolExecutor(config: noWeb).webSearchRequest(query: "桌宠留存怎么做")
            // 打开权限再试
            noWeb.toolWebSearch = true
            let researchFile = Paths.root.appendingPathComponent("research_requests.jsonl")
            let before = (try? String(contentsOf: researchFile, encoding: .utf8))?.count ?? 0
            let allowed = try LocalToolExecutor(config: noWeb).webSearchRequest(query: "桌宠留存怎么做", reason: "测试")
            let after = (try? String(contentsOf: researchFile, encoding: .utf8)) ?? ""
            check("web_search.gated_record",
                  !denied.allowed && !denied.ok
                    && allowed.allowed && allowed.ok
                    && after.count > before && after.contains("桌宠留存怎么做") && after.contains("pending"),
                  "denied(allowed=\(denied.allowed)) allowed(ok=\(allowed.ok)) landed=\(after.count > before)")
        } catch {
            check("web_search.gated_record", false, "\(error)")
        }

        // research 命令解析 + 经队列 toolRunner 真正记录(权限已开)
        do {
            let parsed = LocalCommandParser.parse("咕咕,帮我研究一下桌宠为什么会被卸载")
            var cfg = Config.load(); cfg.toolWebSearch = true
            let queue = AutonomyTaskQueue(runner: AutonomyTaskQueue.toolRunner(config: cfg))
            let task = try queue.enqueue(kind: .research, title: "桌宠卸载原因", body: "")
            let run = try await queue.runDue(limit: 3)
            let landed = run.contains { $0.task.id == task.id && $0.succeeded }
            check("web_search.command_and_queue",
                  parsed?.kind == .research && landed,
                  "parsed=\(parsed?.kind.rawValue ?? "nil") landed=\(landed)")
        } catch {
            check("web_search.command_and_queue", false, "\(error)")
        }

        // OpenAI provider: protocol-specific transforms (no network).
        do {
            // message flattening: string passthrough + block-array join
            let flatString = OpenAIClient.flatten("你好")
            let flatBlocks = OpenAIClient.flatten([["type": "text", "text": "甲"],
                                                   ["type": "text", "text": "乙"]])
            check("openai.flatten", flatString == "你好" && flatBlocks == "甲乙",
                  "string=\(flatString) blocks=\(flatBlocks)")

            // schema → prompt hint: lists keys, enums, required markers
            let hint = SchemaHint.describe(Brain.heartbeatSchema)
            check("openai.schema_hint",
                  hint.contains("mood") && hint.contains("action")
                    && hint.contains("开心") && hint.contains("(必填)"),
                  "hint=\(hint.prefix(60))…")

            // provider selection is config-driven; default is now openai
            // (taas.hk honors structured output on the chat-completions line).
            check("openai.provider_default", Config.load().apiProvider == "openai",
                  "provider=\(Config.load().apiProvider)")
        }

        // LLM wire: typed request/response contract — pure parsing, no network.
        // Locks the trickiest paths (reasoning fallback / truncation / empty /
        // multi-block join / json_object guard) so they can't silently regress.
        do {
            func parse(_ json: String, _ f: (Data) throws -> LLMReply) -> Result<String, LLMError> {
                do { return .success(try f(Data(json.utf8)).text) }
                catch let e as LLMError { return .failure(e) }
                catch { return .failure(.malformed("\(error)")) }
            }
            func isEmpty(_ r: Result<String, LLMError>) -> Bool {
                if case .failure(let e) = r, case .empty = e { return true }; return false
            }
            func isMalformed(_ r: Result<String, LLMError>) -> Bool {
                if case .failure(let e) = r, case .malformed = e { return true }; return false
            }

            let oNormal = parse(#"{"choices":[{"message":{"content":"嗨"},"finish_reason":"stop"}]}"#, OpenAIResponse.reply)
            check("wire.openai_normal", (try? oNormal.get()) == "嗨", "\(oNormal)")

            let oReason = parse(#"{"choices":[{"message":{"content":"","reasoning_content":"想了想"},"finish_reason":"stop"}]}"#, OpenAIResponse.reply)
            check("wire.openai_reasoning_fallback", (try? oReason.get()) == "想了想", "\(oReason)")

            let oTrunc = parse(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#, OpenAIResponse.reply)
            check("wire.openai_truncated", isMalformed(oTrunc), "\(oTrunc)")

            let oEmpty = parse(#"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#, OpenAIResponse.reply)
            check("wire.openai_empty", isEmpty(oEmpty), "\(oEmpty)")

            let aMulti = parse(#"{"content":[{"type":"text","text":"甲"},{"type":"text","text":"乙"}],"stop_reason":"end_turn"}"#, AnthropicResponse.reply)
            check("wire.anthropic_multiblock", (try? aMulti.get()) == "甲乙", "\(aMulti)")

            let aEmpty = parse(#"{"content":[],"stop_reason":"end_turn"}"#, AnthropicResponse.reply)
            check("wire.anthropic_empty", isEmpty(aEmpty), "\(aEmpty)")

            let guarded = OpenAIJSONGuard.ensureJSONMentioned("请只回复一个对象")
            let preserved = OpenAIJSONGuard.ensureJSONMentioned("output JSON now")
            check("wire.json_guard",
                  guarded.range(of: "json", options: .caseInsensitive) != nil && preserved == "output JSON now",
                  "guarded_has_json + preserved=\(preserved == "output JSON now")")

            let encoded = (try? JSONEncoder().encode(JSONValue(Brain.heartbeatSchema)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check("wire.schema_jsonvalue", encoded.contains("mood") && encoded.contains("properties"),
                  "encoded_len=\(encoded.count)")
        }

        print(failures == 0 ? "=== 全部通过 ===" : "=== \(failures) 项失败 ===")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
