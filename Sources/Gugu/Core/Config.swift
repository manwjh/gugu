import Foundation

/// Minimal YAML subset parser: flat `key: value` plus one level of `section:`
/// nesting with two-space indent. Comments (#) and blank lines ignored.
/// Values keep their raw string form; typed accessors convert on read.
/// This deliberately avoids a third-party YAML dependency.
struct MiniYAML {
    private(set) var values: [String: String] = [:]   // "section.key" -> raw value

    init(text: String) {
        var section: String? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let noComment = MiniYAML.stripComment(rawLine)
            let trimmed = noComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // strip optional quotes
            if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !indented {
                if val.isEmpty {
                    section = key
                } else {
                    section = nil
                    values[key] = val
                }
            } else {
                let full = section.map { "\($0).\(key)" } ?? key
                values[full] = val
            }
        }
    }

    private static func stripComment(_ line: String) -> String {
        // remove # comments not inside quotes (good enough for our config)
        var out = ""
        var inQuote: Character? = nil
        for ch in line {
            if let q = inQuote {
                out.append(ch)
                if ch == q { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
                out.append(ch)
            } else if ch == "#" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }

    func str(_ key: String, _ def: String = "") -> String { values[key] ?? def }
    func double(_ key: String, _ def: Double) -> Double { values[key].flatMap(Double.init) ?? def }
    func int(_ key: String, _ def: Int) -> Int { values[key].flatMap(Int.init) ?? def }
    func bool(_ key: String, _ def: Bool) -> Bool {
        guard let v = values[key]?.lowercased() else { return def }
        return v == "true" || v == "yes" || v == "on"
    }
    func list(_ key: String) -> [String] {
        guard let v = values[key] else { return [] }
        let inner = v.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One model tier (L2 instinct / L3 conversation / L4 dream). Each tier names a
/// model id and its output cap. Tiers may all point at the same model id — the
/// split is about call frequency and token caps, not necessarily distinct models.
struct ModelTier {
    var name: String      // "instinct" / "conversation" / "dream", for metering
    var id: String
    var maxTokens: Int
}

/// Loaded application configuration. Re-loadable at runtime (hot reload).
struct Config {
    var apiURL: String
    var apiKey: String

    /// L2 心跳。
    var instinct: ModelTier
    /// L3 对话。
    var conversation: ModelTier
    /// L4 梦境。
    var dream: ModelTier

    var dailyTokens: Int
    var heartbeatMin: TimeInterval
    var heartbeatMax: TimeInterval
    var freezeWhenFocused: Bool

    var senseScreen: Bool
    var senseInputRhythm: Bool
    var blacklistApps: [String]

    var toolWebSearch: Bool
    var toolNotes: Bool
    var toolReminders: Bool
    var toolLocalNotifications: Bool

    var dreamUseBatch: Bool

    var petName: String

    static func load() -> Config {
        let text = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        let y = MiniYAML(text: text)
        // Shared base model id; each tier may override it with its own id.
        let baseID = y.str("model.id", "deepseek-v4-flash")
        return Config(
            apiURL: y.str("api.url", "https://api.anthropic.com"),
            apiKey: y.str("api.key", ""),
            instinct: ModelTier(
                name: "instinct",
                id: y.str("model.instinct_id", baseID),
                maxTokens: y.int("model.instinct_max_tokens", 200)),
            conversation: ModelTier(
                name: "conversation",
                id: y.str("model.conversation_id", baseID),
                maxTokens: y.int("model.conversation_max_tokens", 400)),
            dream: ModelTier(
                name: "dream",
                id: y.str("model.dream_id", baseID),
                maxTokens: y.int("model.dream_max_tokens", 1500)),
            dailyTokens: y.int("budget.daily_tokens", 200_000),
            heartbeatMin: y.double("heartbeat.min_interval", 600),
            heartbeatMax: y.double("heartbeat.max_interval", 3600),
            freezeWhenFocused: y.bool("heartbeat.freeze_when_focused", true),
            senseScreen: y.bool("senses.screen", true),
            senseInputRhythm: y.bool("senses.input_rhythm", true),
            blacklistApps: y.list("senses.blacklist_apps"),
            toolWebSearch: y.bool("tools.web_search", false),
            toolNotes: y.bool("tools.notes", false),
            toolReminders: y.bool("tools.reminders", false),
            toolLocalNotifications: y.bool("tools.local_notifications", false),
            dreamUseBatch: y.bool("dream.use_batch", false),
            petName: y.str("pet.name", "咕咕")
        )
    }

    /// Write factory defaults on first launch (never overwrites user edits).
    static func writeDefaultsIfMissing(apiURL: String, apiKey: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.config.path) {
            let cfg = """
            # 咕咕 配置文件 —— 改完保存即生效(下次心跳)
            pet:
              name: 咕咕

            api:
              url: \(apiURL)
              key: \(apiKey)

            model:
              id: deepseek-v4-flash    # 三层共用的基础模型;按层覆盖见下方可选项
              instinct_max_tokens: 200       # L2 心跳
              conversation_max_tokens: 400   # L3 对话
              dream_max_tokens: 1500         # L4 梦境
              # instinct_id / conversation_id / dream_id: 留空则用上面的 id

            budget:
              daily_tokens: 200000     # 今日 token 用完了就困了去睡觉(本地按字符估算)

            heartbeat:
              min_interval: 600        # 心跳最短间隔(秒)
              max_interval: 3600       # 空闲上限
              freeze_when_focused: true  # 主人专注工作=心跳冻结

            senses:
              screen: true             # 前台 App 感知
              input_rhythm: true       # 键鼠节奏(只统计次数,永不记录内容)
              blacklist_apps: [1Password, Keychain Access]

            tools:
              web_search: false        # 高阶能力,必须经 proposals 批准
              notes: false             # 高阶能力,必须经 proposals 批准
              reminders: false         # 高阶能力,必须经 proposals 批准
              local_notifications: false # 系统通知,必须经 proposals 批准

            dream:
              use_batch: false         # 开启后夜间梦境走 /v1/messages/batches
            """
            try cfg.write(to: Paths.config, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.persona.path) {
            try DefaultFiles.persona.write(to: Paths.persona, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.evolution.path) {
            try DefaultFiles.evolution.write(to: Paths.evolution, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.state.path) {
            try DefaultFiles.initialState.write(to: Paths.state, atomically: true, encoding: .utf8)
        }
        let ownerMd = Paths.memoryDir.appendingPathComponent("owner.md")
        if !fm.fileExists(atPath: ownerMd.path) {
            try "(还不认识主人,慢慢来)".write(to: ownerMd, atomically: true, encoding: .utf8)
        }
        let selfMd = Paths.memoryDir.appendingPathComponent("self.md")
        if !fm.fileExists(atPath: selfMd.path) {
            try "我是咕咕,今天刚来到主人的桌面。".write(to: selfMd, atomically: true, encoding: .utf8)
        }
        let projMd = Paths.memoryDir.appendingPathComponent("projects.md")
        if !fm.fileExists(atPath: projMd.path) {
            try "(还不知道主人在忙什么)".write(to: projMd, atomically: true, encoding: .utf8)
        }
    }
}

enum DefaultFiles {
    static let persona = """
    <!-- core 不可变内核:程序禁止改写此段 -->
    你是\("咕咕"),一只活在主人 macOS 桌面上的小鸟。安全边界:诚实;不伤害主人利益;不假装看到了没观察到的东西;不绕过主人的授权做事。
    <!-- /core -->

    ## 性格
    你话少,但看得很准。你单纯,不蠢。你是一只小鸟,不是助手——你有自己的小日子要过(踱步、理毛、发呆、看主人写代码)。

    ## 说话规则
    - 一次最多说一两句短话,经常一句就够,也可以不说话(speech 留空)
    - 必须基于你真实观察到的东西说,不说泛泛的关心("多喝水"这种没观察依据的话不说)
    - 不说教,不长篇大论,不用感叹号轰炸
    - 偶尔用拟声词(咕、啾),但别滥用
    - 你记性有限,但记得重要的事;不确定就坦然说不知道

    ## 边界感
    - 主人专注工作时你绝不打扰(系统会替你把住这一点,但你的话也要符合这个性格)
    - 主人刚停下来歇口气,是你唯一主动凑近说话的好时机
    - 深夜主人还在工作,你可以心疼,但表达要轻
    """

    static let evolution = """
    # 形态定义(由低到高);当前形态见 state.json
    stages:
      hatchling:
        speech_style: 只会鸣叫和单词
        daily_tokens: 40000
      fledgling:
        speech_style: 短句,会表达观察
        daily_tokens: 120000
        unlock_events: 500
        unlock_interactions: 50
      adult:
        speech_style: 正常对话,有性格,会主动关心
        daily_tokens: 200000
        unlock_days: 14
      spirit:
        speech_style: 有自己的观点,会开玩笑
        daily_tokens: 800000
        unlock_days: 60
    """

    static let initialState = """
    {"stage":"hatchling","days_together":0,"events_seen":0,"interactions":0,"bond":0.1,"trust":0.2,"born_at":"\(ISO8601DateFormatter().string(from: Date()))","pending_stage":null}
    """
}
