import Foundation

/// Shared result/error types and the protocol both LLM transports implement.
/// Two providers conform: `AnthropicClient` (Messages API, the default) and
/// `OpenAIClient` (Chat Completions, for OpenAI-compatible vendors). Only the
/// single-call `create` is shared — batch is Anthropic-only and lives on that
/// concrete type (the dream path guards with `as? AnthropicClient`).
@MainActor
protocol LLMClient: Sendable {
    var baseURL: String { get }
    var apiKey: String { get }

    /// One model call. `system` is the persona/system prompt; `messages` are
    /// Anthropic-style role/content dicts (the OpenAI client flattens them).
    /// `schema`, when present, requests structured JSON output.
    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]?,
        retries: Int
    ) async throws -> LLMReply
}

extension LLMClient {
    /// Convenience overload with a default retry count, so call sites (and the
    /// existential type) can omit `retries`. Protocol witnesses can't carry
    /// default args, so the default lives here.
    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil
    ) async throws -> LLMReply {
        try await create(model: model, maxTokens: maxTokens, system: system,
                         messages: messages, schema: schema, retries: 2)
    }
}

/// Normalized single-call result. `stopReason` is currently informational only
/// (Brain reads `text`), but kept so both providers can report it uniformly.
struct LLMReply: Sendable {
    let text: String
    let stopReason: String
}

enum LLMError: Error, CustomStringConvertible {
    case http(Int, String)
    case malformed(String)
    /// 传输层错误(超时/断网/连接被中转通道挂住)。可重试。
    case transport(String)
    /// 200 但正文为空(reasoning 模型有时只填 reasoning_content)。可重试。
    case empty(String)
    var description: String {
        switch self {
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        case .malformed(let s): return "malformed response: \(s.prefix(300))"
        case .transport(let s): return "transport error: \(s.prefix(300))"
        case .empty(let s): return "empty content: \(s.prefix(300))"
        }
    }
}

// MARK: - Shared transport (hard timeout so a stalled relay can't hang forever)

/// 两个 client 共用的传输层。关键:除了 `timeoutIntervalForRequest`(字节间空闲超时,
/// 中转通道持续 trickle 数据时它永不触发),再设一个 `timeoutIntervalForResource`
/// **硬资源超时**——无论如何,单次请求超过它就一定失败,而不是无限挂起。
/// 这修掉了"心跳秒回、但 learnMove 这类较重请求永久卡死、既不成功也不报错"的问题。
enum LLMTransport {
    /// 单次请求的硬上限(秒)。deepseek-v4 带 reasoning 的较重请求实测 ~12s;
    /// 给到 150s(10× 余量),既不误杀慢请求,又保证绝不无限挂。
    static let resourceTimeout: TimeInterval = 150

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90       // 字节间空闲超时
        cfg.timeoutIntervalForResource = resourceTimeout  // 整次请求硬上限
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 发请求并归一化结果:返回 (data, httpCode);传输异常统一包成 `LLMError.transport`,
    /// 并记一行带耗时的 `llm` 日志,便于真机诊断"到底花了多久 / 卡在哪"。
    static func send(_ req: URLRequest, label: String) async throws -> (Data, Int) {
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            Log.info("llm", "\(label) → \(code) · \(String(format: "%.1f", Date().timeIntervalSince(start)))s · \(data.count)B")
            return (data, code)
        } catch {
            Log.info("llm", "\(label) 传输失败 · \(String(format: "%.1f", Date().timeIntervalSince(start)))s · \(error.localizedDescription)")
            throw LLMError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Retry policy (shared by both transports)

enum LLMRetry {
    /// True for transient statuses worth retrying (rate limit / server error).
    static func isTransient(_ code: Int) -> Bool { code == 429 || code >= 500 }

    /// Whether an LLMError is worth retrying: transient HTTP codes, or any
    /// transport-layer error (timeout / dropped connection).
    static func isRetriable(_ error: LLMError) -> Bool {
        switch error {
        case .http(let code, _): return isTransient(code)
        case .transport: return true
        case .empty: return true
        case .malformed: return false
        }
    }

    /// Exponential backoff with jitter, matching the original Anthropic client.
    static func backoffSeconds(attempt: Int) -> Double {
        pow(2.0, Double(attempt)) + Double.random(in: 0...1)
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
