import Foundation
import GuguKernel

/// Local backups created before proposal application. Restore is explicit and
/// only targets first-class editable files.
enum SnapshotStore {
    enum RestoreError: Error, CustomStringConvertible {
        case unsupportedSnapshot(String)
        case missingSnapshot(String)

        var description: String {
            switch self {
            case .unsupportedSnapshot(let n): return "unsupported snapshot: \(n)"
            case .missingSnapshot(let n): return "missing snapshot: \(n)"
            }
        }
    }

    static func latestSnapshot(for fileName: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Paths.snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("\(fileName).") && $0.pathExtension == "bak" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
    }

    static func restoreLatest(for fileName: String) throws -> URL {
        guard let target = targetURL(for: fileName) else {
            throw RestoreError.unsupportedSnapshot(fileName)
        }
        guard let snapshot = latestSnapshot(for: fileName) else {
            throw RestoreError.missingSnapshot(fileName)
        }
        try FileManager.default.copyItemReplacingExisting(at: snapshot, to: target)
        Audit.record(kind: "snapshot.restore", summary: "恢复快照:\(fileName)",
                     detail: ["snapshot": snapshot.lastPathComponent, "target": target.lastPathComponent])
        return target
    }

    private static func targetURL(for fileName: String) -> URL? {
        switch fileName {
        case "config.yaml": return Paths.config
        case "persona.md": return Paths.persona
        case "state.json": return Paths.state
        default: return nil
        }
    }
}

private extension FileManager {
    func copyItemReplacingExisting(at src: URL, to dst: URL) throws {
        if fileExists(atPath: dst.path) {
            try removeItem(at: dst)
        }
        try copyItem(at: src, to: dst)
    }
}
