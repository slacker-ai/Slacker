import Foundation

/// Local Llama via Ollama's chat endpoint (`.ollama`). No API key; localhost only.
struct OllamaClient: LLMClient {
    let transport: HTTPTransport
    let baseURL: URL
    let model: String

    init(transport: HTTPTransport, model: String,
         baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.transport = transport
        self.model = model
        self.baseURL = baseURL
    }

    func complete(_ request: LLMRequest) async throws -> String {
        guard !model.isEmpty else { throw LLMError.notConfigured }

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": request.temperature],
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]

        let data = try await LLMHTTP.postJSON(
            transport: transport,
            url: baseURL.appendingPathComponent("api/chat"),
            headers: [:],
            body: body
        )

        let decoded = try LLMHTTP.decode(Response.self, from: data)
        guard let text = decoded.message?.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }

    private struct Response: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
    }
}
