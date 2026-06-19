import Foundation
import GuguKernel

/// Local, offline-first queue for owner-approved autonomous work.
/// Stored as JSON Lines at `Paths.root/autonomy_tasks.jsonl`.
final class AutonomyTaskQueue {
    enum TaskKind: String, Codable, CaseIterable {
        case note
        case reminder
        case research
    }

    enum TaskStatus: String, Codable {
        case pending
        case completed
        case failed
    }

    struct Task: Codable, Identifiable {
        let id: String
        let kind: TaskKind
        let title: String
        let body: String
        let createdAt: Date
        let dueAt: Date?
        var status: TaskStatus
        var result: String?
        var error: String?
        var completedAt: Date?
    }

    struct RunResult {
        let task: Task
        let succeeded: Bool
    }

    enum QueueError: Error, CustomStringConvertible {
        case emptyTitle
        case unsupportedKind(String)
        case taskNotFound(String)
        case taskNotPending(String)
        case storageReadFailed(String)
        case storageWriteFailed(String)
        case runnerFailed(String)

        var description: String {
            switch self {
            case .emptyTitle: return "task title is empty"
            case .unsupportedKind(let kind): return "unsupported task kind: \(kind)"
            case .taskNotFound(let id): return "task not found: \(id)"
            case .taskNotPending(let id): return "task is not pending: \(id)"
            case .storageReadFailed(let message): return "failed to read autonomy task queue: \(message)"
            case .storageWriteFailed(let message): return "failed to write autonomy task queue: \(message)"
            case .runnerFailed(let message): return message
            }
        }
    }

    typealias Runner = (Task) async throws -> String

