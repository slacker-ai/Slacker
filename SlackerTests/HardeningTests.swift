import XCTest
@testable import Slacker

final class SecretRedactionTests: XCTestCase {
    func testRedactsSlackToken() {
        let out = SecretRedaction.redact("token is xoxp-123-abc-DEF456 ok")
        XCTAssertFalse(out.contains("xoxp-123-abc-DEF456"))
        XCTAssertTrue(out.contains("‹redacted›"))
    }

    func testRedactsOpenAIKey() {
        let out = SecretRedaction.redact("key=sk-abcdEFGH1234567890")
        XCTAssertFalse(out.contains("sk-abcdEFGH1234567890"))
    }

    func testRedactsBearerHeader() {
        let out = SecretRedaction.redact("Authorization: Bearer xoxp-secret-value")
        XCTAssertFalse(out.contains("xoxp-secret-value"))
    }

    func testLeavesOrdinaryTextAlone() {
        XCTAssertEqual(SecretRedaction.redact("nothing secret here"), "nothing secret here")
    }
}

/// No-egress guard (§3): all Slack traffic must target slack.com and nothing else.
/// Every network call in the app goes through `HTTPTransport`, so recording the hosts
/// a full poll cycle hits proves there is no stray egress.
final class NoEgressTests: XCTestCase {
    func testSlackClientOnlyContactsSlackDotCom() async throws {
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[{"ts":"1.0","user":"U1","text":"hi","reply_count":1}],"response_metadata":{"next_cursor":""}}"#), makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                return (jsonData(#"{"ok":true,"messages":[{"ts":"1.0","user":"U1","text":"hi","thread_ts":"1.0"}],"response_metadata":{"next_cursor":""}}"#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        let service = IngestionService(
            client: SlackClient(transport: transport, sleep: { _ in }), database: db
        )

        try await service.pollWorkspace(workspaceID: "T1", token: "xoxp-test")

        let hosts = Set(transport.requests.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["slack.com"], "Slack ingestion must only contact slack.com")
    }

    func testLLMProvidersTargetExpectedHostsOnly() async throws {
        let recorded = Counter() // unused; keep structure simple
        _ = recorded

        let cases: [(LLMProvider, String)] = [
            (.anthropic, "api.anthropic.com"),
            (.openAI, "api.openai.com"),
            (.gemini, "generativelanguage.googleapis.com"),
        ]
        for (provider, expectedHost) in cases {
            let transport = StubTransport { _ in
                // Minimal valid bodies per provider.
                let body: String
                switch provider {
                case .anthropic: body = #"{"content":[{"type":"text","text":"x"}]}"#
                case .gemini: body = #"{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#
                default: body = #"{"choices":[{"message":{"content":"x"}}]}"#
                }
                return (jsonData(body), makeHTTPResponse(200))
            }
            var settings = AppSettings()
            settings.llmProvider = provider
            settings.llmModel = "m"
            let client = try LLMClientFactory.make(settings: settings, apiKey: "k", transport: transport)
            _ = try await client.complete(LLMRequest(system: "s", user: "u"))

            let hosts = Set(transport.requests.compactMap { $0.url?.host })
            XCTAssertEqual(hosts, [expectedHost], "\(provider) must only contact \(expectedHost)")
        }
    }
}

// NOTE: AppRoot is intentionally not unit-tested directly — constructing it opens the
// real on-disk DB and starts the live poller (real network/Keychain), which is slow and
// flaky in tests. The recoverable-DB fallback is verified manually. If this needs a test,
// first refactor AppRoot to inject its database + poller.
