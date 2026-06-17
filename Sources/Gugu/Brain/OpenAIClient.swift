import Foundation

/// OpenAI Chat Completions client for OpenAI-compatible vendors (DeepSeek's own
/// API, local Ollama, SiliconFlow, etc.). Opt-in via `api.provider: openai`.
///
/// Structured output uses the broadly-supported `response_format: json_object`
/// plus a schema description appended to the system prompt (see `SchemaHint`),
/// rather than `json_schema` which many compatible endpoints reject. The reply
/// is parsed leniently by the same `Brain.extractJSON` used for Anthropic.
@MainActor
struct OpenAIClient: LLMClient {
    let baseURL: String
    let apiKey: String

    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil,
        retries: Int = 2
    ) async throws -> LLMReply {
        // Build system text: persona + (when structured) a schema instruction.
        var systemText = system
        if let schema {
            let hint = SchemaHint.describe(schema)
            systemText = (system.map { $0 + "\n\n" } ?? "") + hint
        }

        var chatMessages: [[String: Any]] = []
        if let systemText {
            chatMessages.append(["role": "system", "content": systemText])
        }
        for m in messages {
            let role = (m["role"] as? String) ?? "user"
            chatMessages.append(["role": role, "content": Self.flatten(m["content"])])
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.budgetWithReasoningHeadroom(maxTokens),
            "messages": chatMessages,
        ]
        // Reasoning models (e.g. deepseek-v4) spend completion tokens on hidden
        // reasoning before emitting content. Nudge it lower so more of the
        // budget reaches the actual answer; the headroom above is the real fix.
        body["reasoning_effort"] = "low"
        if schema != nil {
            body["response_format"] = ["type": "json_object"]
        }

        var attempt = 0
        while true {
            do {
                return try await doRequest(body: body, model: model)
            } catch let e as LLMError {
                if LLMRetry.isRetriable(e), attempt < retries {
                    attempt += 1
                    let delay = LLMRetry.backoffSeconds(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw e
            }
        }
    }

    /// Reasoning models burn completion tokens on hidden reasoning before any
    /// visible output, sharing the single `max_tokens` budget. The caller's
    /// `max_tokens` expresses *desired visible output*; we add headroom so
    /// reasoning doesn't starve the answer and truncate the JSON.
    ///
    /// Reasoning cost is largely independent of the requested output length and
    /// high-variance: measured deepseek-v4 (taas.hk, reasoning_effort=low) peaks
    /// observed at ~550 tokens with occasional higher spikes. A flat 1024-token
    /// floor (≈2× the observed peak) clears truncation across all tiers; we also
    /// keep "at least double" so unusually large output requests scale too.
    /// Per the stability-first choice, this trades extra tokens for reliability.
    static func budgetWithReasoningHeadroom(_ requested: Int) -> Int {
        requested + max(1024, requested)
    }

    /// Anthropic content may be a plain string or an array of typed blocks.
    /// OpenAI wants a single string, so join any text blocks.
    static func flatten(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    private func doRequest(body: [String: Any], model: String) async throws -> LLMReply {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, code) = try await LLMTransport.send(req, label: "openai \(model)")
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw LLMError.malformed(bodyText)
        }
        let message = first["message"] as? [String: Any]
        let text = (message?["content"] as? String) ?? ""
        let stop = (first["finish_reason"] as? String) ?? "unknown"
        // A reasoning model that ran out of budget mid-thought returns
        // finish_reason "length" with empty/partial content. Surface that
        // distinctly so it's diagnosable (and not mistaken for a model refusal).
        if stop == "length" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.malformed("truncated: reasoning consumed the token budget before any output (raise max_tokens)")
        }
        return LLMReply(text: text, stopReason: stop)
    }
}
