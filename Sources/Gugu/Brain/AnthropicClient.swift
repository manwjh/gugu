import Foundation
import GuguKernel

/// Minimal Anthropic Messages API client over URLSession (no SDK for Swift).
/// Works against the relay channel (Anthropic-compatible shape). Selected by
/// `api.provider: anthropic`. Wire models live in `LLMWire.swift`; parsing is
/// the testable `AnthropicResponse.reply(from:)`. Also owns the batch path.
@MainActor
struct AnthropicClient: LLMClient {
    let baseURL: String
    let apiKey: String

    struct Batch: Sendable {
        let id: String
        let processingStatus: String
        let resultURL: String?
    }

    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil,
        policy: LLMCallPolicy = .chat
    ) async throws -> LLMReply {
        let request = Self.buildRequest(model: model, maxTokens: maxTokens,
                                        system: system, messages: messages, schema: schema)
        return try await LLMRetry.run(policy: policy) {
            try await doRequest(request, timeout: policy.timeout)
        }
    }

    /// Assemble a typed Messages request (shared by `create` and the batch path).
    static func buildRequest(model: String, maxTokens: Int, system: String?,
                             messages: [[String: Any]], schema: [String: Any]?) -> AnthropicRequest {
        AnthropicRequest(
            model: model,
            max_tokens: maxTokens,
            system: system.map { [AnthropicRequest.SystemBlock(text: $0)] },
            messages: messages.map {
                AnthropicRequest.Message(role: $0["role"] as? String ?? "user",
                                         content: $0["content"] as? String ?? "")
            },
            output_config: schema.map { AnthropicRequest.OutputConfig(schema: JSONValue($0)) }
        )
    }

    private func doRequest(_ request: AnthropicRequest, timeout: TimeInterval) async throws -> LLMReply {
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(request)

        let (data, code) = try await LLMTransport.send(req, label: "anthropic \(request.model)")
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try AnthropicResponse.reply(from: data)
    }

    // MARK: - Batch

    func createMessageBatch(
        customID: String,
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil
    ) async throws -> Batch {
        let params = Self.buildRequest(model: model, maxTokens: maxTokens,
                                       system: system, messages: messages, schema: schema)
        let body = AnthropicBatchRequest(requests: [.init(custom_id: customID, params: params)])
        return try await doBatchRequest(method: "POST", path: "/v1/messages/batches",
                                        body: try JSONEncoder().encode(body))
    }

    func retrieveMessageBatch(id: String) async throws -> Batch {
        try await doBatchRequest(method: "GET", path: "/v1/messages/batches/\(id)", body: nil)
    }

    func downloadBatchResults(from resultURL: String) async throws -> String {
        guard let url = URL(string: resultURL) else {
            throw LLMError.malformed("bad result url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = LLMCallPolicy.dream.timeout
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, code) = try await LLMTransport.send(req, label: "anthropic batch results")
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        return bodyText
    }

    private func doBatchRequest(method: String, path: String, body: Data?) async throws -> Batch {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = LLMCallPolicy.dream.timeout
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = body

        let (data, code) = try await LLMTransport.send(req, label: "anthropic batch \(method)")
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        guard let resp = try? JSONDecoder().decode(AnthropicBatchResponse.self, from: data) else {
            throw LLMError.malformed(bodyText)
        }
        return Batch(id: resp.id, processingStatus: resp.resolvedStatus, resultURL: resp.resolvedResultURL)
    }
}
