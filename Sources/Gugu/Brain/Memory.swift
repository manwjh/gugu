import Foundation

/// Long-term memory: small markdown files the dream job rewrites nightly.
/// Deliberately small & fuzzy — both for token economy and the pet's persona.
@MainActor
final class Memory {
    enum MemoryError: Error, CustomStringConvertible {
        case unsupportedMemoryFile(String)
        case emptySkillName
        case writeFailed(String, Error)
        case appendFailed(String, Error)
        case removeFailed(String, Error)
        case snapshotFailed(String, Error)
        case invalidPinnedFact(String)

        var description: String {
            switch self {
            case .unsupportedMemoryFile(let file): return "unsupported memory file: \(file)"
            case .emptySkillName: return "empty skill name"
            case .writeFailed(let file, let error): return "failed to write \(file): \(error.localizedDescription)"
            case .appendFailed(let file, let error): return "failed to append \(file): \(error.localizedDescription)"
            case .removeFailed(let file, let error): return "failed to remove \(file): \(error.localizedDescription)"
            case .snapshotFailed(let file, let error): return "failed to snapshot \(file): \(error.localizedDescription)"
            case .invalidPinnedFact(let fact): return "invalid pinned fact: \(fact)"
            }
        }
    }

    static let longTermFiles = ["owner.md", "projects.md", "self.md"]

    /// Combined memory digest for prompts, capped in length.
    func digest(maxChars: Int = 500) -> String {
        var parts: [String] = []
        let pinned = pinnedDigest()
        if !pinned.isEmpty { parts.append(pinned) }
        for (name, file) in [("主人", "owner.md"), ("近况", "projects.md"), ("我", "self.md")] {
            let url = Paths.memoryDir.appendingPathComponent(file)
            if let t = try? String(contentsOf: url, encoding: .utf8),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("\(name):\(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let milestones = recentBondMilestones()
        if !milestones.isEmpty { parts.append("你们一起经历的事:\(milestones)") }
        let joined = parts.joined(separator: "\n")
        return String(joined.prefix(maxChars))
    }

    /// The most recent append-only milestones from bond.md (newest last in file),
    /// so the pet remembers shared history (e.g. evolutions) without bloating the
    /// prompt with the full ever-growing log.
    func recentBondMilestones(limit: Int = 3) -> String {
        let url = Paths.memoryDir.appendingPathComponent("bond.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*\t")) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return lines.suffix(limit).joined(separator: ";")
    }

    func pinnedDigest() -> String {
        let pinned = PinnedMemory.load()
        var facts: [String] = []
        if let preferred = pinned.owner.preferredName, !preferred.isEmpty {
            facts.append("主人希望被称呼为:\(preferred)")
        }
        let aliases = pinned.owner.names.filter { $0 != pinned.owner.preferredName }
        if !aliases.isEmpty {
            facts.append("主人别名:\(aliases.joined(separator: "、"))")
        }
        guard !facts.isEmpty else { return "" }
        return "固定记忆(主人明确告诉你的,不要被梦境覆盖):" + facts.joined(separator: ";")
    }

    @discardableResult
    func capturePinnedFact(from userText: String, source: String = "chat") -> PinnedMemory.Capture? {
        guard let fact = PinnedMemoryExtractor.extract(from: userText) else { return nil }
        do {
            let capture = try applyPinnedFact(fact, source: source, rawText: userText)
            Log.info("memory", "固定记忆:\(capture.summary)")
            return capture
        } catch {
            Log.info("memory", "\(error)")
            Audit.record(kind: "memory.pinned_failed", summary: "固定记忆写入失败",
                         detail: ["error": "\(error)"])
            return nil
        }
    }

    @discardableResult
    func applyPinnedFact(_ fact: PinnedMemoryExtractor.Fact,
                         source: String = "chat",
                         rawText: String) throws -> PinnedMemory.Capture {
        switch fact {
        case .ownerName(let name, let preferred):
            guard PinnedMemory.isValidName(name) else {
                throw MemoryError.invalidPinnedFact(name)
            }
            var pinned = PinnedMemory.load()
            let capture = pinned.rememberOwnerName(name, preferred: preferred, source: source, rawText: rawText)
            try pinned.save()
            Audit.record(kind: "memory.pinned", summary: capture.summary,
                         detail: ["kind": capture.kind, "value": capture.value])
            return capture
        }
    }

    func write(file: String, content: String) {
        do {
            try writeRequired(file: file, content: content)
        } catch {
            Log.info("memory", "\(error)")
            Audit.record(kind: "memory.write_failed", summary: "记忆写入失败:\(file)",
                         detail: ["file": file])
        }
    }

    func writeRequired(file: String, content: String) throws {
        guard Memory.longTermFiles.contains(file) else {
            throw MemoryError.unsupportedMemoryFile(file)
        }
        let url = Paths.memoryDir.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: Paths.memoryDir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            Audit.record(kind: "memory.write", summary: "更新长期记忆:\(file)",
                         detail: ["file": file])
        } catch {
            throw MemoryError.writeFailed(file, error)
        }
    }

