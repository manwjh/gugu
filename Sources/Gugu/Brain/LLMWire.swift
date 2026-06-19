import Foundation
import GuguKernel

/// Typed wire models for the two LLM protocols. Replaces the old `[String: Any]`
/// + `JSONSerialization` request/response handling so request construction and
/// response parsing are compile-time checked and the trickiest extraction logic
/// (reasoning fallback / truncation / empty) lives in pure, offline-testable
/// functions rather than buried in the network methods.
///
/// No SDK dependency: this is ~the part of a mature client worth having (typed
/// contract), hand-written to keep the zero-dependency / dual-protocol posture.

// MARK: - JSONValue (the one genuinely dynamic field: Anthropic's JSON Schema)

/// Minimal symmetric Codable JSON value. Built from the `[String: Any]` schema
/// dicts Brain constructs, so an arbitrary JSON Schema can ride inside a typed
/// `Encodable` request without resorting to `JSONSerialization`.
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case let v as Bool: self = .bool(v)          // before Int: a Swift Bool is distinct
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map(JSONValue.init))
        case let v as [String: Any]: self = .object(v.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - OpenAI Chat Completions

struct OpenAIRequest: Encodable {
    let model: String
    let max_tokens: Int
    let reasoning_effort: String
    let messages: [Message]
    let response_format: ResponseFormat?

    struct Message: Encodable { let role: String; let content: String }
    struct ResponseFormat: Encodable { let type: String }
}

struct OpenAIResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        let finish_reason: String?
    }
    struct Message: Decodable {
        let content: String?
        // Chain-of-thought. Decoded so the wire shape is documented, but it is
        // the model's *thinking*, never the answer — must NOT be surfaced as the
        // reply (doing so leaked "（王哥又在喊我...）"-style monologue into the
        // bubble). Locked by the `wire.openai_reasoning_not_leaked` selftest.
        let reasoning_content: String?
        let reasoning: String?
    }

    /// Decode + extract the visible answer (`content` only) into an `LLMReply`,
    /// or throw the specific `LLMError`. `reasoning_content` is deliberately
    /// ignored — it's the model's chain-of-thought, not the answer. Empty
    /// content with `finish_reason == length` means the reasoning budget was
    /// exhausted before any output (raise max_tokens); otherwise it's a plain
    /// empty reply (retriable). Pure & offline-testable.
    static func reply(from data: Data) throws -> LLMReply {
        guard let resp = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
              let choice = resp.choices.first else {
            throw LLMError.malformed(String(data: data, encoding: .utf8) ?? "")
        }
        let text = choice.message.content ?? ""
        let stop = choice.finish_reason ?? "unknown"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if stop == "length" {
                throw LLMError.malformed("truncated: reasoning consumed the token budget before any output (raise max_tokens)")
            }
            throw LLMError.empty("finish_reason=\(stop)")
        }
        return LLMReply(text: text)
    }
}

/// The relay rejects `response_format: json_object` unless the prompt contains
/// the literal word "json". `SchemaHint` currently satisfies this, but that's an
/// implicit dependency — guarantee it in code so a reworded hint can never
/// silently start returning 400s.
enum OpenAIJSONGuard {
    static func ensureJSONMentioned(_ system: String) -> String {
        system.range(of: "json", options: .caseInsensitive) != nil
            ? system
            : system + "\n(Respond with a single JSON object.)"
    }
}

// MARK: - Anthropic Messages

struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: [SystemBlock]?
    let messages: [Message]
    let output_config: OutputConfig?

    struct Message: Encodable { let role: String; let content: String }
    struct SystemBlock: Encodable {
        let type: String
        let text: String
        let cache_control: CacheControl
        init(text: String) { self.type = "text"; self.text = text; self.cache_control = CacheControl() }
    }
    struct CacheControl: Encodable {
        let type: String
        init() { self.type = "ephemeral" }
    }
    struct OutputConfig: Encodable {
        let format: Format
        init(schema: JSONValue) { self.format = Format(type: "json_schema", schema: schema) }
        struct Format: Encodable { let type: String; let schema: JSONValue }
    }
}

/// Batch (`/v1/messages/batches`) — one request wrapped in the batch envelope.
struct AnthropicBatchRequest: Encodable {
    let requests: [Item]
    struct Item: Encodable {
        let custom_id: String
        let params: AnthropicRequest
    }
}

struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    let stop_reason: String?
    struct ContentBlock: Decodable { let type: String; let text: String? }

    /// Decode + join text blocks into an `LLMReply`, or throw. Pure & testable.
    static func reply(from data: Data) throws -> LLMReply {
        guard let resp = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
            throw LLMError.malformed(String(data: data, encoding: .utf8) ?? "")
        }
        let text = resp.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.empty("stop_reason=\(resp.stop_reason ?? "unknown")")
        }
        return LLMReply(text: text)
    }
}

struct AnthropicBatchResponse: Decodable {
    let id: String
    let processing_status: String?
    let status: String?
    let results_url: String?
    let result_url: String?

    var resolvedStatus: String { processing_status ?? status ?? "unknown" }
    var resolvedResultURL: String? { results_url ?? result_url }
}
