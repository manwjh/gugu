import Foundation
import GuguKernel

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

    /// Persona plus the active-language directive, so the bird speaks the chosen language.
    private var systemPrompt: String {
        personaText + "\n\n" + L.llmLanguageDirective
    }

    /// The single LLM transport: OpenAI-compatible Chat Completions (taas.hk).
    private var client: OpenAIClient {
        OpenAIClient(baseURL: config.apiURL, apiKey: config.apiKey)
    }

    // MARK: - L2 Heartbeat

    static let heartbeatSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mood": ["type": "string", "enum": ["开心", "平静", "好奇", "心疼", "无聊", "困", "委屈"]],
            "action": ["type": "string", "enum": ["idle", "walk", "approach", "retreat", "perch", "sleep", "dance", "stare", "peck", "groom", "yawn"]],
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
        lines.append(Perception.shared.summaryForBrain())   // 一致的"此刻"快照(六路感知收口)
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
        - 本地物品识别:用系统内置识别,摄像头开启时可低置信度地"好像看见"猫、狗;若装了本地物品检测模型,还能认杯子、手机、键盘、书、瓶子等常见物品(当前\(localObjectRecognitionAvailable ? "检测模型已装" : "检测模型未装,只认猫狗")),并通过短窗口轨迹判断出现/消失/移动。只在本机分析,不保存或上传图像;没真看到时不要硬说看见了具体东西。
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
            model: config.modelId,
            maxTokens: 200,
            system: systemPrompt,
            messages: [["role": "user", "content": userMsg]],
            schema: Brain.heartbeatSchema,
            policy: .heartbeat
        )
        budget.record(inputChars: personaText.count + userMsg.count,
                      outputChars: reply.text.count, label: "instinct")
        return try Brain.parseHeartbeat(reply.text)
    }

    static func parseHeartbeat(_ text: String) throws -> HeartbeatDecision {
        guard let data = extractJSON(text)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformed("heartbeat json: \(text)")
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

    /// Classify an error for user-facing messages. Returns a user-friendly message
    /// based on the error type, checking config state to give actionable guidance.
    static func userMessage(for error: Error, config: Config) -> String {
        // Check if API key is missing first (most common first-time issue)
        if config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return L.errorNoApiKey
        }

        // Classify the actual error
        if let llmError = error as? LLMError {
            switch llmError {
            case .http(let code, _):
                // Authentication/authorization failures
                if code == 401 || code == 403 {
                    return L.errorAuthFailed
                }
                // Other HTTP errors (rate limit, server error, etc.)
                return L.chatFailed
            case .transport, .timeout:
                return L.errorNetwork
            case .malformed, .empty:
                return L.chatFailed
            }
        }

        // Fallback for unknown error types
        return L.chatFailed
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
            result = executor.execute(.init(name: "web_search.request", arguments: ["query": command.content]))
            if !result.allowed {
                _ = ProposalEngine().writeToolPermissionProposal(title: "请求学会联网查东西", key: "tools.web_search")
            }
        }

        let reply: String
        if result.ok {
            reply = result.message
        } else if result.allowed {
            reply = result.message
        } else {
            reply = L.cannotDoYet
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
            return L.deferredTask(task.title)
        } catch {
            Log.info("autonomy", "入队失败: \(error)")
            return L.autonomyEnqueueFailed
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
        // 固定记忆已在 handleLocalCommand(两条链路的统一首步)里捕获过,这里不再重复,
        // 否则同一句话会写两条 Record + 两条审计(来源还不一致)。
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

        // budget degrade: shorter output when running hot (one model — it's the
        // token cap that drops, not the model).
        let maxTokens = budget.degradeLevel >= 1 ? 200 : 400
        let reply: LLMReply
        do {
            reply = try await client.create(
                model: config.modelId,
                maxTokens: maxTokens,
                system: systemPrompt,
                messages: messages,
                schema: Brain.chatSchema,
                policy: .chat
            )
        } catch let e as LLMError {
            // 200 但没产出 content(偶发,尤其富上下文下模型把话"想"在 reasoning 里):
            // 咕咕用一个非语言小反应(歪头点头)回应,而不是弹通用报错——既不破活物感,
            // 也不把"没答上"写进 chatHistory(避免污染后续轮次)。真错误(网络/超时/鉴权)仍上抛。
            if case .empty = e {
                Log.info("chat", "空内容降级:非语言回应(nod)")
                return ChatResult(reply: "", action: "nod")
            }
            throw e
        }
        budget.record(inputChars: personaText.count + messages.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) },
                      outputChars: reply.text.count, label: "conversation")

        // Default empty (not reply.text): chat always requests structured JSON,
        // so if extraction fails we degrade to an action-only / blank reply rather
        // than leaking raw model output (e.g. chain-of-thought) into the bubble.
        var replyText = ""
        var aside = ""
        var action = "idle"
        if let data = Brain.extractJSON(reply.text)?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            replyText = (obj["speech"] as? String) ?? (obj["reply"] as? String) ?? ""
            aside = (obj["aside"] as? String) ?? ""
            action = (obj["action"] as? String) ?? "idle"
        }
        // Normalize whitespace-only fields to empty so a blank speech degrades to
        // an action-only reply (no empty bubble) instead of showing whitespace.
        replyText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        aside = aside.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("chat", "解析:action=\(action) reply空=\(replyText.isEmpty) aside空=\(aside.isEmpty) | 原文前100: \(reply.text.prefix(100))")
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

    // MARK: - 动作学习(动作进化:把主人的口头要求翻译成元动作编排)

    /// 单步编排的 schema:op 限定在白名单基元内,其余为可选参数。
    static let moveStepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "op": ["type": "string",
                   "enum": MetaOp.allCases.map { $0.rawValue },
                   "description": "身体基元。move=平移 rotate=旋转(弧度) scale=挤压拉伸 flap=扑翅 hop=蹦 wait=停顿 say=说一句 view=朝向 tilt=歪头 blush=脸红 peck=啄 groom=理毛 manpu=冒情绪符号"],
            "dx": ["type": "number", "description": "move:水平位移(点,±120内)"],
            "dy": ["type": "number", "description": "move:垂直位移(点,±120内)"],
            "by": ["type": "number", "description": "rotate:旋转弧度(一圈=6.283)"],
            "x": ["type": "number", "description": "scale:横向比例(0.3~2)"],
            "y": ["type": "number", "description": "scale:纵向比例(0.3~2)"],
            "dur": ["type": "number", "description": "本步时长(秒,≤2)"],
            "times": ["type": "integer", "description": "flap:扇动次数(1~30)"],
            "fast": ["type": "boolean", "description": "flap:是否快速"],
            "height": ["type": "number", "description": "hop:跳起高度(点,≤80)"],
            "text": ["type": "string", "description": "say:要说的短话(≤24字)"],
            "dir": ["type": "string", "enum": ["front", "back", "side"], "description": "view:朝向"],
            "on": ["type": "boolean", "description": "tilt/blush:开或关"],
            "kind": ["type": "string", "enum": Array(MoveLimits.validManpu).sorted(),
                     "description": "manpu:情绪符号(sweat汗 anger怒 surprise惊 love心 music音符 question问号 dizzy晕)"],
        ],
        "required": ["op"],
        "additionalProperties": false,
    ]

    static var moveSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "动作的简短名字(≤8字),如:翻跟头、作揖"],
                "trigger": ["type": "string", "description": "主人说什么时触发这个动作,一个短词,如:翻跟头"],
                "steps": [
                    "type": "array",
                    "description": "动作分解成的若干步(≤12步,总时长≤8秒)。只能用给定的身体基元拼。",
                    "items": moveStepSchema,
                ],
                "feasible": ["type": "boolean", "description": "用现有身体基元能不能大致表现这个动作。完全做不到就填 false"],
            ],
            "required": ["name", "trigger", "steps", "feasible"],
            "additionalProperties": false,
        ]
    }

    struct LearnedMoveDraft {
        let move: Move
        let feasible: Bool
    }

    /// 明确告诉模型 steps 的 JSON 形状 + 一个完整示例。
    /// 关键:很多 OpenAI 兼容通道只支持 response_format=json_object(不强制 json_schema),
    /// 仅靠字段名模型会把 steps 猜成字符串数组。给出"每步是带 op 的对象"的实例可根治。
    static var moveFormatSpec: String {
        let intro = L.current == .zh
            ? "严格只输出一个 JSON 对象。steps 必须是数组,每个元素是一个对象且必须含 \"op\" 字段;按需带参数。可用 op 与参数:"
            : "Output strictly one JSON object. \"steps\" must be an array whose every element is an object containing an \"op\" field, with optional params. Available ops and params:"
        return """
        \(intro)
        move(dx,dy,dur) rotate(by,dur) scale(x,y,dur) flap(times,fast) hop(height,dur) wait(dur) say(text) view(dir) tilt(on) blush(on) peck groom manpu(kind)

        \(L.current == .zh ? "示例" : "Example"):
        {"name":"招手","trigger":"招手","feasible":true,"steps":[{"op":"view","dir":"front"},{"op":"flap","times":2,"fast":true},{"op":"wait","dur":0.3},{"op":"flap","times":2,"fast":true},{"op":"say","text":"嗨"}]}
        """
    }

    /// 让模型把主人口头描述的动作翻译成一段元动作编排(只能用白名单基元)。
    /// 这一步是"它居然学会了"的灵光时刻——低频、择机、短输出(公理 A2)。
    /// 返回的草稿仍需经 move_add 提案 + 主人批准才会真正注册(公理 B2)。
    func learnMove(intent: String) async throws -> LearnedMoveDraft {
        let system = L.learnMoveSystemPrompt
        let user = L.learnMoveUserMessage(intent)
        let reply = try await client.create(
            model: config.modelId,
            maxTokens: 600,
            system: system + "\n\n" + Brain.moveFormatSpec + "\n\n" + L.llmLanguageDirective,
            messages: [["role": "user", "content": user]],
            schema: Brain.moveSchema,
            policy: .chat
        )
        budget.record(inputChars: system.count + user.count,
                      outputChars: reply.text.count, label: "instinct")
        let draft = try Brain.parseMoveDraft(reply.text, fallbackName: intent)
        Log.info("learn_move", "草稿:name=\(draft.move.name) feasible=\(draft.feasible) steps=\(draft.move.steps.count) | 原文前120: \(reply.text.prefix(120))")
        return draft
    }

    static func parseMoveDraft(_ text: String, fallbackName: String) throws -> LearnedMoveDraft {
        guard let json = extractJSON(text), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformed("move json: \(text)")
        }
        let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let trigger = (obj["trigger"] as? String) ?? name
        let feasible = (obj["feasible"] as? Bool) ?? true
        let steps = Brain.parseSteps(obj["steps"])
        let move = Move(name: name, trigger: trigger, steps: steps, origin: "learned",
                        createdAt: ISO8601DateFormatter().string(from: Date()))
        return LearnedMoveDraft(move: move, feasible: feasible)
    }

    /// 容错解析 steps:正常是对象数组 [{op,…}];也兼容模型偶尔把它给成
    /// 纯字符串数组 ["flap","wait"](OpenAI json_object 模式下常见)。数字用
    /// NSNumber 桥接读取,避免 JSON 整数/浮点混用时 `as? Double`/`as? Int` 漏读。
    static func parseSteps(_ raw: Any?) -> [MoveStep] {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        if let dicts = raw as? [[String: Any]] {
            return dicts.compactMap { dict in
                guard let op = dict["op"] as? String else { return nil }
                return MoveStep(
                    op: op,
                    dx: num(dict["dx"]), dy: num(dict["dy"]), by: num(dict["by"]),
                    x: num(dict["x"]), y: num(dict["y"]), dur: num(dict["dur"]),
                    times: int(dict["times"]), fast: dict["fast"] as? Bool,
                    height: num(dict["height"]), text: dict["text"] as? String,
                    dir: dict["dir"] as? String, on: dict["on"] as? Bool
                )
            }
        }
        if let names = raw as? [String] {
            // 退化形状:只给了基元名,补成最简步骤(参数走 clamp 默认)。
            return names.compactMap { MetaOp(rawValue: $0) != nil ? MoveStep(op: $0) : nil }
        }
        return []
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
            model: config.modelId,
            maxTokens: 1500,
            system: systemPrompt,
            messages: [["role": "user", "content": user]],
            schema: Brain.dreamSchema,
            policy: .dream
        )
        budget.record(inputChars: systemPrompt.count + user.count,
                      outputChars: reply.text.count, label: "dream")
        return try applyDreamText(reply.text, for: date)
    }

    /// Apply a dream from raw model JSON text (the path `dream()` uses after the
    /// network call). Split out so the apply/persistence logic is offline-testable.
    func applyDreamText(_ text: String, for date: Date = Date()) throws -> DreamResult {
        guard let data = Brain.extractJSON(text)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformed("dream json: \(text)")
        }
        return try applyDreamObject(obj, for: date)
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
        memory.pruneStaleSkills()   // use-it-or-lose-it: forget long-unused skills

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