    /// Append a note the pet decided to remember (memory_note from heartbeat).
    /// These accumulate in a scratch file the dream job distills at night.
    func appendNote(_ note: String) {
        do {
            try appendNoteRequired(note)
        } catch {
            Log.info("memory", "\(error)")
            Audit.record(kind: "memory.note_failed", summary: "临时记忆追加失败",
                         detail: ["error": "\(error)"])
        }
    }

    func appendNoteRequired(_ note: String, date: Date = Date()) throws {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let url = notesURL(for: date)
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let line = "- [\(df.string(from: Date()))] \(note)\n"
        do {
            try FileManager.default.createDirectory(at: Paths.memoryDir, withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try h.write(contentsOf: line.data(using: .utf8)!)
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            throw MemoryError.appendFailed(url.lastPathComponent, error)
        }
    }

    func todayNotes() -> String {
        notes(for: Date())
    }

    func notes(for date: Date, includeLegacy: Bool = true) -> String {
        var parts: [String] = []
        if let text = try? String(contentsOf: notesURL(for: date), encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(text)
        }
        if includeLegacy,
           let legacy = try? String(contentsOf: legacyNotesURL, encoding: .utf8),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(legacy)
        }
        return parts.joined(separator: "\n")
    }

    func clearTodayNotes() {
        do {
            try clearNotes(for: Date())
        } catch {
            Log.info("memory", "\(error)")
        }
    }

