import Foundation

/// All on-disk locations for Gugu. Everything lives under
/// ~/Library/Application Support/Gugu/ as plain text the owner can edit.
enum Paths {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["GUGU_HOME"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gugu", isDirectory: true)
    }()

    static let config     = root.appendingPathComponent("config.yaml")
    static let persona    = root.appendingPathComponent("persona.md")
    static let evolution  = root.appendingPathComponent("evolution.yaml")
    static let state      = root.appendingPathComponent("state.json")
    static let usage      = root.appendingPathComponent("usage.json")
    static let schedulerState = root.appendingPathComponent("scheduler.json")
    static let dreamBatchState = root.appendingPathComponent("dream_batch.json")
    static let pinnedMemory = root.appendingPathComponent("pinned.json")
    static let memoryDir  = root.appendingPathComponent("memory", isDirectory: true)
    static let skillsDir  = root.appendingPathComponent("skills", isDirectory: true)
    static let eventsDir  = root.appendingPathComponent("events", isDirectory: true)
    static let modelsDir  = root.appendingPathComponent("models", isDirectory: true)
    static let auditDir   = root.appendingPathComponent("audit", isDirectory: true)
    static let proposals  = root.appendingPathComponent("proposals", isDirectory: true)
    static let snapshots  = root.appendingPathComponent("snapshots", isDirectory: true)
    static let chatLog    = root.appendingPathComponent("chat.jsonl")
    static let logFile    = root.appendingPathComponent("gugu.log")

    static func bootstrap() throws {
        let fm = FileManager.default
        for dir in [root, memoryDir, skillsDir, eventsDir, modelsDir, auditDir, proposals, snapshots] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: pinnedMemory.deletingLastPathComponent().path) {
            try fm.createDirectory(at: pinnedMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    static func eventsFile(for date: Date = Date()) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return eventsDir.appendingPathComponent("\(df.string(from: date)).jsonl")
    }

    /// Delete event files older than 7 days (privacy: rolling window).
    static func pruneOldEvents() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for f in files {
            if let created = (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               created < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    static func auditFile(for date: Date = Date()) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return auditDir.appendingPathComponent("\(df.string(from: date)).jsonl")
    }
}

/// Simple shared logger: prints to stdout and appends to gugu.log.
enum Log {
    private static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "HH:mm:ss"
        return d
    }()
    private static let queue = DispatchQueue(label: "gugu.log")

    static func info(_ tag: String, _ msg: String) {
        let line = "[\(df.string(from: Date()))] [\(tag)] \(msg)"
        print(line)
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: Paths.logFile) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: Paths.logFile)
            }
        }
    }
}
