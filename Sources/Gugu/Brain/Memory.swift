import Foundation

/// Long-term memory: small markdown files the dream job rewrites nightly.
/// Deliberately small & fuzzy — both for token economy and the pet's persona.
@MainActor
final class Memory {
    /// Combined memory digest for prompts, capped in length.
    func digest(maxChars: Int = 500) -> String {
        var parts: [String] = []
        for (name, file) in [("主人", "owner.md"), ("近况", "projects.md"), ("我", "self.md")] {
            let url = Paths.memoryDir.appendingPathComponent(file)
            if let t = try? String(contentsOf: url, encoding: .utf8),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("\(name):\(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let joined = parts.joined(separator: "\n")
        return String(joined.prefix(maxChars))
    }

    func write(file: String, content: String) {
        let url = Paths.memoryDir.appendingPathComponent(file)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Append a note the pet decided to remember (memory_note from heartbeat).
    /// These accumulate in a scratch file the dream job distills at night.
    func appendNote(_ note: String) {
        guard !note.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let url = Paths.memoryDir.appendingPathComponent("notes_today.md")
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let line = "- [\(df.string(from: Date()))] \(note)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func todayNotes() -> String {
        let url = Paths.memoryDir.appendingPathComponent("notes_today.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func clearTodayNotes() {
        let url = Paths.memoryDir.appendingPathComponent("notes_today.md")
        try? FileManager.default.removeItem(at: url)
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
        let safe = name.replacingOccurrences(of: "/", with: "_").prefix(40)
        let url = Paths.skillsDir.appendingPathComponent("\(safe).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    func skillCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: Paths.skillsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }.count ?? 0
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
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Paths.state)
        }
    }
}