    func clearNotes(for date: Date, includeLegacy: Bool = true) throws {
        let fm = FileManager.default
        for url in [notesURL(for: date)] + (includeLegacy ? [legacyNotesURL] : []) {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                throw MemoryError.removeFailed(url.lastPathComponent, error)
            }
        }
    }

    @discardableResult
    func snapshotLongTermFiles(reason: String) throws -> [URL] {
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var snapshots: [URL] = []
        do {
            try fm.createDirectory(at: Paths.snapshots, withIntermediateDirectories: true)
        } catch {
            throw MemoryError.snapshotFailed("snapshots", error)
        }

        for file in Memory.longTermFiles {
            let src = Paths.memoryDir.appendingPathComponent(file)
            let name = "memory-\(file).\(df.string(from: Date()))-\(reason)-\(UUID().uuidString.prefix(8)).bak"
            let dst = Paths.snapshots.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: dst)
                } else {
                    try "".write(to: dst, atomically: true, encoding: .utf8)
                }
                snapshots.append(dst)
            } catch {
                throw MemoryError.snapshotFailed(file, error)
            }
        }
        Audit.record(kind: "memory.snapshot", summary: "长期记忆快照:\(reason)",
                     detail: ["count": "\(snapshots.count)"])
        return snapshots
    }

    // MARK: - Skills (self-grown behavior strategies)

    /// Pick up to 2 skills whose filename conditions match the current context.
    /// Matching is local & cheap: filename keywords vs hour/rhythm/weekday.
    func activeSkills(rhythm: WorkRhythm) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.skillsDir, includingPropertiesForKeys: nil) else { return [] }
        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date()) // 1=Sun … 7=Sat
        var hits: [String] = []
        for f in files where f.pathExtension == "md" {
            let name = f.deletingPathExtension().lastPathComponent
            var match = false
            if name.contains("深夜") && (hour >= 22 || hour < 5) { match = true }
            if name.contains("早上") && (5..<11).contains(hour) { match = true }
            if name.contains("周五") && weekday == 6 { match = true }
            if name.contains("周末") && (weekday == 1 || weekday == 7) { match = true }
            if name.contains("deadline") || name.contains("赶工") || name.contains("加班") {
                if rhythm == .focused || rhythm == .busy || hour >= 22 { match = true }
            }
            if name.contains("烦躁") && rhythm == .agitated { match = true }
            if match, let body = try? String(contentsOf: f, encoding: .utf8) {
                hits.append("[\(name)] \(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
            }
            if hits.count >= 2 { break }
        }
        return hits
    }

    func addSkill(name: String, body: String) {
        do {
            try addSkillRequired(name: name, body: body)
        } catch {
            Log.info("memory", "\(error)")
            Audit.record(kind: "memory.skill_failed", summary: "经验写入失败",
                         detail: ["name": name])
        }
    }

    func addSkillRequired(name: String, body: String) throws {
        let safe = sanitizedSkillName(name)
        guard !safe.isEmpty else { throw MemoryError.emptySkillName }
        let url = Paths.skillsDir.appendingPathComponent("\(safe).md")
        do {
            try FileManager.default.createDirectory(at: Paths.skillsDir, withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            Audit.record(kind: "memory.skill", summary: "新增经验:\(safe)",
                         detail: ["file": url.lastPathComponent])
        } catch {
            throw MemoryError.writeFailed(url.lastPathComponent, error)
        }
    }

    func skillCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: Paths.skillsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }.count ?? 0
    }

    func notesURL(for date: Date) -> URL {
        Paths.memoryDir.appendingPathComponent("notes-\(Self.dayString(for: date)).md")
    }

    private var legacyNotesURL: URL {
        Paths.memoryDir.appendingPathComponent("notes_today.md")
    }

    private func sanitizedSkillName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "/:\\\n\r\t").inverted
        let pieces = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(pieces).trimmingCharacters(in: .whitespacesAndNewlines).prefixString(40)
    }

    nonisolated static func dayString(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

struct PinnedMemory: Codable {
    struct Owner: Codable {
        var preferredName: String?
        var names: [String]
    }

    struct Record: Codable {
        var id: String
        var kind: String
        var value: String
        var source: String
        var rawText: String
        var createdAt: String
    }

    struct Capture {
        let kind: String
        let value: String
        let summary: String
    }

    var schemaVersion: Int
    var owner: Owner
    var records: [Record]

    static func empty() -> PinnedMemory {
        PinnedMemory(schemaVersion: 1, owner: Owner(preferredName: nil, names: []), records: [])
    }

    static func load() -> PinnedMemory {
        guard let data = try? Data(contentsOf: Paths.pinnedMemory),
              let memory = try? JSONDecoder().decode(PinnedMemory.self, from: data) else {
            return .empty()
        }
        return memory
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Paths.pinnedMemory, options: .atomic)
    }

    mutating func rememberOwnerName(_ name: String, preferred: Bool, source: String, rawText: String) -> Capture {
        let cleanName = Self.normalizedName(name)
        if !owner.names.contains(cleanName) {
            owner.names.append(cleanName)
        }
        if preferred || owner.preferredName == nil {
            owner.preferredName = cleanName
        }
        records.append(Record(
            id: "owner-name-\(UUID().uuidString)",
            kind: preferred ? "owner.preferred_name" : "owner.name",
            value: cleanName,
            source: source,
            rawText: rawText,
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))
        let summary = preferred
            ? "记住主人称呼:\(cleanName)"
            : "记住主人名字/别名:\(cleanName)"
        return Capture(kind: preferred ? "owner.preferred_name" : "owner.name",
                       value: cleanName,
                       summary: summary)
    }

    static func isValidName(_ value: String) -> Bool {
        let name = normalizedName(value)
        guard (1...12).contains(name.count) else { return false }
        let rejected = ["开玩笑", "说这个", "不是", "在忙", "饿了", "困了", "开心", "生气", "主人"]
        guard !rejected.contains(where: { name.contains($0) }) else { return false }
        guard !name.contains(" ") && !name.contains("\n") && !name.contains("\t") else { return false }
        return true
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " 「」\"'：:，,。!！?？、\n\t"))
    }
}

