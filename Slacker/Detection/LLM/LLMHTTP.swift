import Foundation

/// Shared POST-JSON helper for HTTP LLM providers. Reuses the `HTTPTransport` seam so
/// every provider is unit-testable with a stub transport (no real network).
enum LLMHTTP {
    static func postJSON(
        transport: HTTPTransport,
        url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode)
        }
        return data
    }

    /// Decode JSON, mapping failure to `LLMError.decoding`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LLMError.decoding
        }
    }
}
