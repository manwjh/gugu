import Foundation

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

        // 3b. Language → action: "过来" should map to a movement action
        do {
            let r = try await brain.chat("咕咕,过来", rhythmLine: "当前节奏:歇口气;现在 22:42")
            let moved = ["come", "approach", "walk", "fly"].contains(r.action)
            check("chat→action", moved, "「过来」→ action=\(r.action) reply=「\(r.reply.prefix(40))」")
        } catch {
            check("chat→action", false, "\(error)")
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
                && capabilityContext.contains("模型未安装")
                && capabilityContext.contains("语音识别:代码已实现")
                && capabilityContext.contains("当前未开启")
                && capabilityContext.contains("不要假装看到了具体画面"),
              "local senses are described without overstating observations")
        check("paths.models",
              FileManager.default.fileExists(atPath: Paths.modelsDir.path),
              Paths.modelsDir.path)
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
        check("local_command.research",
              LocalCommandParser.parse("咕咕,帮我研究 SwiftData 离线存储")?.kind == .research,
              "research parser")
        check("local_command.deferred",
              LocalCommandParser.parse("咕咕,今晚帮我研究 SwiftData 离线存储")?.deferred == true,
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
        let deferredReply = localBrain.handleLocalCommand("咕咕,今晚帮我研究离线任务队列")
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

        let toolURL = Paths.proposals.appendingPathComponent("tool-web-search.md")
        try? """
        # 请求学会查资料
        kind: tool_permission
        target: config.yaml
        key: tools.web_search
        value: true
        """.write(to: toolURL, atomically: true, encoding: .utf8)
        do {
            _ = try engine.applyApprovedProposal(at: toolURL)
            let cfg = Config.load()
            check("proposal.tool", cfg.toolWebSearch,
                  "web_search=\(cfg.toolWebSearch)")
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
            let task = try queue.enqueue(kind: .research, title: "离线研究任务", body: "确认队列能完成")
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
            check("snapshot.restore", restored.dailyTokens == 12345 && restored.toolWebSearch && !restored.toolNotes && restored.toolLocalNotifications,
                  "daily_tokens=\(restored.dailyTokens) web_search=\(restored.toolWebSearch) notes=\(restored.toolNotes) notifications=\(restored.toolLocalNotifications)")
        } catch {
            check("snapshot.restore", false, "\(error)")
        }

        print(failures == 0 ? "=== 全部通过 ===" : "=== \(failures) 项失败 ===")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
