import Foundation

/// OpenAI Chat Completions, and any OpenAI-compatible endpoint (the generic "API"
/// provider just supplies a different `baseURL`). Covers `.openAI` and `.genericAPI`.
struct OpenAICompatibleClient: LLMClient {
    let transport: HTTPTransport
    let baseURL: URL
    let apiKey: String
    let model: String

    func complete(_ request: LLMRequest) async throws -> String {
        guard !model.isEmpty, !apiKey.isEmpty else { throw LLMError.notConfigured }

        let body: [String: Any] = [
            "model": model,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]

        let data = try await LLMHTTP.postJSON(
            transport: transport,
            url: baseURL.appendingPathComponent("chat/completions"),
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: body
        )

        let decoded = try LLMHTTP.decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}
