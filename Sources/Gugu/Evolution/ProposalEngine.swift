import Foundation

/// Applies owner-approved self-modification proposals. Supported proposal files
/// are deliberately narrow and declarative:
///
/// # 标题
/// kind: persona_append | config_set | tool_permission
/// target: persona.md | config.yaml
/// key: section.key          (config_set/tool_permission only)
/// value: new value          (config_set/tool_permission only)
///
/// Body after a line containing "---" is appended for persona_append.
@MainActor
final class ProposalEngine {
    enum ProposalError: Error, CustomStringConvertible {
        case missingFile
        case unsupportedKind(String)
        case invalidTarget(String)
        case missingField(String)
        case coreMutationRejected
        case writeFailed(String)

        var description: String {
            switch self {
            case .missingFile: return "proposal file is missing"
            case .unsupportedKind(let k): return "unsupported proposal kind: \(k)"
            case .invalidTarget(let t): return "invalid proposal target: \(t)"
            case .missingField(let f): return "missing proposal field: \(f)"
            case .coreMutationRejected: return "proposal tried to modify persona core"
            case .writeFailed(let p): return "failed to write \(p)"
            }
        }
    }

    struct Applied {
        let title: String
        let target: URL
        let snapshot: URL
        let newStage: GrowthStage?
    }

