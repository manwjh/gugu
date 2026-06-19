import Foundation

/// Append-only local audit log for actions that change files, settings, or
/// permissions. It stores only summaries and file paths, never raw sensor data.
///
/// Foundational: `record` depends only on `Paths`, so it lives in Kernel and
/// every layer can write audit lines downward. The human-facing `report` (which
/// must read proposals/evolution state) stays up in Evolution as an extension.
enum Audit {
    static func record(kind: String, summary: String, detail: [String: String] = [:]) {
        var obj: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "summary": summary,
        ]
        if !detail.isEmpty { obj["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Paths.auditFile()
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
