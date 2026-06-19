import Foundation
import GuguKernel

/// 一个"学会的动作":名字 + 触发词 + 一段元动作编排。
///
/// 它就是咕咕进化出来的身体技能,落盘为 `moves/<name>.json`,纯文本、主人可读可改、可审计。
/// 进化 = 这个目录里多出一个文件(公理 A1);执行全本地零成本(公理 A2)。
struct Move: Codable, Equatable {
    var name: String
    var trigger: String        // 主人说什么时触发(本地关键词匹配),可空
    var steps: [MoveStep]
    var origin: String         // "builtin" / "learned" —— 出厂内置 还是 学会的
    var createdAt: String?

    init(name: String, trigger: String = "", steps: [MoveStep], origin: String = "learned", createdAt: String? = nil) {
        self.name = name
        self.trigger = trigger
        self.steps = steps
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// 加载 / 保存 / 查找 moves/ 下的动作。出厂自带几个内置组合动作作为"元动作之上长出来的示范"。
@MainActor
final class MoveLibrary {
    static let shared = MoveLibrary()

    private(set) var moves: [Move] = []

    init() {
        reload()
    }

    /// 从磁盘重新加载;首次发现目录里没有内置动作时,写入出厂内置动作。
    func reload() {
        seedBuiltinsIfNeeded()
        var loaded: [Move] = []
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Paths.movesDir, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let move = try? JSONDecoder().decode(Move.self, from: data) {
                    loaded.append(move)
                }
            }
        }
        moves = loaded.sorted { $0.name < $1.name }
    }

    /// 按动作名精确查。
    func move(named name: String) -> Move? {
        moves.first { $0.name == name }
    }

    /// 主人说的话里是否命中某个动作的触发词(本地、零成本、不烧 token)。
    /// 越长的触发词优先,避免短词误命中。
    func matchTrigger(in text: String) -> Move? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return moves
            .filter { !$0.trigger.isEmpty && t.contains($0.trigger) }
            .max { $0.trigger.count < $1.trigger.count }
    }

    /// 已学会(非内置)的动作。
    var learnedMoves: [Move] { moves.filter { $0.origin != "builtin" } }

    /// 写入一个动作(经校验后)。会 clamp 步骤、消毒名字,返回最终落盘的 Move。
    @discardableResult
    func save(_ move: Move) throws -> Move {
        let name = try MetaActionValidator.sanitizedName(move.name)
        let steps = try MetaActionValidator.validate(steps: move.steps)
        let finalized = Move(name: name, trigger: String(move.trigger.prefix(MoveLimits.maxTriggerChars)),
                             steps: steps, origin: move.origin, createdAt: move.createdAt)
        let url = Paths.movesDir.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(finalized)
        try data.write(to: url, options: .atomic)
        reload()
        return finalized
    }

    private func seedBuiltinsIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.movesDir, withIntermediateDirectories: true)
        for move in MoveLibrary.builtins {
            let url = Paths.movesDir.appendingPathComponent("\(move.name).json")
            guard !fm.fileExists(atPath: url.path) else { continue }
            if let data = try? prettyEncode(move) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func prettyEncode(_ move: Move) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(move)
    }

    // MARK: - 出厂内置组合动作(在元动作之上长出来的示范)

    static let builtins: [Move] = [
        // 翻跟头:起跳 → 空中转一整圈 → 落地挤压
        Move(name: "翻跟头", trigger: "翻跟头", steps: [
            MoveStep(op: "flap", times: 6, fast: true),
            MoveStep(op: "move", dy: 50, dur: 0.25),
            MoveStep(op: "rotate", by: -6.283, dur: 0.5),
            MoveStep(op: "move", dy: -50, dur: 0.25),
            MoveStep(op: "scale", y: 0.7, dur: 0.12),
            MoveStep(op: "scale", y: 1.0, dur: 0.2),
            MoveStep(op: "say", text: "咕!"),
        ], origin: "builtin"),

        // 转圈圈:原地小幅左右摆 + 扑翅,像高兴地打转
        Move(name: "转圈圈", trigger: "转个圈", steps: [
            MoveStep(op: "flap", times: 4, fast: true),
            MoveStep(op: "rotate", by: 0.4, dur: 0.18),
            MoveStep(op: "rotate", by: -0.8, dur: 0.2),
            MoveStep(op: "rotate", by: 0.4, dur: 0.18),
            MoveStep(op: "hop", dur: 0.16, height: 16),
        ], origin: "builtin"),

        // 鞠躬:歪头 → 身子下沉 → 抬起,像在道谢
        Move(name: "鞠躬", trigger: "鞠个躬", steps: [
            MoveStep(op: "view", dir: "front"),
            MoveStep(op: "move", dy: -8, dur: 0.25),
            MoveStep(op: "scale", y: 0.85, dur: 0.2),
            MoveStep(op: "wait", dur: 0.3),
            MoveStep(op: "scale", y: 1.0, dur: 0.25),
            MoveStep(op: "move", dy: 8, dur: 0.2),
            MoveStep(op: "say", text: "咕咕。"),
        ], origin: "builtin"),
    ]
}
