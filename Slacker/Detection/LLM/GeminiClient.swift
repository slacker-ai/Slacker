import Foundation

/// Google Gemini `generateContent` (`.gemini`). The API key is a query parameter.
struct GeminiClient: LLMClient {
    let transport: HTTPTransport
    let baseURL: URL
    let apiKey: String
    let model: String

    init(transport: HTTPTransport, apiKey: String, model: String,
         baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!) {
        self.transport = transport
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    func complete(_ request: LLMRequest) async throws -> String {
        guard !model.isEmpty, !apiKey.isEmpty else { throw LLMError.notConfigured }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1beta/models/\(model):generateContent"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": request.system]]],
            "contents": [["role": "user", "parts": [["text": request.user]]]],
            "generationConfig": [
                "temperature": request.temperature,
                "maxOutputTokens": request.maxTokens,
            ],
        ]

        let data = try await LLMHTTP.postJSON(
            transport: transport,
            url: components.url!,
            headers: [:],
            body: body
        )

        let decoded = try LLMHTTP.decode(Response.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.first?.text, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }

    private struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
    }
}
