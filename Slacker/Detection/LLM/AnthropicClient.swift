import Foundation

/// Anthropic Messages API (`.anthropic`).
struct AnthropicClient: LLMClient {
    let transport: HTTPTransport
    let baseURL: URL
    let apiKey: String
    let model: String

    init(transport: HTTPTransport, apiKey: String, model: String,
         baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.transport = transport
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    func complete(_ request: LLMRequest) async throws -> String {
        guard !model.isEmpty, !apiKey.isEmpty else { throw LLMError.notConfigured }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]

        let data = try await LLMHTTP.postJSON(
            transport: transport,
            url: baseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: body
        )

        let decoded = try LLMHTTP.decode(Response.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }
}
