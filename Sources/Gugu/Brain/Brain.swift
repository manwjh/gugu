import Foundation

/// The heartbeat decision returned by L2.
struct HeartbeatDecision {
    let mood: String
    let action: String
    let speech: String
    let memoryNote: String
}

/// Brain: builds prompts, calls the model tiers, parses structured output.
@MainActor
final class Brain {
    var config: Config
    let memory = Memory()
    let budget: Budget
    private var chatHistory: [(role: String, text: String)] = []

    /// Stable persona text. Loaded once per process; byte-stable across calls
    /// within a session so the relay can prefix-cache it.
    private var personaText: String

    init(config: Config, budget: Budget) {
        self.config = config
        self.budget = budget
        self.personaText = (try? String(contentsOf: Paths.persona, encoding: .utf8))
            ?? DefaultFiles.persona
    }

    func reloadPersona() {
        personaText = (try? String(contentsOf: Paths.persona, encoding: .utf8)) ?? personaText
    }

    private var client: AnthropicClient {
        AnthropicClient(baseURL: config.apiURL, apiKey: config.apiKey)
    }

    // MARK: - L2 Heartbeat

    static let heartbeatSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mood": ["type": "string", "enum": ["开心", "平静", "好奇", "心疼", "无聊", "困", "委屈"]],
            "action": ["type": "string", "enum": ["idle", "walk", "approach", "retreat", "perch", "sleep", "dance", "stare", "peck", "groom"]],
            "speech": ["type": "string", "description": "想说的一两句短话,多数时候应该留空"],
            "memory_note": ["type": "string", "description": "值得记一笔的事,通常留空"],
        ],
        "required": ["mood", "action", "speech", "memory_note"],
        "additionalProperties": false,
    ]

    /// Build the dynamic user message for a heartbeat (persona stays in system).
    func heartbeatUserMessage(rhythm: String, screen: String, affect: String, skills: [String]) -> String {
        var lines: [String] = []
        lines.append(Brain.growthContext())
        let mem = memory.digest()
        if !mem.isEmpty { lines.append("记忆摘要:\n\(mem)") }
        if !skills.isEmpty { lines.append("你给自己总结过的经验:\n" + skills.joined(separator: "\n")) }
        let events = EventBus.shared.promptSummary()
        if !events.isEmpty { lines.append("最近发生的事:\n\(events)") }
        lines.append("\(rhythm);\(screen)")
        lines.append("你的状态:\(affect)")
        lines.append("现在你想干嘛?(多数时候不需要说话;说话必须基于上面真实观察到的东西)")
        return lines.joined(separator: "\n\n")
    }

    static func localCapabilitiesContext(cameraEnabled: Bool,
                                         localObjectRecognitionAvailable: Bool = false,
                                         listeningEnabled: Bool,
                                         voiceEnabled: Bool) -> String {
        """
        本机能力状态:
        - 摄像头感知:代码已实现,但必须由主人在菜单栏开启并通过系统授权才会工作。当前\(cameraEnabled ? "已开启" : "未开启")。开启时你可以通过本机算法知道主人是否在座位、是否在笑、是否显得惊讶或困倦,以及挥手、手掌、点赞、OK、指向等少量手势;还会用最近几秒的本机结构化轨迹理解主人靠近/离远/左右移动、手靠近镜头等视频事件;不会保存或上传图像。
        - 本地物品识别:预留 Core ML 模型插槽,仅在主人把编译好的本地模型放到 models/gugu-objects.mlmodelc 后工作。当前\(localObjectRecognitionAvailable ? "模型已安装" : "模型未安装")。未安装时不要声称看见了具体物品;安装后也只能基于本机模型事件低置信度地说“好像看见…”,并可通过短窗口轨迹判断物体出现/消失/移动。
        - 语音识别:代码已实现,但必须由主人开启麦克风监听并通过系统授权才会工作。当前\(listeningEnabled ? "已开启" : "未开启")。它只处理唤醒词后的简短指令。
        - 本地朗读:代码已实现,但必须由主人开启朗读才会出声。当前\(voiceEnabled ? "已开启" : "未开启")。
        回答能力问题时要诚实区分“项目支持/当前开启/系统授权/模型是否安装/你此刻实际观察到什么”,不要说自己没有这些本机能力,也不要假装看到了具体画面、具体物品或听到了未提供的内容。
        """
    }

    static func growthContext(state: PetState = PetState.load()) -> String {
        let stage = GrowthStage(rawStage: state.stage)
        let pending = state.pending_stage.flatMap(GrowthStage.init(rawValue:))
        let pendingLine = pending.map { "待主人批准的下一阶段:\($0.displayName)。" } ?? "当前没有待批准进化。"
        return """
        成长状态:
        - 当前形态:\(stage.displayName)(\(stage.rawValue))
        - 相处天数:\(state.days_together),见过事件:\(state.events_seen),互动:\(state.interactions),羁绊:\(String(format: "%.2f", state.bond)),信任:\(String(format: "%.2f", state.trust))
        - \(pendingLine)
        - \(stage.speechGuidance)
        """
    }

    func heartbeat(rhythm: String, screen: String, affect: String, skills: [String]) async throws -> HeartbeatDecision {
        let userMsg = heartbeatUserMessage(rhythm: rhythm, screen: screen, affect: affect, skills: skills)
        let reply = try await client.create(
            model: config.instinct.id,
            maxTokens: config.instinct.maxTokens,
            system: personaText,
            messages: [["role": "user", "content": userMsg]],
            schema: Brain.heartbeatSchema
        )
        budget.record(inputChars: personaText.count + userMsg.count,
                      outputChars: reply.text.count, tier: config.instinct)
        return try Brain.parseHeartbeat(reply.text)
    }

    static func parseHeartbeat(_ text: String) throws -> HeartbeatDecision {
        guard let data = extractJSON(text)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClient.APIError.malformed("heartbeat json: \(text)")
        }
        return HeartbeatDecision(
            mood: obj["mood"] as? String ?? "平静",
            action: obj["action"] as? String ?? "idle",
            speech: obj["speech"] as? String ?? "",
            memoryNote: obj["memory_note"] as? String ?? ""
        )
    }

    /// Tolerate models that wrap JSON in prose/code fences.
    static func extractJSON(_ text: String) -> String? {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return nil
    }

    // MARK: - L3 Chat

    /// Chat result: a short spoken reply plus an optional body action the owner
    /// may have asked for ("过来" → come, "飞起来" → fly, "坐下" → sit …).
    struct ChatResult {
        let reply: String   // compatibility alias for speech
        let action: String   // "idle" when no movement is called for
        let aside: String

        init(reply: String, action: String, aside: String = "") {
            self.reply = reply
            self.action = action
            self.aside = aside
        }
    }

    func handleLocalCommand(_ userText: String) -> ChatResult? {
        _ = memory.capturePinnedFact(from: userText, source: "local_command")
        guard let command = LocalCommandParser.parse(userText) else { return nil }
        if command.deferred, let queued = enqueueAutonomyTask(command) {
            appendChatLog(user: userText, pet: queued)
            return ChatResult(reply: queued, action: "nod")
        }

        let executor = LocalToolExecutor(config: config)
        let result: LocalToolExecutor.Result

        switch command.kind {
        case .note:
            result = executor.execute(.init(name: "notes.add", arguments: ["text": command.content]))
            if !result.allowed {
                _ = ProposalEngine().writeToolPermissionProposal(title: "请求学会记笔记", key: "tools.notes")
            }
        case .reminder:
            var args = ["text": command.content]
            if let due = command.dueText { args["due"] = due }
            result = executor.execute(.init(name: "reminders.add", arguments: args))
            if !result.allowed {
                _ = ProposalEngine().writeToolPermissionProposal(title: "请求学会记提醒", key: "tools.reminders")
            }
        case .research:
            result = executor.execute(.init(name: "web_search.request", arguments: [
                "query": command.content,
                "reason": "主人主动让咕咕研究",
            ]))
            if !result.allowed {
                _ = ProposalEngine().writeToolPermissionProposal(title: "请求学会查资料", key: "tools.web_search")
            }
        }

        let reply: String
        if result.ok {
            reply = result.message
        } else if result.allowed {
            reply = result.message
        } else {
            reply = "这个我还不能做。我把申请放到提案里了。"
        }
        appendChatLog(user: userText, pet: reply)
        return ChatResult(reply: reply, action: "nod")
    }

    private func enqueueAutonomyTask(_ command: LocalCommand) -> String? {
        do {
            let kind: AutonomyTaskQueue.TaskKind
            switch command.kind {
            case .note: kind = .note
            case .reminder: kind = .reminder
            case .research: kind = .research
            }
            let task = try AutonomyTaskQueue().enqueue(kind: kind, title: command.content, body: command.dueText ?? "")
            return "放到夜里做了。\(task.title)"
        } catch {
            Log.info("autonomy", "入队失败: \(error)")
            return "这个夜里任务没放进去。"
        }
    }

    static let chatSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "speech": ["type": "string", "description": "真正说出口的话,必须短。不要写动作描写或括号旁白;也可以为空只用动作回应"],
            "aside": ["type": "string", "description": "聊天窗口可显示的轻量动作旁白,例如'咕咕歪了歪头';可为空。不要把 aside 放进 speech"],
            "action": ["type": "string",
                       "enum": ["idle", "come", "walk", "fly", "perch", "settle", "dance",
                                "hop", "nod", "stare", "peck", "groom", "retreat", "sleep"],
                       "description": "你此刻身体想做的事。你是一只有脾气的小鸟,不是听口令的宠物狗——只有当你自己愿意时才照主人说的做。心情好/信任时会过去(come)、蹲下歇着(settle)、扑腾(fly);心情差或刚被欺负时,可以选 idle 或 retreat 表示不理他。没特别想做就 idle"],
        ],
        "required": ["speech", "aside", "action"],
        "additionalProperties": false,
    ]

    func chat(_ userText: String, rhythmLine: String, mood: String = "", localCapabilities: String = "") async throws -> ChatResult {
        _ = memory.capturePinnedFact(from: userText, source: "chat")
        chatHistory.append((role: "user", text: userText))
        if chatHistory.count > 20 { chatHistory.removeFirst(chatHistory.count - 20) }

        var messages: [[String: Any]] = []
        // context preamble folded into first user turn for cache friendliness
        let mem = memory.digest()
        var first = true
        for turn in chatHistory {
            var content = turn.text
            if first && turn.role == "user" {
                let moodLine = mood.isEmpty ? "" : "你现在的状态:\(mood)。"
                let capabilityLine = localCapabilities.isEmpty ? "" : "\(localCapabilities)\n"
                content = "（背景,主人看不到这段:\(Brain.growthContext())\n你的记忆——\(mem)。\(rhythmLine)。\(moodLine)"
                    + "\(capabilityLine)"
                    + "你是只有情绪的小鸟:愿意就用 action 回应主人;不愿意就 idle 或 retreat,也可以用一两个字表示不想理）\n\n主人说:\(content)"
                first = false
            }
            messages.append(["role": turn.role == "user" ? "user" : "assistant", "content": content])
        }

        // budget degrade: drop from conversation tier to the cheaper instinct tier when running hot
        let tier = budget.degradeLevel >= 1 ? config.instinct : config.conversation
        let reply = try await client.create(
            model: tier.id,
            maxTokens: max(tier.maxTokens, 300),
            system: personaText,
            messages: messages,
            schema: Brain.chatSchema
        )
        budget.record(inputChars: personaText.count + messages.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) },
                      outputChars: reply.text.count, tier: tier)

        var replyText = reply.text
        var aside = ""
        var action = "idle"
        if let data = Brain.extractJSON(reply.text)?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            replyText = (obj["speech"] as? String) ?? (obj["reply"] as? String) ?? ""
            aside = (obj["aside"] as? String) ?? ""
            action = (obj["action"] as? String) ?? "idle"
        }
        let logText = [aside.isEmpty ? nil : "(\(aside))", replyText.isEmpty ? nil : replyText]
            .compactMap { $0 }
            .joined(separator: " ")
        chatHistory.append((role: "assistant", text: logText.isEmpty ? "(\(action))" : logText))
        appendChatLog(user: userText, pet: logText.isEmpty ? "(\(action))" : logText)
        return ChatResult(reply: replyText, action: action, aside: aside)
    }

    private func appendChatLog(user: String, pet: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        let obj: [String: Any] = ["t": iso, "user": user, "pet": pet]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: Paths.chatLog) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.write(to: Paths.chatLog, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - L4 Dream (nightly distillation)

    static let dreamSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "owner": ["type": "string", "description": "对主人的认识,150字以内"],
            "projects": ["type": "string", "description": "主人最近在忙什么,100字以内"],
            "self": ["type": "string", "description": "你对自己的认识与心情,80字以内"],
            "new_skill_name": ["type": "string", "description": "新经验的名字(含情境关键词如:深夜/周五/赶工/烦躁),没有就留空"],
            "new_skill_body": ["type": "string", "description": "这条经验的内容,50字以内"],
            "morning_words": ["type": "string", "description": "醒来想对主人说的第一句话,一句即可"],
        ],
        "required": ["owner", "projects", "self", "new_skill_name", "new_skill_body", "morning_words"],
        "additionalProperties": false,
    ]

    struct DreamResult {
        let morningWords: String
        let newSkill: String?
        let evolutionSummary: String
        let proposalTitle: String?
    }

    private func dreamPrompt(for date: Date = Date()) -> String {
        let events = EventBus.lines(for: date).suffix(120).joined(separator: "\n")
        let notes = memory.notes(for: date)
        let current = memory.digest(maxChars: 800)

        return """
        现在是深夜,你在睡觉,梦里整理今天的记忆。

        你现有的记忆:
        \(current)

        今天的事件流水(系统记录):
        \(events.isEmpty ? "(今天很安静)" : events)

        你白天随手记的小本本:
        \(notes.isEmpty ? "(没记什么)" : notes)

        请把今天的见闻蒸馏进记忆(合并旧记忆,删掉过时的,保持简短模糊——你是小鸟,记不住细节,但记得重要的事)。如果今天发现了某个值得以后注意的规律,总结成一条经验。
        """
    }

    func dream(for date: Date = Date()) async throws -> DreamResult {
        let user = dreamPrompt(for: date)
        let reply = try await client.create(
            model: config.dream.id,
            maxTokens: config.dream.maxTokens,
            system: personaText,
            messages: [["role": "user", "content": user]],
            schema: Brain.dreamSchema
        )
        budget.record(inputChars: personaText.count + user.count,
                      outputChars: reply.text.count, tier: config.dream)

        guard let data = Brain.extractJSON(reply.text)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClient.APIError.malformed("dream json: \(reply.text)")
        }

        return try applyDreamObject(obj, for: date)
    }

    func submitDreamBatch(for date: Date = Date()) async throws -> DreamBatchState {
        let customID = "dream-\(Memory.dayString(for: date))-\(ISO8601DateFormatter().string(from: Date()))"
        let user = dreamPrompt(for: date)
        let batch = try await client.createMessageBatch(
            customID: customID,
            model: config.dream.id,
            maxTokens: config.dream.maxTokens,
            system: personaText,
            messages: [["role": "user", "content": user]],
            schema: Brain.dreamSchema
        )
        budget.record(inputChars: personaText.count + user.count, outputChars: 1, tier: config.dream)
        let state = DreamBatchState(
            batchID: batch.id,
            customID: customID,
            memoryDay: Memory.dayString(for: date),
            status: batch.processingStatus,
            createdAt: Date(),
            resultURL: batch.resultURL
        )
        DreamBatchStore.save(state)
        Audit.record(kind: "dream.batch", summary: "已提交梦境 Batch",
                     detail: ["batch_id": batch.id, "status": batch.processingStatus])
        return state
    }

    func refreshDreamBatchStatus() async throws -> DreamBatchState? {
        guard var state = DreamBatchStore.load() else { return nil }
        let batch = try await client.retrieveMessageBatch(id: state.batchID)
        state.status = batch.processingStatus
        state.resultURL = batch.resultURL
        DreamBatchStore.save(state)
        Audit.record(kind: "dream.batch", summary: "梦境 Batch 状态:\(state.status)",
                     detail: ["batch_id": state.batchID])
        return state
    }

    func applyReadyDreamBatch(_ state: DreamBatchState) async throws -> DreamResult? {
        guard Brain.isBatchCompleted(state.status), let resultURL = state.resultURL else {
            return nil
        }
        let resultsText = try await client.downloadBatchResults(from: resultURL)
        let dreamText = try Brain.extractDreamTextFromBatchResults(resultsText, customID: state.customID)
        return try applyDreamBatchText(dreamText, for: state.memoryDate)
    }

    func applyDreamBatchText(_ text: String, for date: Date = Date()) throws -> DreamResult {
        guard let data = Brain.extractJSON(text)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClient.APIError.malformed("dream batch json: \(text)")
        }
        let result = try applyDreamObject(obj, for: date)
        DreamBatchStore.clear()
        Audit.record(kind: "dream.batch", summary: "已应用梦境 Batch 结果")
        return result
    }

    static func isBatchCompleted(_ status: String) -> Bool {
        ["ended", "completed", "succeeded", "done"].contains(status.lowercased())
    }

    static func extractDreamTextFromBatchResults(_ text: String, customID: String? = nil) throws -> String {
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let customID,
               let lineCustomID = obj["custom_id"] as? String,
               lineCustomID != customID {
                continue
            }
            if let result = obj["result"] as? [String: Any] {
                if let message = result["message"] as? [String: Any],
                   let text = extractTextBlocks(from: message) {
                    return text
                }
                if let text = extractTextBlocks(from: result) {
                    return text
                }
                if let error = result["error"] as? [String: Any] {
                    throw AnthropicClient.APIError.malformed("batch request failed: \(error)")
                }
            }
            if let text = extractTextBlocks(from: obj) {
                return text
            }
        }
        if let json = extractJSON(text) {
            return json
        }
        throw AnthropicClient.APIError.malformed("dream batch result jsonl: \(text)")
    }

    private static func extractTextBlocks(from obj: [String: Any]) -> String? {
        guard let content = obj["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        return text.isEmpty ? nil : text
    }

    private func applyDreamObject(_ obj: [String: Any], for date: Date) throws -> DreamResult {
        _ = try memory.snapshotLongTermFiles(reason: "dream-\(Memory.dayString(for: date))")
        if let owner = obj["owner"] as? String, !owner.isEmpty {
            try memory.writeRequired(file: "owner.md", content: owner)
        }
        if let proj = obj["projects"] as? String, !proj.isEmpty {
            try memory.writeRequired(file: "projects.md", content: proj)
        }
        if let selfNote = obj["self"] as? String, !selfNote.isEmpty {
            try memory.writeRequired(file: "self.md", content: selfNote)
        }

        var skillName: String? = nil
        if let name = obj["new_skill_name"] as? String,
           let body = obj["new_skill_body"] as? String,
           !name.trimmingCharacters(in: .whitespaces).isEmpty,
           !body.trimmingCharacters(in: .whitespaces).isEmpty {
            try memory.addSkillRequired(name: name, body: body)
            skillName = name
        }
        try memory.clearNotes(for: date)

        let settlement = Evolution(memory: memory).settleAfterDream(
            state: PetState.load(),
            eventCount: EventBus.lines(for: date).count
        )

        return DreamResult(
            morningWords: obj["morning_words"] as? String ?? "",
            newSkill: skillName,
            evolutionSummary: settlement.summary,
            proposalTitle: settlement.proposal?.title
        )
    }
}