    private let storageURL: URL
    private let runner: Runner
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storageURL: URL = Paths.root.appendingPathComponent("autonomy_tasks.jsonl"),
        fileManager: FileManager = .default,
        runner: @escaping Runner = AutonomyTaskQueue.offlineRunner
    ) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.runner = runner

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @discardableResult
    func enqueue(kind: TaskKind, title: String, body: String = "", dueAt: Date? = nil) throws -> Task {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw QueueError.emptyTitle }

        var tasks = try loadAll()
        let task = Task(
            id: Self.makeID(),
            kind: kind,
            title: trimmedTitle,
            body: body,
            createdAt: Date(),
            dueAt: dueAt,
            status: .pending,
            result: nil,
            error: nil,
            completedAt: nil
        )
        tasks.append(task)
        try saveAll(tasks)
        Audit.record(
            kind: "autonomy.enqueue",
            summary: "入队夜间任务:\(task.title)",
            detail: auditDetail(for: task)
        )
        return task
    }

    @discardableResult
    func enqueue(kind rawKind: String, title: String, body: String = "", dueAt: Date? = nil) throws -> Task {
        guard let kind = TaskKind(rawValue: rawKind) else {
            throw QueueError.unsupportedKind(rawKind)
        }
        return try enqueue(kind: kind, title: title, body: body, dueAt: dueAt)
    }

    func listPending(now: Date = Date()) throws -> [Task] {
        try loadAll()
            .filter { $0.status == .pending && ($0.dueAt == nil || $0.dueAt! <= now) }
            .sorted { lhs, rhs in
                switch (lhs.dueAt, rhs.dueAt) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.createdAt < rhs.createdAt
                }
            }
    }

    @discardableResult
    func complete(id: String, result: String) throws -> Task {
        try update(id: id) { task in
            guard task.status == .pending else { throw QueueError.taskNotPending(id) }
            task.status = .completed
            task.result = result
            task.error = nil
            task.completedAt = Date()
        }
    }

    @discardableResult
    func fail(id: String, error: String) throws -> Task {
        try update(id: id) { task in
            guard task.status == .pending else { throw QueueError.taskNotPending(id) }
            task.status = .failed
            task.error = error
            task.completedAt = Date()
        }
    }

    @discardableResult
    func runDue(now: Date = Date(), limit: Int? = nil) async throws -> [RunResult] {
        let dueTasks = try Array(listPending(now: now).prefix(limit ?? Int.max))
        var results: [RunResult] = []

        for task in dueTasks {
            do {
                let result = try await runner(task)
                let completed = try complete(id: task.id, result: result)
                results.append(RunResult(task: completed, succeeded: true))
            } catch {
                let failed = try fail(id: task.id, error: String(describing: error))
                results.append(RunResult(task: failed, succeeded: false))
            }
        }

        return results
    }

    static func offlineRunner(task: Task) async throws -> String {
        switch task.kind {
        case .note:
            return task.body.isEmpty ? "离线记录:\(task.title)" : "离线记录:\(task.title)\n\(task.body)"
        case .reminder:
            return task.body.isEmpty ? "离线提醒:\(task.title)" : "离线提醒:\(task.title)\n\(task.body)"
        case .research:
            return task.body.isEmpty ? "离线记录待研究:\(task.title)" : "离线记录待研究:\(task.title)\n\(task.body)"
        }
    }

    /// Real runner: routes each task through the local tool layer so a deferred
    /// note/reminder/research actually lands instead of returning a stub string.
    /// research 当前只记录请求(框架就绪,出网待接入,见 LocalToolExecutor.webSearchRequest)。
    /// A denied tool (permission off) fails the task — the queue records the
    /// truth rather than marking unfinished work "completed".
    static func toolRunner(config: Config) -> Runner {
        return { task in
            let executor = LocalToolExecutor(config: config)
            let result: LocalToolExecutor.Result
            switch task.kind {
            case .note:
                result = executor.execute(.init(name: "notes.add", arguments: ["text": task.title]))
            case .reminder:
                var args = ["text": task.title]
                if !task.body.isEmpty { args["due"] = task.body }
                result = executor.execute(.init(name: "reminders.add", arguments: args))
            case .research:
                var args = ["query": task.title]
                if !task.body.isEmpty { args["reason"] = task.body }
                result = executor.execute(.init(name: "web_search.request", arguments: args))
            }
            guard result.ok else {
                throw QueueError.runnerFailed(result.message)
            }
            return result.message
        }
    }

    private func loadAll() throws -> [Task] {
        guard fileManager.fileExists(atPath: storageURL.path) else { return [] }
        do {
            let text = try String(contentsOf: storageURL, encoding: .utf8)
            return try text
                .split(separator: "\n")
                .map { line in
                    guard let data = String(line).data(using: .utf8) else {
                        throw QueueError.storageReadFailed("invalid UTF-8 line")
                    }
                    return try decoder.decode(Task.self, from: data)
                }
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.storageReadFailed(String(describing: error))
        }
    }

    private func saveAll(_ tasks: [Task]) throws {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let lines = try tasks.map { task -> String in
                let data = try encoder.encode(task)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw QueueError.storageWriteFailed("failed to encode task \(task.id)")
                }
                return line
            }
            let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            try text.write(to: storageURL, atomically: true, encoding: .utf8)
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.storageWriteFailed(String(describing: error))
        }
    }

    private func update(id: String, mutate: (inout Task) throws -> Void) throws -> Task {
        var tasks = try loadAll()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw QueueError.taskNotFound(id)
        }

        try mutate(&tasks[index])
        let updated = tasks[index]
        try saveAll(tasks)

        switch updated.status {
        case .completed:
            Audit.record(
                kind: "autonomy.complete",
                summary: "完成夜间任务:\(updated.title)",
                detail: auditDetail(for: updated)
            )
        case .failed:
            var detail = auditDetail(for: updated)
            if let error = updated.error { detail["error"] = error }
            Audit.record(
                kind: "autonomy.fail",
                summary: "夜间任务失败:\(updated.title)",
                detail: detail
            )
        case .pending:
            break
        }

        return updated
    }

    private func auditDetail(for task: Task) -> [String: String] {
        var detail = [
            "id": task.id,
            "kind": task.kind.rawValue,
            "status": task.status.rawValue,
            "storage": storageURL.lastPathComponent,
        ]
        if let dueAt = task.dueAt {
            detail["due_at"] = ISO8601DateFormatter().string(from: dueAt)
        }
        return detail
    }

    private static func makeID() -> String {
        "task-\(UUID().uuidString.lowercased())"
    }
}
