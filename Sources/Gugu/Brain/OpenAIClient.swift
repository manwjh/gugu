import Foundation
import GuguKernel

/// OpenAI Chat Completions client for OpenAI-compatible vendors (DeepSeek's own
/// API, local Ollama, SiliconFlow, etc.). The factory default (`api.provider:
/// openai`). Structured output uses the broadly-supported `response_format:
/// json_object` plus a schema description appended to the system prompt (see
/// `SchemaHint`), rather than `json_schema` which many compatible endpoints
/// reject. Wire models live in `LLMWire.swift`; parsing is the testable
/// `OpenAIResponse.reply(from:)`.
@MainActor
struct OpenAIClient {
    let baseURL: String
    let apiKey: String

    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil,
        policy: LLMCallPolicy = .chat
    ) async throws -> LLMReply {
        // System text: persona + (when structured) a schema instruction.
        var systemText = system
        if let schema {
            let hint = SchemaHint.describe(schema)
            systemText = (system.map { $0 + "\n\n" } ?? "") + hint
        }
        // json_object mode requires the literal word "json" in the prompt — guarantee it.
        if schema != nil, let s = systemText {
            systemText = OpenAIJSONGuard.ensureJSONMentioned(s)
        }

        var chatMessages: [OpenAIRequest.Message] = []
        if let systemText {
            chatMessages.append(.init(role: "system", content: systemText))
        }
        for m in messages {
            chatMessages.append(.init(role: (m["role"] as? String) ?? "user",
                                      content: Self.flatten(m["content"])))
        }

        let request = OpenAIRequest(
            model: model,
            // Reasoning models burn completion tokens on hidden reasoning before
            // any visible output; pad the budget so the answer isn't truncated.
            max_tokens: Self.budgetWithReasoningHeadroom(maxTokens),
            // Nudge reasoning lower so more of the budget reaches the answer.
            reasoning_effort: "low",
            messages: chatMessages,
            response_format: schema != nil ? .init(type: "json_object") : nil
        )

        return try await LLMRetry.run(policy: policy) {
            try await doRequest(request, model: model, timeout: policy.timeout)
        }
    }

    /// Reasoning models burn completion tokens on hidden reasoning before any
    /// visible output, sharing the single `max_tokens` budget. The caller's
    /// `max_tokens` expresses *desired visible output*; we add headroom so
    /// reasoning doesn't starve the answer and truncate the JSON. Measured
    /// deepseek-v4 (taas.hk, reasoning_effort=low) peaks ~550 reasoning tokens;
    /// a 1024 floor (≈2× peak) clears truncation, "at least double" scales large
    /// requests too. Trades extra tokens for reliability.
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

    private func doRequest(_ request: OpenAIRequest, model: String, timeout: TimeInterval) async throws -> LLMReply {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(request)

        let (data, code) = try await LLMTransport.send(req, label: "openai \(model)")
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try OpenAIResponse.reply(from: data)
    }
}
