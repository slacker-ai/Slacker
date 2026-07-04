import Foundation
@testable import Slacker

/// Closure-based `HTTPTransport` stub for tests — no real network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    /// Inspect the request and return a canned (Data, HTTPURLResponse).
    let handler: @Sendable (URLRequest) -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return handler(request)
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }
}

func makeHTTPResponse(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://slack.com/api/test")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    )!
}

func jsonData(_ string: String) -> Data { Data(string.utf8) }
