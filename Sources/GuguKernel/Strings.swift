import Foundation

/// Bilingual string table. Access via `L.key`.
/// Language is persisted in UserDefaults; default is English.
/// Not actor-isolated: backed only by thread-safe UserDefaults so it can be
/// read from any context (e.g. GrowthStage, Brain prompt building).
package enum Lang: String {
    case en, zh
}

package enum L {
    // MARK: - Language state

    package static var current: Lang {
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

    package static var menuTooltip: String { s("咕咕", "Gugu") }
    package static var menuAccessibility: String { s("咕咕菜单", "Gugu Menu") }
    package static var menuChat: String { s("和咕咕说话…", "Talk to Gugu…") }
    package static var menuWriteBlog: String { s("写一篇心流记录", "Write today's entry") }
    package static var menuOpenBlog: String { s("翻看心流记录", "Open the journal") }
    package static var blogWriting: String { s("我来写写今天…", "Let me write about today…") }
    package static var blogDone: String { s("写好啦", "Done!") }
    package static var blogFailed: String { s("没写成…", "Couldn't write it…") }
    package static var menuPoke: String { s("戳一下", "Poke") }
    package static var menuHome: String { s("进入小窝", "Open Home") }
    package static var menuHomeClose: String { s("离开小窝", "Close Home") }
    package static var menuVisionDebug: String { s("视觉调试窗口", "Vision debug panel") }
    package static var menuVisionDebugClose: String { s("关闭视觉调试", "Close vision debug") }
    package static var homeHint: String { s("点左上角的画笔,画条线，我就能站上去啦~",
                                    "Tap the pencil top-left and draw a line — I can stand on it!") }
    package static var menuHeartbeatDebug: String { s("心跳一次(调试)", "Heartbeat (debug)") }
    package static var menuDreamDebug: String { s("做梦一次(调试)", "Dream (debug)") }
    package static var menuAudit: String { s("今天看到了什么", "Today's observations") }
    package static var menuProposals: String { s("待批准提案", "Pending proposals") }
    package static var menuApproveNext: String { s("批准下一个提案", "Approve next proposal") }
    package static var menuOpenConfig: String { s("打开配置目录", "Open config folder") }
    package static var menuQuit: String { s("退出", "Quit") }
    package static var menuLanguage: String { s("语言 / Language", "Language / 语言") }
    package static var menuLangZH: String { "中文" }
    package static var menuLangEN: String { "English" }
    /// Toggle target: shows the *other* language as the action label.
    package static var menuLangSwitch: String { current == .en ? "中文" : "English" }

    // Quick menu
    package static var menuActions: String { s("动作", "Actions") }
    package static var menuDance: String { s("跳舞", "Dance") }
    package static var menuHop: String { s("蹦跳", "Hop") }
    package static var menuFly: String { s("飞一下", "Fly") }
    package static var menuPerch: String { s("站窗口", "Perch") }
    package static var menuSettle: String { s("蹲坐", "Settle") }
    package static var menuGroom: String { s("理毛", "Groom") }
    package static var menuSleep: String { s("睡觉", "Sleep") }

    // Sensory toggles
    package static var toggleCameraOn: String { s("闭上眼睛", "Close eyes") }
    package static var toggleCameraOff: String { s("睁眼看你", "Open eyes") }
    package static var toggleVoiceOn: String { s("安静", "Mute") }
    package static var toggleVoiceOff: String { s("出声说话", "Speak aloud") }

    package static var toggleListenOff: String { s("对咕咕说话", "Talk to Gugu") }
    package static var toggleListenStarting: String { s("正在接入…", "Connecting…") }
    package static var toggleListenListening: String { s("正在听你说", "Listening…") }
    package static var toggleListenMuted: String { s("咕咕在说话…", "Gugu is talking…") }
    package static var toggleListenUnavailable: String { s("麦克风不可用", "Mic unavailable") }

    // Quick panel labels
    package static var panelTalk: String { s("说话", "Talk") }
    package static var panelPoke: String { s("戳一下", "Poke") }
    package static var panelCamera: String { s("摄像头", "Camera") }
    package static var panelVoice: String { s("朗读", "Voice") }
    package static var panelMic: String { s("麦克风", "Mic") }
    package static var panelAbilities: String { s("才艺", "Abilities") }

    // MARK: - Status line

    package static var statusPrefix: String { s("状态", "Status") }
    package static var statusDND: String { s("勿扰中", "DND") }
    package static var statusSleeping: String { s("睡着了", "Sleeping") }
    package static var growthPrefix: String { s("形态", "Stage") }
    package static func proposalsPending(_ n: Int) -> String {
        s("\(n) 个提案待批", "\(n) proposal\(n == 1 ? "" : "s") pending")
    }

    // Short status chips
    package static var shortSleep: String { s("睡", "Zzz") }
    package static var shortDND: String { s("静", "DND") }
    package static var shortFocused: String { s("专", "Fcs") }
    package static var shortBusy: String { s("忙", "Bsy") }
    package static var shortBreather: String { s("歇", "Brk") }
    package static var shortAway: String { s("离", "Awy") }
    package static var shortActive: String { s("闲", "Idl") }
    package static var shortAgitated: String { s("躁", "Agt") }

    // MARK: - Chat input

    package static var chatPlaceholder: String { s("对咕咕说…", "Say something to Gugu…") }
    package static var chatThinking: String { s("咕咕在想...", "Gugu is thinking…") }
    package static var chatFailed: String { s("咕咕没听清。", "Gugu didn't catch that.") }
    /// 模型回了空(既没话也没动作)时的轻量占位,避免"反应丢失"。
    package static var chatNoReply: String { s("(咕咕歪头看了看你)", "(Gugu tilts its head at you)") }
    package static var chatDragTooltip: String { s("拖动输入框", "Drag input") }
    package static var chatCloseTooltip: String { s("关闭输入框", "Close input") }

    // Error messages with guidance
    package static var errorNoApiKey: String {
        s("(咕咕想说话,但还没接上脑子。右键我 → 设置,填上 API Key)",
          "(Gugu wants to talk, but the brain isn't connected yet. Right-click me → Settings, add your API Key)")
    }
    package static var errorAuthFailed: String {
        s("(咕咕脑子接不上了,密钥可能失效了。右键我 → 设置)",
          "(Can't connect — API key might be invalid. Right-click me → Settings)")
    }
    package static var errorNetwork: String {
        s("(咕咕的脑子在远方,网络卡住了,等会儿再试?)",
          "(My brain is far away — network hiccup. Try again in a moment?)")
    }

    // MARK: - Greetings

    package static var greetingNew: String { s("咕?(歪头看了看你)", "Gu? (tilts head curiously)") }
    package static var greetingNeedsSetup: String {
        s("咕!(我还没接上脑子。右键我 → 设置,填上 API Key 就能和你说话了)",
          "Gu! (My brain isn't connected yet. Right-click me → Settings, add an API Key so I can talk to you)")
    }
    package static var greetingBonded: String { s("你来啦!", "Hey, you're back!") }
    package static var greetingDefault: String { s("咕咕。", "Gu gu.") }

    // MARK: - Growth stages

    package static var stageHatchling: String { s("幼鸟", "Hatchling") }
    package static var stageFledgling: String { s("雏鸟", "Fledgling") }
    package static var stageAdult: String { s("成鸟", "Adult") }
    package static var stageSpirit: String { s("灵鸟", "Spirit") }

    package static var stageShortHatchling: String { s("幼", "H") }
    package static var stageShortFledgling: String { s("雏", "F") }
    package static var stageShortAdult: String { s("成", "A") }
    package static var stageShortSpirit: String { s("灵", "S") }

    // MARK: - Pet speech

    package static var woke: String { s("咕醒了。", "Gugu is awake.") }
    package static var pokeReaction: String { s("嗯?", "Hm?") }
    package static var voiceTest: String { s("咕!", "Gu!") }
    package static var stopListening: String { s("好,我先不听了。", "Okay, I'll stop listening.") }
    package static var cameraOpened: String { s("(咕咕睁开眼睛看了看你)", "(Gugu opens eyes and looks at you)") }
    package static var cameraClosed: String { s("(咕咕闭上了眼睛)", "(Gugu closes eyes)") }
    package static var cameraDenied: String { s("咕咕想睁眼,但系统没给摄像头权限。到「系统设置 → 隐私与安全 → 摄像头」里把咕咕勾上吧~",
                                        "I tried to open my eyes but macOS hasn't granted camera access. Enable Gugu in System Settings → Privacy & Security → Camera.") }
    package static var cameraNoDevice: String { s("(咕咕眨眨眼,没找到摄像头)", "(Gugu blinks — no camera found)") }
    package static var dreamEnter: String { s("(进入梦乡…)", "(Drifting off to dream…)") }
    package static var dreamFailed: String { s("梦没做成。", "Dream didn't work out.") }
    package static func dreamProposal(_ title: String) -> String {
        s("我梦见自己好像能长大了。\(title),等你批准。",
          "I dreamed I could grow. \(title) — waiting for your approval.")
    }
    package static var proposalFailed: String { s("这个提案没法批准。", "Can't approve this proposal.") }
    package static func proposalApproved(_ title: String) -> String {
        s("批准了。\(title)", "Approved. \(title)")
    }
    package static var budgetSleepy: String { s("(今天想了好多事,有点困了…)", "(Thought a lot today, getting sleepy…)") }
    package static var micUnavailable: String { s("麦克风现在用不了。", "Mic isn't available right now.") }
    package static var voiceFailed: String { s("我刚才没听明白,你再说一遍。", "I didn't catch that. Say it again?") }
    package static var voiceFailedNoKey: String {
        s("(咕咕还没接上脑子,先去菜单栏图标 → 设置里填 API Key)",
          "(Brain not connected yet — go to menu bar icon → Settings to add API Key)")
    }
    package static var voiceFailedAuth: String {
        s("(密钥好像失效了,去设置里看看?)", "(API key seems invalid — check Settings?)")
    }
    package static var grewUp: String { s("我好像长大了一点。", "I think I grew a little.") }
    package static var perchCooldown: String { s("(刚试过，等一下再站)", "(Just tried, give me a sec)") }
    package static var perchNoWindow: String { s("(没找到能站的窗口)", "(No window to perch on)") }

    // Abilities
    package static var abilitiesSpeech: String {
        s("我会聊天、跳舞、蹦一下、飞一下、理毛,也能看你回来、听唤醒词。",
          "I can chat, dance, hop, fly, groom — and notice when you come back or call my name.")
    }

    // MARK: - Discovery hints

    package static var hintPoke: String { s("(歪头)你可以戳戳我。", "(tilts head) You can poke me.") }
    package static var hintPet: String { s("摸摸我嘛,双击我。", "Pet me — double-click me.") }
    package static var hintLearn: String {
        s("你可以教我新动作,跟我说\"学个翻跟头\"。",
          "You can teach me new moves — say \"learn a backflip\".")
    }
    package static var hintChat: String {
        s("想说话就右键我,选\"和咕咕说话\"。",
          "To talk, right-click me and pick \"Talk to Gugu\".")
    }

    // MARK: - Milestones

    package static var milestoneInteract10: String {
        s("我们已经玩了好一会儿了,我开始喜欢你了。", "We've played for a while now — I'm starting to like you.")
    }
    package static var milestoneInteract50: String {
        s("和你在一起的每一下,我都记着呢。", "Every moment with you, I remember it.")
    }
    package static var milestoneBond30: String {
        s("(蹭了蹭你)我好像有点黏你了。", "(nuzzles you) I think I'm getting attached to you.")
    }
    package static var milestoneBond50: String { s("你是我最熟的人了。", "You're the one I know best now.") }
    package static var milestoneBond80: String { s("无论你忙不忙,我都在这儿。", "Busy or not, I'm right here.") }
    package static var milestoneDays3: String { s("我们认识三天啦。", "We've known each other three days now.") }
    package static var milestoneDays7: String {
        s("一整个星期了,谢谢你没把我关掉。", "A whole week — thank you for not closing me.")
    }
    package static var milestoneDays30: String {
        s("三十天了。我已经是你桌面的一部分了吧?", "Thirty days. I'm part of your desktop now, aren't I?")
    }
    package static var milestoneMove1: String { s("我学会第一个新动作了!", "I learned my first new move!") }
    package static var milestoneMove3: String {
        s("我会的动作越来越多了,要不要再教我一个?", "I know more and more moves — want to teach me another?")
    }

    // MARK: - Poke combo reactions

    package static var pokeAnnoyed: String { s("(扭头)别戳啦。", "(turns away) Stop poking.") }
    package static var pokeDizzy: String { s("呜…头晕了。", "Ugh… I'm dizzy.") }
    package static var pokeFlee: String { s("(躲开)不理你了!", "(dodges) I'm ignoring you now!") }

    // MARK: - Learn move

    package static var learnAlreadyKnow: String { s("这个我会呀,你看——", "I know this one — watch!") }
    package static func learnTrying(_ intent: String) -> String {
        s("我…试试看怎么\(intent)。", "Let me… try to figure out how to \(intent).")
    }
    package static var learnCantDo: String {
        s("这个我学不会,身子做不出来这个动作。", "I can't learn this — my body can't make that move.")
    }
    package static func learnGotDraft(_ name: String) -> String {
        s("我好像学会「\(name)」了!你批准我就会了。",
          "I think I learned \"\(name)\"! Approve it and I'll have it.")
    }
    package static var learnFailed: String { s("唔,我没学会,等下再教我?", "Hmm, I didn't get it. Teach me again later?") }
    package static var learnFailedNoKey: String {
        s("(还没接上脑子,没法学。右键我 → 设置)",
          "(Brain not connected — can't learn yet. Right-click me → Settings)")
    }

    // MARK: - Rhythm display names

    package static var rhythmFocused: String { s("专注工作", "Focused") }
    package static var rhythmBusy: String { s("忙碌操作", "Busy") }
    package static var rhythmBreather: String { s("歇口气", "Breather") }
    package static var rhythmAway: String { s("离开", "Away") }
    package static var rhythmActive: String { s("活跃", "Active") }
    package static var rhythmAgitated: String { s("可能烦躁", "Agitated") }

    // MARK: - Action labels (for chat log)

    package static func actionLabel(_ a: String) -> String {
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

    package static var auditTitle: String { s("# 咕咕今天看到了什么", "# What Gugu noticed today") }
    package static var auditProposals: String { s("## 待批准提案", "## Pending proposals") }
    package static var auditEvents: String { s("## 今日感知事件", "## Today's events") }
    package static var auditSection: String { s("## 今日审计", "## Today's audit") }
    package static var auditEmpty: String { s("(暂无)", "(none yet)") }
    package static var auditNone: String { s("无", "None") }
    package static var auditPending: String { s("暂无", "Nothing yet") }
    package static func auditGeneratedAt(_ time: String) -> String { s("生成时间:\(time)", "Generated at: \(time)") }
    package static var auditCurrentState: String { s("## 当前状态", "## Current state") }
    package static func auditStage(_ v: String) -> String { s("- 形态:\(v)", "- Stage: \(v)") }
    package static func auditPendingStage(_ v: String) -> String { s("- 待进化:\(v)", "- Pending growth: \(v)") }
    package static func auditDays(_ v: Int) -> String { s("- 相处天数:\(v)", "- Days together: \(v)") }
    package static func auditEventCount(_ v: Int) -> String { s("- 事件数:\(v)", "- Events seen: \(v)") }
    package static func auditInteractions(_ v: Int) -> String { s("- 互动数:\(v)", "- Interactions: \(v)") }
    package static func auditBond(_ v: String) -> String { s("- 羁绊:\(v)", "- Bond: \(v)") }
    package static func auditTrust(_ v: String) -> String { s("- 信任:\(v)", "- Trust: \(v)") }
    package static var auditUsage: String { s("## 用量", "## Usage") }

    // MARK: - Budget

    package static func budgetLine(total: Int, daily: Int, calls: Int) -> String {
        s("今日 \(total) / \(daily) tokens · \(calls) 次",
          "Today \(total) / \(daily) tokens · \(calls) calls")
    }

    // MARK: - Evolution

    package static func evolvedTo(_ name: String) -> String {
        s("主人批准咕咕长成了\(name)。", "Owner approved Gugu's growth to \(name).")
    }
    package static func evolutionProposalTitle(_ target: String) -> String {
        s("请求长成\(target)", "Request to grow into \(target)")
    }
    package static var proposalUnnamed: String { s("未命名提案", "Unnamed proposal") }
    package static var proposalStatusPending: String { s("状态:待主人批准", "Status: awaiting owner approval") }
    package static func proposalGeneratedAt(_ time: String) -> String {
        s("生成时间:\(time)", "Generated at: \(time)")
    }
    package static func proposalGrowthReason(_ old: String, _ new: String) -> String {
        s("咕咕觉得自己从\(old)长到\(new)的条件已经接近成熟。",
          "Gugu feels the conditions to grow from \(old) to \(new) are nearly ripe.")
    }
    package static var proposalMetricsHeader: String { s("当前指标:", "Current metrics:") }
    package static func proposalMetricDays(_ v: Int) -> String { s("- 相处天数:\(v)", "- Days together: \(v)") }
    package static func proposalMetricEvents(_ v: Int) -> String { s("- 见过事件:\(v)", "- Events seen: \(v)") }
    package static func proposalMetricInteractions(_ v: Int) -> String { s("- 互动次数:\(v)", "- Interactions: \(v)") }
    package static func proposalMetricBond(_ v: String) -> String { s("- 羁绊:\(v)", "- Bond: \(v)") }
    package static func proposalMetricTrust(_ v: String) -> String { s("- 信任:\(v)", "- Trust: \(v)") }
    package static func proposalMetricSkills(_ v: Int) -> String { s("- 技能数:\(v)", "- Skills: \(v)") }
    package static var proposalStageFooter: String {
        s("需要主人确认后才会生效。批准后只提升阶段;记忆、安全内核和现有边界保持不变。",
          "Takes effect only after owner approval. Approval raises the stage only — memory, safety core, and existing boundaries stay unchanged.")
    }

    // MARK: - Local tool executor

    package static var noteRecorded: String { s("已记录笔记", "Note saved") }
    package static var reminderRecorded: String { s("已记录提醒事项", "Reminder saved") }
    package static func reminderRecordedWithDue(_ due: String) -> String {
        s("已记录提醒事项(\(due))", "Reminder saved (\(due))")
    }
    package static func reminderScheduled(_ time: String) -> String {
        s("已记录提醒事项,会在 \(time) 提醒你", "Reminder saved — will notify at \(time)")
    }
    package static var notesNotAuthorized: String {
        s("notes.add 未授权:请先在配置中开启 tools.notes",
          "notes.add not authorized: enable tools.notes in config first")
    }
    package static var remindersNotAuthorized: String {
        s("reminders.add 未授权:请先在配置中开启 tools.reminders",
          "reminders.add not authorized: enable tools.reminders in config first")
    }
    package static var webSearchNotAuthorized: String {
        s("web_search 未授权:请先在配置中开启 tools.web_search",
          "web_search not authorized: enable tools.web_search in config first")
    }
    /// 联网搜索目前只记录请求、尚未真正出网(框架就绪,出网待接入)。
    package static var webSearchRecorded: String {
        s("我把要查的记下了,等我能上网了就去查。",
          "Noted what to look up — I'll search once I can go online.")
    }
    package static var reminderNotificationTitle: String { s("咕咕提醒事项", "Gugu Reminder") }
    /// Date format for the scheduled-reminder confirmation.
    package static var reminderDateFormat: String { s("M月d日 HH:mm", "MMM d, HH:mm") }

    // MARK: - Deferred / autonomy

    package static func deferredTask(_ title: String) -> String {
        s("放到夜里做了。\(title)", "Deferred to tonight. \(title)")
    }
    package static var autonomyEnqueueFailed: String {
        s("这个夜里任务没放进去。", "Couldn't queue that night task.")
    }
    package static var cannotDoYet: String {
        s("这个我还不能做。我把申请放到提案里了。",
          "I can't do that yet. I've filed it as a proposal.")
    }

    // MARK: - Event summaries

    package static var eventWake: String { s("咕咕来到了主人的桌面", "Gugu arrived on owner's desktop") }
    package static var eventPoke: String { s("主人戳了你一下", "Owner poked you") }
    package static var eventPetted: String { s("主人摸了摸你", "Owner petted you") }
    package static var eventThrown: String { s("主人把你扔了出去,摔了个跟头", "Owner tossed you — tumbled!") }
    package static func eventChat(_ text: String) -> String {
        s("主人和你聊天:\(text)", "Owner chatted: \(text)")
    }
    package static func eventVoice(_ text: String) -> String {
        s("主人对你说:\(text)", "Owner said: \(text)")
    }
    package static var eventSeeReturn: String { s("你看见主人回到座位上了", "Saw owner return to seat") }
    package static var eventSeeLeave: String { s("你看见主人离开了座位", "Saw owner leave seat") }
    package static var eventSeeSmile: String { s("你看见主人在笑", "Saw owner smile") }
    package static func eventLateNight(_ hour: Int) -> String {
        s("主人深夜(\(hour)点)还在高强度工作", "Owner still working intensely at \(hour):00")
    }
    package static func eventAppSwitch(_ name: String, _ dwell: String) -> String {
        s("主人切到了 \(name)\(dwell)", "Owner switched to \(name)\(dwell)")
    }
    package static func eventProposalApproved(_ title: String) -> String {
        s("主人批准提案:\(title)", "Owner approved proposal: \(title)")
    }

    // MARK: - Language switch

    package static var langSwitched: String { s("好,说中文。", "Okay, English now.") }

    /// Directive appended to every LLM system prompt so the bird speaks the
    /// owner's chosen language. Persona stays Chinese; this overrides output.
    package static var llmLanguageDirective: String {
        s("请始终用简体中文回答,包括 speech、aside、记忆等所有自然语言字段。",
          "Always respond in English for all natural-language fields (speech, aside, memory notes, morning words, etc.), even though the instructions above are in Chinese. Stay in character as a small bird: very short utterances.")
    }

    // MARK: - LLM prompt fragments (growth-stage speech guidance)

    package static var speechGuidanceHatchling: String {
        s("你现在还是幼鸟:多用很短的词、拟声和动作回应;复杂事情可以听懂,但说出来要笨拙一点。",
          "You're still a hatchling: reply mostly with very short words, onomatopoeia, and actions; you understand complex things but speak them clumsily.")
    }
    package static var speechGuidanceFledgling: String {
        s("你现在是雏鸟:能说短句,会表达观察,但仍然保持小鸟式的直接和有限记忆。",
          "You're now a fledgling: you can speak short sentences and voice observations, but stay bird-like — direct, with limited memory.")
    }
    package static var speechGuidanceAdult: String {
        s("你现在是成鸟:能正常短句对话,有稳定性格,会主动关心但不过度打扰。",
          "You're now an adult: you converse in normal short sentences, have a stable personality, and show care without being intrusive.")
    }
    package static var speechGuidanceSpirit: String {
        s("你现在是灵鸟:可以偶尔有自己的观点和玩笑,但仍必须诚实、短句、基于真实观察。",
          "You're now a spirit bird: you may occasionally voice your own opinions and jokes, but must stay honest, brief, and grounded in real observation.")
    }

    // MARK: - LLM prompt fragments (learn-move designer)

    /// System prompt for the move-designer call (Brain.learnMove).
    package static var learnMoveSystemPrompt: String {
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
    package static func learnMoveUserMessage(_ intent: String) -> String {
        s("主人想教咕咕的动作是:「\(intent)」。请设计这个动作的分解步骤。",
          "The move the owner wants to teach Gugu is: \"\(intent)\". Design the step-by-step breakdown of this move.")
    }

    // MARK: - Scheduler / config

    package static var configReloaded: String { s("配置已重新加载", "Config reloaded") }

    // MARK: - Structured-output hint (OpenAI-compatible providers)

    package static var schemaHintHeader: String {
        s("只输出一个 JSON 对象,包含且仅包含以下字段:",
          "Output only a single JSON object with exactly these fields:")
    }
    package static var schemaHintRequired: String { s("(必填)", " (required)") }
    package static var schemaHintGeneric: String {
        s("只输出一个合法的 JSON 对象,不要包含其它文字。",
          "Output only a valid JSON object, with no other text.")
    }

    // MARK: - Settings window

    package static var menuSettings: String { s("设置…", "Settings…") }
    package static var settingsTitle: String { s("咕咕设置", "Gugu Settings") }
    package static var settingsURL: String { s("接口地址", "API URL") }
    package static var settingsKey: String { s("密钥", "API Key") }
    package static var settingsModel: String { s("模型", "Model") }
    package static var settingsAdvanced: String { s("高级", "Advanced") }
    package static var settingsBudget: String { s("预算", "Budget") }
    package static var settingsDailyTokens: String { s("每日 tokens", "Daily tokens") }
    package static var settingsSave: String { s("保存", "Save") }
    package static var settingsCancel: String { s("取消", "Cancel") }
    package static var settingsSaveFailed: String { s("保存失败", "Save failed") }

    // MARK: - Listener wake words (used for matching, not display)

    package static var wakeWordsZH: [String] { ["咕咕", "股股", "古古", "咕鸟", "小咕"] }
    package static var wakeWordsEN: [String] { ["gugu", "hey gugu", "hi gugu", "hey goo goo", "goo goo"] }
    package static var wakeWords: [String] { current == .zh ? wakeWordsZH : (wakeWordsZH + wakeWordsEN) }
}
