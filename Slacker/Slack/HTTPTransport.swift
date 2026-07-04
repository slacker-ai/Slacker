import Foundation

/// Minimal async HTTP transport seam so the Slack/LLM clients can be unit-tested
/// without real network access (inject a stub in tests).
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession` (§1 — no Alamofire).
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SlackClientError.nonHTTPResponse
        }
        return (data, http)
    }
}