enum PinnedMemoryExtractor {
    enum Fact: Equatable {
        case ownerName(name: String, preferred: Bool)
    }

    static func extract(from text: String) -> Fact? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        if let name = extractAfterAny(of: ["以后叫我", "以后喊我", "以后称呼我", "叫我", "喊我", "称呼我"], in: normalized),
           PinnedMemory.isValidName(name) {
            return .ownerName(name: name, preferred: true)
        }

        if hasMemoryIntent(normalized),
           let name = extractAfterAny(of: ["我叫", "我的名字是", "名字是"], in: normalized),
           PinnedMemory.isValidName(name) {
            return .ownerName(name: name, preferred: true)
        }

        if hasMemoryIntent(normalized),
           let name = extractAfterAny(of: ["我是"], in: normalized),
           PinnedMemory.isValidName(name),
           looksLikeNameAlias(name) {
            return .ownerName(name: name, preferred: false)
        }

        if let name = extractAfterAny(of: ["我叫", "我的名字是", "名字是"], in: normalized),
           PinnedMemory.isValidName(name) {
            return .ownerName(name: name, preferred: true)
        }

        if normalized.hasPrefix("我是"),
           let name = extractAfterAny(of: ["我是"], in: normalized),
           PinnedMemory.isValidName(name),
           looksLikeNameAlias(name) {
            return .ownerName(name: name, preferred: false)
        }

        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
    }

    private static func hasMemoryIntent(_ text: String) -> Bool {
        ["记住", "记得", "别忘", "不要忘", "以后"].contains { text.contains($0) }
    }

    private static func extractAfterAny(of markers: [String], in text: String) -> String? {
        for marker in markers {
            guard let range = text.range(of: marker, options: [.caseInsensitive, .widthInsensitive]) else { continue }
            let suffix = String(text[range.upperBound...])
            let firstClause = suffix
                .split(whereSeparator: { "，,。.!！?？；;".contains($0) })
                .first
                .map(String.init) ?? suffix
            let clean = PinnedMemory.normalizedName(firstClause)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private static func looksLikeNameAlias(_ name: String) -> Bool {
        if name.contains("哥") || name.contains("姐") || name.contains("总") || name.contains("老师") { return true }
        if name.hasSuffix("王哥") || name.hasSuffix("王总") { return true }
        return false
    }
}

/// Persistent pet state (stage, experience counters, bond).
struct PetState: Codable {
    var stage: String
    var days_together: Int
    var events_seen: Int
    var interactions: Int
    var bond: Double
    var trust: Double
    var born_at: String
    var pending_stage: String?

    static func load() -> PetState {
        if let data = try? Data(contentsOf: Paths.state),
           let s = try? JSONDecoder().decode(PetState.self, from: data) {
            return s
        }
        return PetState(stage: "hatchling", days_together: 0, events_seen: 0,
                        interactions: 0, bond: 0.1, trust: 0.2,
                        born_at: ISO8601DateFormatter().string(from: Date()),
                        pending_stage: nil)
    }

    func save() {
        do {
            try saveRequired()
        } catch {
            Log.info("state", "保存失败:\(error)")
        }
    }

    func saveRequired() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Paths.state, options: .atomic)
    }

    /// Apply a small long-term bond increment and persist. PetState.bond is the
    /// single source of truth for bond (Affect no longer holds a copy).
    static func recordBondGain(_ delta: Double) {
        var state = load()
        state.bond = min(1, state.bond + delta)
        state.save()
    }
}

private extension String {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
