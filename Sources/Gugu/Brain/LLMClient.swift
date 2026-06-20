import Foundation
import GuguKernel

/// Shared result/error/transport types for the LLM layer. There is a single
/// transport — `OpenAIClient` (Chat Completions; taas.hk / DeepSeek-style).

/// Per-call timeout + retry behavior. The pet is interactive: a heartbeat must
/// feel live, so it fails fast rather than retrying a slow/stalled call for
/// minutes. Background work (dream) can afford to be slow and to retry.
struct LLMCallPolicy: Sendable {
    /// Per-request idle timeout (seconds); set on `URLRequest.timeoutInterval`.
    var timeout: TimeInterval
    /// Max retries for retriable errors (429/5xx, dropped connection, empty body).
    var retries: Int
    /// Whether a client-side **timeout** is worth retrying. False for interactive
    /// calls: a timeout already means "waited long enough" — retrying with the
    /// same long timeout just waits again (this was the 4-minute heartbeat hang).
    /// True only for background work where latency is irrelevant.
    var retryOnTimeout: Bool

    /// 心跳:要"活物感",必须快;超时直接发呆,不拖几分钟。连接被拒/TLS 抖动可补一次。
    static let heartbeat = LLMCallPolicy(timeout: 20, retries: 1, retryOnTimeout: false)
    /// 对话:主人在等,失败要快;超时不重试。
    static let chat = LLMCallPolicy(timeout: 45, retries: 1, retryOnTimeout: false)
    /// 梦境 / 批处理:夜间后台,可以慢、可重试(含超时)。
    static let dream = LLMCallPolicy(timeout: 120, retries: 2, retryOnTimeout: true)
}

/// Normalized single-call result.
struct LLMReply: Sendable {
    let text: String
}

enum LLMError: Error, CustomStringConvertible {
    case http(Int, String)
    case malformed(String)
    /// 连接被拒 / TLS 失败 / 断网 — 可重试一次(故障可能瞬时)。
    case transport(String)
    /// 客户端超时 — 已经等够了,交互调用不重试(只有 dream 才重试)。
    case timeout(String)
    /// 200 但正文为空(reasoning 模型有时只填 reasoning_content)。可重试。
    case empty(String)
    var description: String {
        switch self {
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        case .malformed(let s): return "malformed response: \(s.prefix(300))"
        case .transport(let s): return "transport error: \(s.prefix(300))"
        case .timeout(let s): return "timeout: \(s.prefix(300))"
        case .empty(let s): return "empty content: \(s.prefix(300))"
        }
    }
}

// MARK: - Shared transport (per-request timeout + uniform logging/error mapping)

/// 两个 client(含 batch 路径)共用的传输层。每次请求的超时由调用方通过
/// `URLRequest.timeoutInterval`(=`LLMCallPolicy.timeout`)设定;会话级
/// `timeoutIntervalForResource` 只作绝对兜底,保证再坏也不无限挂。
enum LLMTransport {
    /// 会话级硬资源上限(秒):单次请求绝对天花板,per-request 超时之外的兜底。
    static let resourceTimeout: TimeInterval = 150

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90       // 默认空闲超时;具体调用用 timeoutInterval 覆盖
        cfg.timeoutIntervalForResource = resourceTimeout
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 发请求并归一化结果:返回 (data, httpCode)。**超时→`.timeout`**,其它传输异常→
    /// `.transport`,都记一行带耗时的 `llm` 日志。所有路径(含 batch)都走这里。
    static func send(_ req: URLRequest, label: String) async throws -> (Data, Int) {
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            Log.info("llm", "\(label) → \(code) · \(String(format: "%.1f", Date().timeIntervalSince(start)))s · \(data.count)B")
            return (data, code)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            Log.info("llm", "\(label) 超时 · \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            throw LLMError.timeout(urlErr.localizedDescription)
        } catch {
            Log.info("llm", "\(label) 传输失败 · \(String(format: "%.1f", Date().timeIntervalSince(start)))s · \(error.localizedDescription)")
            throw LLMError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Retry policy (shared loop used by both transports)

enum LLMRetry {
    /// True for transient statuses worth retrying (rate limit / server error).
    static func isTransient(_ code: Int) -> Bool { code == 429 || code >= 500 }

    /// Whether an `LLMError` is worth retrying under the given policy.
    static func isRetriable(_ error: LLMError, retryOnTimeout: Bool) -> Bool {
        switch error {
        case .http(let code, _): return isTransient(code)
        case .transport: return true        // dropped connection/TLS — may be transient
        case .timeout: return retryOnTimeout // already waited long enough
        case .empty: return true
        case .malformed: return false
        }
    }

    /// Exponential backoff with jitter.
    static func backoffSeconds(attempt: Int) -> Double {
        pow(2.0, Double(attempt)) + Double.random(in: 0...1)
    }

    /// 两个 client 共用的重试循环:按 `policy` 决定可重试性与次数,指数退避。
    /// 消除了原先在两个 client 里逐字复制的 while-loop。
    @MainActor
    static func run(policy: LLMCallPolicy,
                    _ body: @MainActor () async throws -> LLMReply) async throws -> LLMReply {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let e as LLMError {
                if isRetriable(e, retryOnTimeout: policy.retryOnTimeout), attempt < policy.retries {
                    attempt += 1
                    let delay = backoffSeconds(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw e
            }
        }
    }
}

// MARK: - Schema → prompt hint (OpenAI-compatible structured output)

enum SchemaHint {
    /// Turn a JSON-schema object into a short instruction appended to the system
    /// prompt, for vendors that support only `response_format: json_object` (not
    /// `json_schema`). Lists the keys, their enums, and which are required.
    /// Bilingual, following `L.current`.
    static func describe(_ schema: [String: Any]) -> String {
        guard let props = schema["properties"] as? [String: Any] else {
            return L.schemaHintGeneric
        }
        let required = Set(schema["required"] as? [String] ?? [])
        // Stable order for byte-stable prompts (prefix caching friendliness).
        let keys = props.keys.sorted()
        var lines: [String] = []
        for key in keys {
            guard let spec = props[key] as? [String: Any] else { continue }
            var parts: [String] = []
            if let enums = spec["enum"] as? [String] {
                parts.append(enums.joined(separator: "/"))
            } else if let type = spec["type"] as? String {
                parts.append(type)
            }
            if let desc = spec["description"] as? String, !desc.isEmpty {
                parts.append(desc)
            }
            let req = required.contains(key) ? L.schemaHintRequired : ""
            let detail = parts.isEmpty ? "" : "(\(parts.joined(separator: " · ")))"
            lines.append("- \(key)\(req) \(detail)")
        }
        return L.schemaHintHeader + "\n" + lines.joined(separator: "\n")
    }
}
