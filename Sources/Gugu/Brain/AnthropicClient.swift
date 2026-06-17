import Foundation

/// Minimal Anthropic Messages API client over URLSession (no SDK for Swift).
/// Works against the relay channel (Anthropic-compatible shape). Default provider.
@MainActor
struct AnthropicClient: LLMClient {
    let baseURL: String
    let apiKey: String

    struct Batch: Sendable {
        let id: String
        let processingStatus: String
        let resultURL: String?
    }

    /// One messages.create call. `system` may carry cache_control.
    /// `schema` (optional) forces structured JSON output.
    func create(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil,
        retries: Int = 2
    ) async throws -> LLMReply {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let system {
            body["system"] = [["type": "text", "text": system,
                               "cache_control": ["type": "ephemeral"]]]
        }
        if let schema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }

        var attempt = 0
        while true {
            do {
                return try await doRequest(body: body)
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

    private func doRequest(body: [String: Any]) async throws -> LLMReply {
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, code) = try await LLMTransport.send(req, label: "anthropic \(body["model"] as? String ?? "")")
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.malformed(bodyText)
        }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        let stop = obj["stop_reason"] as? String ?? "unknown"
        return LLMReply(text: text, stopReason: stop)
    }

    func createMessageBatch(
        customID: String,
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [[String: Any]],
        schema: [String: Any]? = nil
    ) async throws -> Batch {
        var params: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let system {
            params["system"] = [["type": "text", "text": system,
                                 "cache_control": ["type": "ephemeral"]]]
        }
        if let schema {
            params["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        let body: [String: Any] = [
            "requests": [[
                "custom_id": customID,
                "params": params,
            ]],
        ]
        return try await doBatchRequest(method: "POST", path: "/v1/messages/batches", body: body)
    }

    func retrieveMessageBatch(id: String) async throws -> Batch {
        try await doBatchRequest(method: "GET", path: "/v1/messages/batches/\(id)", body: nil)
    }

    func downloadBatchResults(from resultURL: String) async throws -> String {
        guard let url = URL(string: resultURL) else {
            throw LLMError.malformed("bad result url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await LLMTransport.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        return bodyText
    }

    private func doBatchRequest(method: String, path: String, body: [String: Any]?) async throws -> Batch {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw LLMError.malformed("bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await LLMTransport.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, bodyText)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw LLMError.malformed(bodyText)
        }
        let status = obj["processing_status"] as? String
            ?? obj["status"] as? String
            ?? "unknown"
        let resultURL = obj["results_url"] as? String
            ?? obj["result_url"] as? String
        return Batch(id: id, processingStatus: status, resultURL: resultURL)
    }
}
