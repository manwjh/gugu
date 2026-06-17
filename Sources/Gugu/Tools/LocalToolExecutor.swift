import Foundation

/// Local-only tool layer. It never performs network requests; tools either
/// append small JSONL records under Paths.root or return a clear denial.
struct LocalToolExecutor {
    struct ToolCall {
        let name: String
        let arguments: [String: String]

        init(name: String, arguments: [String: String] = [:]) {
            self.name = name
            self.arguments = arguments
        }
    }

    struct Result {
        let tool: String
        let ok: Bool
        let allowed: Bool
        let message: String
        let recordID: String?
        let file: URL?
    }

    enum ToolError: Error, LocalizedError {
        case unknownTool(String)
        case missingArgument(tool: String, argument: String)
        case invalidArgument(tool: String, argument: String)
        case writeFailed(tool: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let tool):
                return "未知本地工具:\(tool)"
            case .missingArgument(let tool, let argument):
                return "\(tool) 缺少参数:\(argument)"
            case .invalidArgument(let tool, let argument):
                return "\(tool) 参数无效:\(argument)"
            case .writeFailed(let tool, let underlying):
                return "\(tool) 写入失败:\(underlying.localizedDescription)"
            }
        }
    }

    let config: Config

    private let iso = ISO8601DateFormatter()

    init(config: Config) {
        self.config = config
    }

    func execute(_ call: ToolCall) -> Result {
        do {
            switch call.name {
            case "notes.add":
                return try addNote(text: required("text", in: call))
            case "reminders.add":
                return try addReminder(
                    text: required("text", in: call),
                    due: optional("due", in: call)
                )
            case "web_search.request":
                return try webSearchRequest(
                    query: required("query", in: call),
                    reason: optional("reason", in: call)
                )
            default:
                let result = Result(
                    tool: call.name,
                    ok: false,
                    allowed: false,
                    message: "未知本地工具:\(call.name)",
                    recordID: nil,
                    file: nil
                )
                audit(result, detail: ["tool": call.name])
                return result
            }
        } catch let error as ToolError {
            let result = Result(
                tool: call.name,
                ok: false,
                allowed: true,
                message: error.localizedDescription,
                recordID: nil,
                file: nil
            )
            audit(result, detail: ["tool": call.name])
            return result
        } catch {
            let result = Result(
                tool: call.name,
                ok: false,
                allowed: true,
                message: error.localizedDescription,
                recordID: nil,
                file: nil
            )
            audit(result, detail: ["tool": call.name])
            return result
        }
    }

    func addNote(text: String) throws -> Result {
        let tool = "notes.add"
        guard config.toolNotes else {
            return denied(tool: tool, message: L.notesNotAuthorized)
        }

        let cleanText = normalized(text)
        guard !cleanText.isEmpty else {
            throw ToolError.invalidArgument(tool: tool, argument: "text")
        }

        let id = makeID(prefix: "note")
        let url = Paths.root.appendingPathComponent("notes.jsonl")
        let record: [String: Any] = [
            "id": id,
            "t": iso.string(from: Date()),
            "text": cleanText,
        ]
        try appendJSONLine(record, to: url, tool: tool)
        return allowed(tool: tool, message: L.noteRecorded, id: id, file: url)
    }

    func addReminder(text: String, due: String? = nil) throws -> Result {
        let tool = "reminders.add"
        guard config.toolReminders else {
            return denied(tool: tool, message: L.remindersNotAuthorized)
        }

        let cleanText = normalized(text)
        guard !cleanText.isEmpty else {
            throw ToolError.invalidArgument(tool: tool, argument: "text")
        }

        let cleanDue = normalized(due ?? "")
        let id = makeID(prefix: "reminder")
        let url = Paths.root.appendingPathComponent("reminders.jsonl")
        var record: [String: Any] = [
            "id": id,
            "t": iso.string(from: Date()),
            "text": cleanText,
        ]
        if !cleanDue.isEmpty { record["due"] = cleanDue }
        try appendJSONLine(record, to: url, tool: tool)

        var scheduledMessage = cleanDue.isEmpty ? L.reminderRecorded : L.reminderRecordedWithDue(cleanDue)
        if config.toolLocalNotifications {
            if cleanDue.isEmpty {
                LocalNotifier.notify(title: L.reminderNotificationTitle, body: cleanText)
            } else if let fireDate = DueDateParser.parse(cleanDue) {
                LocalNotifier.schedule(title: L.reminderNotificationTitle, body: cleanText, at: fireDate)
                let fmt = DateFormatter()
                fmt.dateFormat = L.current == .zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
                scheduledMessage = L.reminderScheduled(fmt.string(from: fireDate))
            } else {
                // due present but unparseable — don't silently drop it
                LocalNotifier.notify(title: L.reminderNotificationTitle, body: cleanText)
            }
        }
        return allowed(tool: tool, message: scheduledMessage, id: id, file: url)
    }

    /// 联网搜索请求。**框架就绪,但当前只把请求记录到本地,尚未真正出网。**
    ///
    /// 这是"共同能动性"的最小落地:权限门控 + 审计 + 队列(见 AutonomyTaskQueue.research)
    /// 全链路打通,唯独"出网"那一步留了一个干净的接口(`WebSearchProvider`)。
    /// 将来要真联网,只需注入一个真正发请求的 provider——隐私边界(B1/B2)在这一层守住:
    /// 默认 provider 不发任何网络请求,只在本机留痕。
    func webSearchRequest(query: String, reason: String? = nil) throws -> Result {
        let tool = "web_search.request"
        guard config.toolWebSearch else {
            return denied(tool: tool, message: L.webSearchNotAuthorized)
        }
        let cleanQuery = normalized(query)
        guard !cleanQuery.isEmpty else {
            throw ToolError.invalidArgument(tool: tool, argument: "query")
        }
        let id = makeID(prefix: "research")
        let url = Paths.root.appendingPathComponent("research_requests.jsonl")
        var record: [String: Any] = [
            "id": id,
            "t": iso.string(from: Date()),
            "query": cleanQuery,
            "status": "pending",           // 出网接入后由 provider 改写为 fetched/failed
        ]
        let cleanReason = normalized(reason ?? "")
        if !cleanReason.isEmpty { record["reason"] = cleanReason }
        try appendJSONLine(record, to: url, tool: tool)
        return allowed(tool: tool, message: L.webSearchRecorded, id: id, file: url)
    }

    private func required(_ key: String, in call: ToolCall) throws -> String {        guard let value = call.arguments[key] else {
            throw ToolError.missingArgument(tool: call.name, argument: key)
        }
        return value
    }

    private func optional(_ key: String, in call: ToolCall) -> String? {
        call.arguments[key]
    }

    private func denied(tool: String, message: String) -> Result {
        let result = Result(tool: tool, ok: false, allowed: false, message: message, recordID: nil, file: nil)
        audit(result)
        return result
    }

    private func allowed(tool: String, message: String, id: String, file: URL) -> Result {
        let result = Result(tool: tool, ok: true, allowed: true, message: message, recordID: id, file: file)
        audit(result, detail: ["record_id": id, "file": file.path])
        return result
    }

    private func audit(_ result: Result, detail: [String: String] = [:]) {
        var auditDetail = detail
        auditDetail["allowed"] = result.allowed ? "true" : "false"
        auditDetail["ok"] = result.ok ? "true" : "false"
        if let recordID = result.recordID { auditDetail["record_id"] = recordID }
        if let file = result.file { auditDetail["file"] = file.path }
        Audit.record(kind: "tool.\(result.tool)", summary: result.message, detail: auditDetail)
    }

    private func appendJSONLine(_ object: [String: Any], to url: URL, tool: String) throws {
        do {
            try FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else {
                throw ToolError.writeFailed(tool: tool, underlying: CocoaError(.fileWriteInapplicableStringEncoding))
            }
            line += "\n"
            let lineData = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: url, options: .atomic)
            }
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.writeFailed(tool: tool, underlying: error)
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
