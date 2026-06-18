import Foundation

/// Bilingual string table. Access via `L.key`.
/// Language is persisted in UserDefaults; default is English.
/// Not actor-isolated: backed only by thread-safe UserDefaults so it can be
/// read from any context (e.g. GrowthStage, Brain prompt building).
enum Lang: String {
    case en, zh
}

enum L {
    // MARK: - Language state

    static var current: Lang {
        get {
            let raw = UserDefaults.standard.string(forKey: "gugu.language") ?? "en"
            return Lang(rawValue: raw) ?? .en
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "gugu.language")
        }
    }

    /// Convenience: pick between zh/en variants.
    private static func s(_ zh: String, _ en: String) -> String {
        current == .zh ? zh : en
    }

    // MARK: - Menu bar / Console

    static var menuTooltip: String { s("咕咕", "Gugu") }
    static var menuAccessibility: String { s("咕咕菜单", "Gugu Menu") }
    static var menuChat: String { s("和咕咕说话…", "Talk to Gugu…") }
    static var menuPoke: String { s("戳一下", "Poke") }
    static var menuHome: String { s("进入小窝", "Open Home") }
    static var menuHomeClose: String { s("离开小窝", "Close Home") }
    static var homeHint: String { s("点左上角的画笔,画条线，我就能站上去啦~",
                                    "Tap the pencil top-left and draw a line — I can stand on it!") }
    static var menuHeartbeatDebug: String { s("心跳一次(调试)", "Heartbeat (debug)") }
    static var menuDreamDebug: String { s("做梦一次(调试)", "Dream (debug)") }
    static var menuAudit: String { s("今天看到了什么", "Today's observations") }
    static var menuProposals: String { s("待批准提案", "Pending proposals") }
    static var menuApproveNext: String { s("批准下一个提案", "Approve next proposal") }
    static var menuOpenConfig: String { s("打开配置目录", "Open config folder") }
    static var menuQuit: String { s("退出", "Quit") }
    static var menuLanguage: String { s("语言 / Language", "Language / 语言") }
    static var menuLangZH: String { "中文" }
    static var menuLangEN: String { "English" }
    /// Toggle target: shows the *other* language as the action label.
    static var menuLangSwitch: String { current == .en ? "中文" : "English" }

    // Quick menu
    static var menuActions: String { s("动作", "Actions") }
    static var menuDance: String { s("跳舞", "Dance") }
    static var menuHop: String { s("蹦跳", "Hop") }
    static var menuFly: String { s("飞一下", "Fly") }
    static var menuPerch: String { s("站窗口", "Perch") }
    static var menuSettle: String { s("蹲坐", "Settle") }
    static var menuGroom: String { s("理毛", "Groom") }
    static var menuSleep: String { s("睡觉", "Sleep") }

    // Sensory toggles
    static var toggleCameraOn: String { s("闭上眼睛", "Close eyes") }
    static var toggleCameraOff: String { s("睁眼看你", "Open eyes") }
    static var toggleVoiceOn: String { s("安静", "Mute") }
    static var toggleVoiceOff: String { s("出声说话", "Speak aloud") }

    static var toggleListenOff: String { s("对咕咕说话", "Talk to Gugu") }
    static var toggleListenStarting: String { s("正在接入…", "Connecting…") }
    static var toggleListenListening: String { s("正在听你说", "Listening…") }
    static var toggleListenMuted: String { s("咕咕在说话…", "Gugu is talking…") }
    static var toggleListenUnavailable: String { s("麦克风不可用", "Mic unavailable") }

    // Quick panel labels
    static var panelTalk: String { s("说话", "Talk") }
    static var panelPoke: String { s("戳一下", "Poke") }
    static var panelCamera: String { s("摄像头", "Camera") }
    static var panelVoice: String { s("朗读", "Voice") }
    static var panelMic: String { s("麦克风", "Mic") }
    static var panelAbilities: String { s("才艺", "Abilities") }

    // MARK: - Status line

    static var statusPrefix: String { s("状态", "Status") }
    static var statusDND: String { s("勿扰中", "DND") }
    static var statusSleeping: String { s("睡着了", "Sleeping") }
    static var growthPrefix: String { s("形态", "Stage") }
    static func proposalsPending(_ n: Int) -> String {
        s("\(n) 个提案待批", "\(n) proposal\(n == 1 ? "" : "s") pending")
    }

    // Short status chips
    static var shortSleep: String { s("睡", "Zzz") }
    static var shortDND: String { s("静", "DND") }
    static var shortFocused: String { s("专", "Fcs") }
    static var shortBusy: String { s("忙", "Bsy") }
    static var shortBreather: String { s("歇", "Brk") }
    static var shortAway: String { s("离", "Awy") }
    static var shortActive: String { s("闲", "Idl") }
    static var shortAgitated: String { s("躁", "Agt") }

    // MARK: - Chat input

    static var chatPlaceholder: String { s("对咕咕说…", "Say something to Gugu…") }
    static var chatThinking: String { s("咕咕在想...", "Gugu is thinking…") }
    static var chatFailed: String { s("咕咕没听清。", "Gugu didn't catch that.") }
    /// 模型回了空(既没话也没动作)时的轻量占位,避免"反应丢失"。
    static var chatNoReply: String { s("(咕咕歪头看了看你)", "(Gugu tilts its head at you)") }
    static var chatDragTooltip: String { s("拖动输入框", "Drag input") }
    static var chatCloseTooltip: String { s("关闭输入框", "Close input") }

    // Error messages with guidance
    static var errorNoApiKey: String {
        s("(咕咕想说话,但还没接上脑子。右键我 → 设置,填上 API Key)",
          "(Gugu wants to talk, but the brain isn't connected yet. Right-click me → Settings, add your API Key)")
    }
    static var errorAuthFailed: String {
        s("(咕咕脑子接不上了,密钥可能失效了。右键我 → 设置)",
          "(Can't connect — API key might be invalid. Right-click me → Settings)")
    }
    static var errorNetwork: String {
        s("(咕咕的脑子在远方,网络卡住了,等会儿再试?)",
          "(My brain is far away — network hiccup. Try again in a moment?)")
    }

    // MARK: - Greetings

    static var greetingNew: String { s("咕?(歪头看了看你)", "Gu? (tilts head curiously)") }
    static var greetingNeedsSetup: String {
        s("咕!(我还没接上脑子。右键我 → 设置,填上 API Key 就能和你说话了)",
          "Gu! (My brain isn't connected yet. Right-click me → Settings, add an API Key so I can talk to you)")
    }
    static var greetingBonded: String { s("你来啦!", "Hey, you're back!") }
    static var greetingDefault: String { s("咕咕。", "Gu gu.") }

    // MARK: - Growth stages

    static var stageHatchling: String { s("幼鸟", "Hatchling") }
    static var stageFledgling: String { s("雏鸟", "Fledgling") }
    static var stageAdult: String { s("成鸟", "Adult") }
    static var stageSpirit: String { s("灵鸟", "Spirit") }

    static var stageShortHatchling: String { s("幼", "H") }
    static var stageShortFledgling: String { s("雏", "F") }
    static var stageShortAdult: String { s("成", "A") }
    static var stageShortSpirit: String { s("灵", "S") }

    // MARK: - Pet speech

    static var woke: String { s("咕醒了。", "Gugu is awake.") }
    static var pokeReaction: String { s("嗯?", "Hm?") }
    static var voiceTest: String { s("咕!", "Gu!") }
    static var stopListening: String { s("好,我先不听了。", "Okay, I'll stop listening.") }
    static var cameraOpened: String { s("(咕咕睁开眼睛看了看你)", "(Gugu opens eyes and looks at you)") }
    static var cameraClosed: String { s("(咕咕闭上了眼睛)", "(Gugu closes eyes)") }
    static var cameraDenied: String { s("咕咕想睁眼,但系统没给摄像头权限。到「系统设置 → 隐私与安全 → 摄像头」里把咕咕勾上吧~",
                                        "I tried to open my eyes but macOS hasn't granted camera access. Enable Gugu in System Settings → Privacy & Security → Camera.") }
    static var cameraNoDevice: String { s("(咕咕眨眨眼,没找到摄像头)", "(Gugu blinks — no camera found)") }
    static var dreamEnter: String { s("(进入梦乡…)", "(Drifting off to dream…)") }
    static var dreamFailed: String { s("梦没做成。", "Dream didn't work out.") }
    static func dreamProposal(_ title: String) -> String {
        s("我梦见自己好像能长大了。\(title),等你批准。",
          "I dreamed I could grow. \(title) — waiting for your approval.")
    }
    static var proposalFailed: String { s("这个提案没法批准。", "Can't approve this proposal.") }
    static func proposalApproved(_ title: String) -> String {
        s("批准了。\(title)", "Approved. \(title)")
    }
    static var budgetSleepy: String { s("(今天想了好多事,有点困了…)", "(Thought a lot today, getting sleepy…)") }
    static var micUnavailable: String { s("麦克风现在用不了。", "Mic isn't available right now.") }
    static var voiceFailed: String { s("我刚才没听明白,你再说一遍。", "I didn't catch that. Say it again?") }
    static var voiceFailedNoKey: String {
        s("(咕咕还没接上脑子,先去菜单栏图标 → 设置里填 API Key)",
          "(Brain not connected yet — go to menu bar icon → Settings to add API Key)")
    }
    static var voiceFailedAuth: String {
        s("(密钥好像失效了,去设置里看看?)", "(API key seems invalid — check Settings?)")
    }
    static var grewUp: String { s("我好像长大了一点。", "I think I grew a little.") }
    static var perchCooldown: String { s("(刚试过，等一下再站)", "(Just tried, give me a sec)") }
    static var perchNoWindow: String { s("(没找到能站的窗口)", "(No window to perch on)") }

    // Abilities
    static var abilitiesSpeech: String {
        s("我会聊天、跳舞、蹦一下、飞一下、理毛,也能看你回来、听唤醒词。",
          "I can chat, dance, hop, fly, groom — and notice when you come back or call my name.")
    }

    // MARK: - Discovery hints

    static var hintPoke: String { s("(歪头)你可以戳戳我。", "(tilts head) You can poke me.") }
    static var hintPet: String { s("摸摸我嘛,双击我。", "Pet me — double-click me.") }
    static var hintLearn: String {
        s("你可以教我新动作,跟我说\"学个翻跟头\"。",
          "You can teach me new moves — say \"learn a backflip\".")
    }
    static var hintChat: String {
        s("想说话就右键我,选\"和咕咕说话\"。",
          "To talk, right-click me and pick \"Talk to Gugu\".")
    }

    // MARK: - Milestones

    static var milestoneInteract10: String {
        s("我们已经玩了好一会儿了,我开始喜欢你了。", "We've played for a while now — I'm starting to like you.")
    }
    static var milestoneInteract50: String {
        s("和你在一起的每一下,我都记着呢。", "Every moment with you, I remember it.")
    }
    static var milestoneBond30: String {
        s("(蹭了蹭你)我好像有点黏你了。", "(nuzzles you) I think I'm getting attached to you.")
    }
    static var milestoneBond50: String { s("你是我最熟的人了。", "You're the one I know best now.") }
    static var milestoneBond80: String { s("无论你忙不忙,我都在这儿。", "Busy or not, I'm right here.") }
    static var milestoneDays3: String { s("我们认识三天啦。", "We've known each other three days now.") }
    static var milestoneDays7: String {
        s("一整个星期了,谢谢你没把我关掉。", "A whole week — thank you for not closing me.")
    }
    static var milestoneDays30: String {
        s("三十天了。我已经是你桌面的一部分了吧?", "Thirty days. I'm part of your desktop now, aren't I?")
    }
    static var milestoneMove1: String { s("我学会第一个新动作了!", "I learned my first new move!") }
    static var milestoneMove3: String {
        s("我会的动作越来越多了,要不要再教我一个?", "I know more and more moves — want to teach me another?")
    }

    // MARK: - Poke combo reactions

    static var pokeAnnoyed: String { s("(扭头)别戳啦。", "(turns away) Stop poking.") }
    static var pokeDizzy: String { s("呜…头晕了。", "Ugh… I'm dizzy.") }
    static var pokeFlee: String { s("(躲开)不理你了!", "(dodges) I'm ignoring you now!") }

    // MARK: - Learn move

    static var learnAlreadyKnow: String { s("这个我会呀,你看——", "I know this one — watch!") }
    static func learnTrying(_ intent: String) -> String {
        s("我…试试看怎么\(intent)。", "Let me… try to figure out how to \(intent).")
    }
    static var learnCantDo: String {
        s("这个我学不会,身子做不出来这个动作。", "I can't learn this — my body can't make that move.")
    }
    static func learnGotDraft(_ name: String) -> String {
        s("我好像学会「\(name)」了!你批准我就会了。",
          "I think I learned \"\(name)\"! Approve it and I'll have it.")
    }
    static var learnFailed: String { s("唔,我没学会,等下再教我?", "Hmm, I didn't get it. Teach me again later?") }
    static var learnFailedNoKey: String {
        s("(还没接上脑子,没法学。右键我 → 设置)",
          "(Brain not connected — can't learn yet. Right-click me → Settings)")
    }

    // MARK: - Rhythm display names

    static var rhythmFocused: String { s("专注工作", "Focused") }
    static var rhythmBusy: String { s("忙碌操作", "Busy") }
    static var rhythmBreather: String { s("歇口气", "Breather") }
    static var rhythmAway: String { s("离开", "Away") }
    static var rhythmActive: String { s("活跃", "Active") }
    static var rhythmAgitated: String { s("可能烦躁", "Agitated") }

    // MARK: - Action labels (for chat log)

    static func actionLabel(_ a: String) -> String {
        switch a {
        case "come", "approach": return s("扑棱扑棱跑过来了", "Fluttered over to you")
        case "walk": return s("走了两步", "Took a few steps")
        case "fly": return s("飞了起来", "Took flight")
        case "perch": return s("飞上去站住了", "Flew up and perched")
        case "settle", "sit": return s("蹲下来,把脚收进羽毛里歇着", "Settled down, tucked feet in")
        case "dance": return s("晃起身子来", "Started dancing")
        case "hop", "jump": return s("蹦了一下", "Hopped")
        case "nod", "yes": return s("一点一点地点头", "Nodded")
        case "stare": return s("歪头盯着你", "Tilted head, staring")
        case "peck": return s("啄了啄", "Pecked")
        case "groom": return s("理了理毛", "Groomed feathers")
        case "retreat", "away": return s("扭头走开了", "Turned and walked away")
        case "sleep": return s("打起瞌睡", "Dozed off")
        default: return a
        }
    }

    // MARK: - Audit report

    static var auditTitle: String { s("# 咕咕今天看到了什么", "# What Gugu noticed today") }
    static var auditProposals: String { s("## 待批准提案", "## Pending proposals") }
    static var auditEvents: String { s("## 今日感知事件", "## Today's events") }
    static var auditSection: String { s("## 今日审计", "## Today's audit") }
    static var auditEmpty: String { s("(暂无)", "(none yet)") }
    static var auditNone: String { s("无", "None") }
    static var auditPending: String { s("暂无", "Nothing yet") }
    static func auditGeneratedAt(_ time: String) -> String { s("生成时间:\(time)", "Generated at: \(time)") }
    static var auditCurrentState: String { s("## 当前状态", "## Current state") }
    static func auditStage(_ v: String) -> String { s("- 形态:\(v)", "- Stage: \(v)") }
    static func auditPendingStage(_ v: String) -> String { s("- 待进化:\(v)", "- Pending growth: \(v)") }
    static func auditDays(_ v: Int) -> String { s("- 相处天数:\(v)", "- Days together: \(v)") }
    static func auditEventCount(_ v: Int) -> String { s("- 事件数:\(v)", "- Events seen: \(v)") }
    static func auditInteractions(_ v: Int) -> String { s("- 互动数:\(v)", "- Interactions: \(v)") }
    static func auditBond(_ v: String) -> String { s("- 羁绊:\(v)", "- Bond: \(v)") }
    static func auditTrust(_ v: String) -> String { s("- 信任:\(v)", "- Trust: \(v)") }
    static var auditUsage: String { s("## 用量", "## Usage") }

    // MARK: - Budget

    static func budgetLine(total: Int, daily: Int, calls: Int) -> String {
        s("今日 \(total) / \(daily) tokens · \(calls) 次",
          "Today \(total) / \(daily) tokens · \(calls) calls")
    }

    // MARK: - Evolution

    static func evolvedTo(_ name: String) -> String {
        s("主人批准咕咕长成了\(name)。", "Owner approved Gugu's growth to \(name).")
    }
    static func evolutionProposalTitle(_ target: String) -> String {
        s("请求长成\(target)", "Request to grow into \(target)")
    }
    static var proposalUnnamed: String { s("未命名提案", "Unnamed proposal") }
    static var proposalStatusPending: String { s("状态:待主人批准", "Status: awaiting owner approval") }
    static func proposalGeneratedAt(_ time: String) -> String {
        s("生成时间:\(time)", "Generated at: \(time)")
    }
    static func proposalGrowthReason(_ old: String, _ new: String) -> String {
        s("咕咕觉得自己从\(old)长到\(new)的条件已经接近成熟。",
          "Gugu feels the conditions to grow from \(old) to \(new) are nearly ripe.")
    }
    static var proposalMetricsHeader: String { s("当前指标:", "Current metrics:") }
    static func proposalMetricDays(_ v: Int) -> String { s("- 相处天数:\(v)", "- Days together: \(v)") }
    static func proposalMetricEvents(_ v: Int) -> String { s("- 见过事件:\(v)", "- Events seen: \(v)") }
    static func proposalMetricInteractions(_ v: Int) -> String { s("- 互动次数:\(v)", "- Interactions: \(v)") }
    static func proposalMetricBond(_ v: String) -> String { s("- 羁绊:\(v)", "- Bond: \(v)") }
    static func proposalMetricTrust(_ v: String) -> String { s("- 信任:\(v)", "- Trust: \(v)") }
    static func proposalMetricSkills(_ v: Int) -> String { s("- 技能数:\(v)", "- Skills: \(v)") }
    static var proposalStageFooter: String {
        s("需要主人确认后才会生效。批准后只提升阶段;记忆、安全内核和现有边界保持不变。",
          "Takes effect only after owner approval. Approval raises the stage only — memory, safety core, and existing boundaries stay unchanged.")
    }

    // MARK: - Local tool executor

    static var noteRecorded: String { s("已记录笔记", "Note saved") }
    static var reminderRecorded: String { s("已记录提醒事项", "Reminder saved") }
    static func reminderRecordedWithDue(_ due: String) -> String {
        s("已记录提醒事项(\(due))", "Reminder saved (\(due))")
    }
    static func reminderScheduled(_ time: String) -> String {
        s("已记录提醒事项,会在 \(time) 提醒你", "Reminder saved — will notify at \(time)")
    }
    static var notesNotAuthorized: String {
        s("notes.add 未授权:请先在配置中开启 tools.notes",
          "notes.add not authorized: enable tools.notes in config first")
    }
    static var remindersNotAuthorized: String {
        s("reminders.add 未授权:请先在配置中开启 tools.reminders",
          "reminders.add not authorized: enable tools.reminders in config first")
    }
    static var webSearchNotAuthorized: String {
        s("web_search 未授权:请先在配置中开启 tools.web_search",
          "web_search not authorized: enable tools.web_search in config first")
    }
    /// 联网搜索目前只记录请求、尚未真正出网(框架就绪,出网待接入)。
    static var webSearchRecorded: String {
        s("我把要查的记下了,等我能上网了就去查。",
          "Noted what to look up — I'll search once I can go online.")
    }
    static var reminderNotificationTitle: String { s("咕咕提醒事项", "Gugu Reminder") }
    /// Date format for the scheduled-reminder confirmation.
    static var reminderDateFormat: String { s("M月d日 HH:mm", "MMM d, HH:mm") }

    // MARK: - Deferred / autonomy

    static func deferredTask(_ title: String) -> String {
        s("放到夜里做了。\(title)", "Deferred to tonight. \(title)")
    }
    static var autonomyEnqueueFailed: String {
        s("这个夜里任务没放进去。", "Couldn't queue that night task.")
    }
    static var cannotDoYet: String {
        s("这个我还不能做。我把申请放到提案里了。",
          "I can't do that yet. I've filed it as a proposal.")
    }

    // MARK: - Event summaries

    static var eventWake: String { s("咕咕来到了主人的桌面", "Gugu arrived on owner's desktop") }
    static var eventPoke: String { s("主人戳了你一下", "Owner poked you") }
    static var eventPetted: String { s("主人摸了摸你", "Owner petted you") }
    static var eventThrown: String { s("主人把你扔了出去,摔了个跟头", "Owner tossed you — tumbled!") }
    static func eventChat(_ text: String) -> String {
        s("主人和你聊天:\(text)", "Owner chatted: \(text)")
    }
    static func eventVoice(_ text: String) -> String {
        s("主人对你说:\(text)", "Owner said: \(text)")
    }
    static var eventSeeReturn: String { s("你看见主人回到座位上了", "Saw owner return to seat") }
    static var eventSeeLeave: String { s("你看见主人离开了座位", "Saw owner leave seat") }
    static var eventSeeSmile: String { s("你看见主人在笑", "Saw owner smile") }
    static func eventLateNight(_ hour: Int) -> String {
        s("主人深夜(\(hour)点)还在高强度工作", "Owner still working intensely at \(hour):00")
    }
    static func eventAppSwitch(_ name: String, _ dwell: String) -> String {
        s("主人切到了 \(name)\(dwell)", "Owner switched to \(name)\(dwell)")
    }
    static func eventProposalApproved(_ title: String) -> String {
        s("主人批准提案:\(title)", "Owner approved proposal: \(title)")
    }

    // MARK: - Language switch

    static var langSwitched: String { s("好,说中文。", "Okay, English now.") }

    /// Directive appended to every LLM system prompt so the bird speaks the
    /// owner's chosen language. Persona stays Chinese; this overrides output.
    static var llmLanguageDirective: String {
        s("请始终用简体中文回答,包括 speech、aside、记忆等所有自然语言字段。",
          "Always respond in English for all natural-language fields (speech, aside, memory notes, morning words, etc.), even though the instructions above are in Chinese. Stay in character as a small bird: very short utterances.")
    }

    // MARK: - LLM prompt fragments (growth-stage speech guidance)

    static var speechGuidanceHatchling: String {
        s("你现在还是幼鸟:多用很短的词、拟声和动作回应;复杂事情可以听懂,但说出来要笨拙一点。",
          "You're still a hatchling: reply mostly with very short words, onomatopoeia, and actions; you understand complex things but speak them clumsily.")
    }
    static var speechGuidanceFledgling: String {
        s("你现在是雏鸟:能说短句,会表达观察,但仍然保持小鸟式的直接和有限记忆。",
          "You're now a fledgling: you can speak short sentences and voice observations, but stay bird-like — direct, with limited memory.")
    }
    static var speechGuidanceAdult: String {
        s("你现在是成鸟:能正常短句对话,有稳定性格,会主动关心但不过度打扰。",
          "You're now an adult: you converse in normal short sentences, have a stable personality, and show care without being intrusive.")
    }
    static var speechGuidanceSpirit: String {
        s("你现在是灵鸟:可以偶尔有自己的观点和玩笑,但仍必须诚实、短句、基于真实观察。",
          "You're now a spirit bird: you may occasionally voice your own opinions and jokes, but must stay honest, brief, and grounded in real observation.")
    }

    // MARK: - LLM prompt fragments (learn-move designer)

    /// System prompt for the move-designer call (Brain.learnMove).
    static var learnMoveSystemPrompt: String {
        s("""
        你是咕咕(一只桌面小鸟)的身体动作设计师。主人想教咕咕学一个新动作。
        你只能用下列身体基元把动作拼出来,不能凭空创造新能力:
        move(平移) rotate(旋转,弧度) scale(挤压拉伸) flap(扑翅) hop(蹦) wait(停顿)
        say(说一句短话) view(朝向front/back/side) tilt(歪头) blush(脸红) peck(啄) groom(理毛)
        约束:最多12步,总时长≤8秒,单步≤2秒,平移≤120点,旋转≤两圈,台词≤24字。
        要点:动作要可爱、有辨识度、像这只小鸟会做的。鞠躬就身子下沉再起来;
        转圈就左右摆配合扑翅;点头就上下小幅移动。如果用这些基元根本表现不了(比如需要新身体部件),
        就把 feasible 设为 false,steps 给一个最接近的近似。
        """,
        """
        You are the body-motion designer for Gugu (a desktop bird). The owner wants to teach Gugu a new move.
        You may only compose the move from the following body primitives — you cannot invent new abilities:
        move (translate) rotate (radians) scale (squash/stretch) flap (wings) hop wait
        say (one short line) view (face front/back/side) tilt (head) blush peck groom
        Constraints: at most 12 steps, total duration ≤8s, each step ≤2s, translation ≤120pt, rotation ≤two turns, any spoken line ≤24 chars.
        Aim for moves that are cute, recognizable, and in-character for this little bird. A bow dips the body down then up;
        a spin sways left-right with wing flaps; a nod moves up and down in small steps. If these primitives genuinely can't express it (e.g. it needs a new body part),
        set feasible to false and give the closest approximation in steps.
        """)
    }

    /// User message for the move-designer call. `intent` is the owner's phrasing.
    static func learnMoveUserMessage(_ intent: String) -> String {
        s("主人想教咕咕的动作是:「\(intent)」。请设计这个动作的分解步骤。",
          "The move the owner wants to teach Gugu is: \"\(intent)\". Design the step-by-step breakdown of this move.")
    }

    // MARK: - Scheduler / config

    static var configReloaded: String { s("配置已重新加载", "Config reloaded") }

    // MARK: - Structured-output hint (OpenAI-compatible providers)

    static var schemaHintHeader: String {
        s("只输出一个 JSON 对象,包含且仅包含以下字段:",
          "Output only a single JSON object with exactly these fields:")
    }
    static var schemaHintRequired: String { s("(必填)", " (required)") }
    static var schemaHintGeneric: String {
        s("只输出一个合法的 JSON 对象,不要包含其它文字。",
          "Output only a valid JSON object, with no other text.")
    }

    // MARK: - Settings window

    static var menuSettings: String { s("设置…", "Settings…") }
    static var settingsTitle: String { s("咕咕设置", "Gugu Settings") }
    static var settingsProvider: String { s("协议", "Protocol") }
    static var settingsProviderAnthropic: String { s("Anthropic", "Anthropic") }
    static var settingsProviderOpenAI: String { s("OpenAI 兼容", "OpenAI-compatible") }
    static var settingsURL: String { s("接口地址", "API URL") }
    static var settingsKey: String { s("密钥", "API Key") }
    static var settingsModel: String { s("模型", "Model") }
    static var settingsAdvanced: String { s("高级", "Advanced") }
    static var settingsTierModels: String { s("分层模型(留空=用上面的模型)", "Per-tier models (blank = use base)") }
    static var settingsInheritsBase: String { s("继承基础模型", "inherits base model") }
    static var settingsSparkOff: String { s("留空=不启用灵光", "blank = spark off") }
    static var settingsInstinctModel: String { s("心跳层", "Instinct") }
    static var settingsConversationModel: String { s("对话层", "Conversation") }
    static var settingsDreamModel: String { s("梦境层", "Dream") }
    static var settingsSparkModel: String { s("灵光层", "Spark") }
    static var settingsMaxTokens: String { s("输出上限(tokens)", "Max output (tokens)") }
    static var settingsInstinctTokens: String { s("心跳层", "Instinct") }
    static var settingsConversationTokens: String { s("对话层", "Conversation") }
    static var settingsDreamTokens: String { s("梦境层", "Dream") }
    static var settingsSparkTokens: String { s("灵光层", "Spark") }
    static var settingsBudget: String { s("预算", "Budget") }
    static var settingsDailyTokens: String { s("每日 tokens", "Daily tokens") }
    static var settingsSave: String { s("保存", "Save") }
    static var settingsCancel: String { s("取消", "Cancel") }
    static var settingsSaveFailed: String { s("保存失败", "Save failed") }

    // MARK: - Listener wake words (used for matching, not display)

    static var wakeWordsZH: [String] { ["咕咕", "股股", "古古", "咕鸟", "小咕"] }
    static var wakeWordsEN: [String] { ["gugu", "hey gugu", "hi gugu", "hey goo goo", "goo goo"] }
    static var wakeWords: [String] { current == .zh ? wakeWordsZH : (wakeWordsZH + wakeWordsEN) }
}