    func applyApprovedProposal(at url: URL) throws -> Applied {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProposalError.missingFile
        }
        let proposal = ParsedProposal(text: text)
        let kind = proposal.meta["kind"] ?? "stage"
        switch kind {
        case "stage":
            guard PetState.load().pending_stage != nil else {
                throw ProposalError.missingField("pending_stage")
            }
            let snapshot = try snapshotFile(Paths.state)
            guard Evolution(memory: Memory()).approvePendingStage() else {
                throw ProposalError.missingField("pending_stage")
            }
            archiveAppliedProposal(url)
            Audit.record(kind: "proposal.apply", summary: "批准进化提案:\(proposal.title)",
                         detail: ["proposal": url.lastPathComponent, "target": "state.json", "snapshot": snapshot.lastPathComponent])
            return Applied(title: proposal.title, target: Paths.state, snapshot: snapshot, newStage: GrowthStage(rawStage: PetState.load().stage))
        case "persona_append":
            return try applyPersonaAppend(proposal, url: url)
        case "config_set":
            return try applyConfigSet(proposal, url: url)
        case "tool_permission":
            return try applyToolPermission(proposal, url: url)
        case "move_add":
            return try applyMoveAdd(proposal, url: url)
        default:
            throw ProposalError.unsupportedKind(kind)
        }
    }

    func writePersonaProposal(title: String, body: String) -> URL {
        let url = proposalURL(prefix: "persona")
        let text = """
        # \(title)
        kind: persona_append
        target: persona.md

        ---
        \(body)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Audit.record(kind: "proposal.create", summary: "生成人格追加提案:\(title)",
                     detail: ["proposal": url.lastPathComponent])
        return url
    }

    func writeConfigProposal(title: String, key: String, value: String) -> URL {
        let url = proposalURL(prefix: "config")
        let text = """
        # \(title)
        kind: config_set
        target: config.yaml
        key: \(key)
        value: \(value)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Audit.record(kind: "proposal.create", summary: "生成配置修改提案:\(title)",
                     detail: ["proposal": url.lastPathComponent, "key": key])
        return url
    }

    /// 生成一个"学会新动作"的提案。move 的编排以 JSON 形式放在正文(--- 之后),
    /// 主人批准后写入 moves/。提案前先做一次校验,非法编排根本不生成提案。
    func writeMoveProposal(_ move: Move) throws -> URL {
        let validatedSteps = try MetaActionValidator.validate(steps: move.steps)
        let name = try MetaActionValidator.sanitizedName(move.name)
        let finalized = Move(name: name, trigger: move.trigger, steps: validatedSteps,
                             origin: "learned", createdAt: move.createdAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(finalized), encoding: .utf8) ?? "{}"
        let url = proposalURL(prefix: "move")
        let text = """
        # 想学会新动作:\(name)
        kind: move_add
        target: moves/\(name).json

        ---
        \(json)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Audit.record(kind: "proposal.create", summary: "生成学习动作提案:\(name)",
                     detail: ["proposal": url.lastPathComponent, "move": name])
        return url
    }

    func writeToolPermissionProposal(title: String, key: String, value: Bool = true) -> URL {        let url = proposalURL(prefix: "tool")
        let text = """
        # \(title)
        kind: tool_permission
        target: config.yaml
        key: \(key)
        value: \(value ? "true" : "false")
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Audit.record(kind: "proposal.create", summary: "生成工具权限提案:\(title)",
                     detail: ["proposal": url.lastPathComponent, "key": key])
        return url
    }

    private func applyPersonaAppend(_ proposal: ParsedProposal, url: URL) throws -> Applied {
        let target = proposal.meta["target"] ?? "persona.md"
        guard target == "persona.md" else { throw ProposalError.invalidTarget(target) }
        let append = proposal.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !append.isEmpty else { throw ProposalError.missingField("body") }
        guard !append.contains("<!-- core") && !append.contains("<!-- /core -->") else {
            throw ProposalError.coreMutationRejected
        }

        let snapshot = try snapshotFile(Paths.persona)
        var persona = (try? String(contentsOf: Paths.persona, encoding: .utf8)) ?? DefaultFiles.persona
        persona += "\n\n## 主人批准的新经验\n\(append)\n"
        try write(persona, to: Paths.persona)
        archiveAppliedProposal(url)
        Audit.record(kind: "proposal.apply", summary: "追加人格提案:\(proposal.title)",
                     detail: ["proposal": url.lastPathComponent, "target": "persona.md", "snapshot": snapshot.lastPathComponent])
        return Applied(title: proposal.title, target: Paths.persona, snapshot: snapshot, newStage: nil)
    }

    private func applyConfigSet(_ proposal: ParsedProposal, url: URL) throws -> Applied {
        let target = proposal.meta["target"] ?? "config.yaml"
        guard target == "config.yaml" else { throw ProposalError.invalidTarget(target) }
        guard let key = proposal.meta["key"], !key.isEmpty else { throw ProposalError.missingField("key") }
        guard let value = proposal.meta["value"] else { throw ProposalError.missingField("value") }
        guard allowedConfigKeys.contains(key) else { throw ProposalError.invalidTarget(key) }
        try validateConfigValue(key: key, value: value)

        let snapshot = try snapshotFile(Paths.config)
        let current = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        let updated = setYAMLValue(text: current, dottedKey: key, value: value)
        try write(updated, to: Paths.config)
        archiveAppliedProposal(url)
        Audit.record(kind: "proposal.apply", summary: "应用配置提案:\(proposal.title)",
                     detail: ["proposal": url.lastPathComponent, "key": key, "snapshot": snapshot.lastPathComponent])
        return Applied(title: proposal.title, target: Paths.config, snapshot: snapshot, newStage: nil)
    }

    private func applyToolPermission(_ proposal: ParsedProposal, url: URL) throws -> Applied {
        guard let key = proposal.meta["key"], key.hasPrefix("tools.") else {
            throw ProposalError.missingField("key")
        }
        guard allowedToolKeys.contains(key) else { throw ProposalError.invalidTarget(key) }
        guard let value = proposal.meta["value"] else { throw ProposalError.missingField("value") }
        guard value == "true" || value == "false" else { throw ProposalError.invalidTarget("\(key)=\(value)") }
        let snapshot = try snapshotFile(Paths.config)
        let current = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        let updated = setYAMLValue(text: current, dottedKey: key, value: value)
        try write(updated, to: Paths.config)
        archiveAppliedProposal(url)
        Audit.record(kind: "proposal.apply", summary: "应用工具权限提案:\(proposal.title)",
                     detail: ["proposal": url.lastPathComponent, "key": key, "snapshot": snapshot.lastPathComponent])
        return Applied(title: proposal.title, target: Paths.config, snapshot: snapshot, newStage: nil)
    }

    /// 批准学习动作:解析正文 JSON → 再次校验/夹紧 → 落盘到 moves/。
    /// 这一步是动作进化真正"长出来"的瞬间,且仍然只能产出受白名单约束的编排。
    @MainActor
    private func applyMoveAdd(_ proposal: ParsedProposal, url: URL) throws -> Applied {
        let body = proposal.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let data = body.data(using: .utf8) else {
            throw ProposalError.missingField("move json")
        }
        guard let move = try? JSONDecoder().decode(Move.self, from: data) else {
            throw ProposalError.invalidTarget("move json 解析失败")
        }
        // MoveLibrary.save 内部会再次校验 + 夹紧 + 消毒名字(纵深防御)。
        let saved: Move
        do {
            saved = try MoveLibrary.shared.save(move)
        } catch {
            throw ProposalError.invalidTarget("动作校验失败: \(error)")
        }
        let target = Paths.movesDir.appendingPathComponent("\(saved.name).json")
        archiveAppliedProposal(url)
        Audit.record(kind: "proposal.apply", summary: "学会新动作:\(saved.name)",
                     detail: ["proposal": url.lastPathComponent, "move": saved.name, "steps": "\(saved.steps.count)"])
        return Applied(title: "学会了「\(saved.name)」", target: target, snapshot: target, newStage: nil)
    }

    private let allowedConfigKeys: Set<String> = [        "budget.daily_tokens",
        "heartbeat.min_interval",
        "heartbeat.max_interval",
        "heartbeat.freeze_when_focused",
        "senses.screen",
        "senses.input_rhythm",
        "pet.name",
    ]

    private let allowedToolKeys: Set<String> = [
        "tools.notes",
        "tools.reminders",
        "tools.local_notifications",
    ]

    private func validateConfigValue(key: String, value: String) throws {
        switch key {
        case "budget.daily_tokens":
            guard let n = Int(value), (1_000...5_000_000).contains(n) else {
                throw ProposalError.invalidTarget("\(key)=\(value)")
            }
        case "heartbeat.min_interval":
            guard let n = Double(value), (30...86_400).contains(n) else {
                throw ProposalError.invalidTarget("\(key)=\(value)")
            }
        case "heartbeat.max_interval":
            guard let n = Double(value), (60...172_800).contains(n) else {
                throw ProposalError.invalidTarget("\(key)=\(value)")
            }
        case "heartbeat.freeze_when_focused", "senses.screen", "senses.input_rhythm":
            guard value == "true" || value == "false" else {
                throw ProposalError.invalidTarget("\(key)=\(value)")
            }
        case "pet.name":
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 24 else {
                throw ProposalError.invalidTarget("\(key)=\(value)")
            }
        default:
            throw ProposalError.invalidTarget(key)
        }
    }

    private func setYAMLValue(text: String, dottedKey: String, value: String) -> String {
        let parts = dottedKey.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return text }
        let section = parts[0]
        let key = parts[1]
        var lines = text.components(separatedBy: .newlines)
        var sectionIndex: Int?
        var insertIndex = lines.count

        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "\(section):" {
                sectionIndex = i
                insertIndex = i + 1
                continue
            }
            if let s = sectionIndex, i > s {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasSuffix(":") {
                    insertIndex = i
                    break
                }
                if trimmed.hasPrefix("\(key):") {
                    lines[i] = "  \(key): \(value)"
                    return lines.joined(separator: "\n")
                }
                insertIndex = i + 1
            }
        }

        if sectionIndex == nil {
            lines.append("")
            lines.append("\(section):")
            lines.append("  \(key): \(value)")
        } else {
            lines.insert("  \(key): \(value)", at: insertIndex)
        }
        return lines.joined(separator: "\n")
    }

    private func snapshotFile(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.snapshots, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(url.lastPathComponent).\(df.string(from: Date()))-\(UUID().uuidString.prefix(8)).bak"
        let dest = Paths.snapshots.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: dest)
        } else {
            try "".write(to: dest, atomically: true, encoding: .utf8)
        }
        return dest
    }

    private func write(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ProposalError.writeFailed(url.lastPathComponent)
        }
    }

    private func archiveAppliedProposal(_ url: URL) {
        let appliedDir = Paths.proposals.appendingPathComponent("applied", isDirectory: true)
        try? FileManager.default.createDirectory(at: appliedDir, withIntermediateDirectories: true)
        let dest = appliedDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    private func proposalURL(prefix: String) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return Paths.proposals.appendingPathComponent("\(prefix)-\(df.string(from: Date())).md")
    }
}

private struct ParsedProposal {
    let title: String
    let meta: [String: String]
    let body: String

    init(text: String) {
        var title = L.proposalUnnamed
        var meta: [String: String] = [:]
        var bodyLines: [String] = []
        var inBody = false

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                inBody = true
                continue
            }
            if inBody {
                bodyLines.append(line)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { meta[key] = value }
            }
        }

        self.title = title
        self.meta = meta
        self.body = bodyLines.joined(separator: "\n")
    }
}
