import XCTest
@testable import Slacker

final class SlackClientTests: XCTestCase {

    private func client(_ transport: StubTransport, maxRetries: Int = 3) -> SlackClient {
        // No-op sleep so retry tests don't actually wait.
        SlackClient(transport: transport, maxRetries: maxRetries, sleep: { _ in })
    }

    func testAuthTestSuccessParsesTeamAndUser() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"ok":true,"team":"Acme","user":"daanish","team_id":"T1","user_id":"U1"}"#),
             makeHTTPResponse(200))
        }
        let auth = try await client(transport).authTest(token: "xoxp-good")
        XCTAssertEqual(auth.team, "Acme")
        XCTAssertEqual(auth.userId, "U1")
    }

    func testAuthTestFailureThrowsAPIError() async {
        let transport = StubTransport { _ in
            (jsonData(#"{"ok":false,"error":"invalid_auth"}"#), makeHTTPResponse(200))
        }
        do {
            _ = try await client(transport).authTest(token: "xoxp-bad")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SlackClientError, .api("invalid_auth"))
        }
    }

    func testTokenSentAsBearerHeader() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"ok":true}"#), makeHTTPResponse(200))
        }
        _ = try await client(transport).authTest(token: "xoxp-secret")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer xoxp-secret")
    }

    func testConversationsListPaginatesAndFiltersNonMembers() async throws {
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("cursor=page2") {
                return (jsonData(#"""
                {"ok":true,"channels":[
                  {"id":"C2","name":"random","is_private":false,"is_member":true}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"""
            {"ok":true,"channels":[
              {"id":"C1","name":"general","is_private":false,"is_member":true},
              {"id":"C9","name":"not-a-member","is_private":false,"is_member":false}
            ],"response_metadata":{"next_cursor":"page2"}}
            """#), makeHTTPResponse(200))
        }

        let channels = try await client(transport).listConversations(token: "t", includePrivate: false)
        XCTAssertEqual(channels.map(\.id), ["C1", "C2"])
        XCTAssertEqual(transport.requestCount, 2, "should follow the cursor for a second page")
    }

    func testIncludePrivateAddsPrivateChannelType() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}"#),
             makeHTTPResponse(200))
        }
        _ = try await client(transport).listConversations(token: "t", includePrivate: true)
        let url = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("private_channel"), "private manifest must request private_channel type")
    }

    func testRetriesOn429ThenSucceeds() async throws {
        let attempts = Counter()
        let transport = StubTransport { _ in
            if attempts.next() == 0 {
                return (jsonData(#"{"ok":false}"#), makeHTTPResponse(429, headers: ["Retry-After": "0"]))
            }
            return (jsonData(#"{"ok":true,"team":"Acme"}"#), makeHTTPResponse(200))
        }
        let auth = try await client(transport).authTest(token: "t")
        XCTAssertEqual(auth.team, "Acme")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testRateLimitedAfterExhaustingRetries() async {
        let transport = StubTransport { _ in
            (jsonData(#"{"ok":false}"#), makeHTTPResponse(429, headers: ["Retry-After": "0"]))
        }
        do {
            _ = try await client(transport, maxRetries: 2).authTest(token: "t")
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? SlackClientError, .rateLimited)
        }
    }
}

/// Tiny thread-safe counter for stub state.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
