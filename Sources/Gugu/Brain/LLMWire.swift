import Foundation
import GuguKernel

/// Typed wire models for the OpenAI Chat Completions protocol. Replaces the old
/// `[String: Any]` + `JSONSerialization` request/response handling so request
/// construction and response parsing are compile-time checked and the trickiest
/// extraction logic (reasoning fallback / truncation / empty) lives in pure,
/// offline-testable functions rather than buried in the network method.
///
/// No SDK dependency: this is ~the part of a mature client worth having (typed
/// contract), hand-written to keep the zero-dependency posture.

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
