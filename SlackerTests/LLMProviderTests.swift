import XCTest
@testable import Slacker

final class LLMProviderTests: XCTestCase {
    private let req = LLMRequest(system: "sys", user: "classify this")

    func testOpenAICompatibleParsesContent() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"choices":[{"message":{"content":"{\"class\":\"openQuestion\"}"}}]}"#),
             makeHTTPResponse(200))
        }
        let client = OpenAICompatibleClient(
            transport: transport,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "k", model: "gpt-x"
        )
        let out = try await client.complete(req)
        XCTAssertEqual(out, #"{"class":"openQuestion"}"#)
        // Hits the chat/completions path with a bearer token.
        XCTAssertTrue(transport.requests.first?.url?.absoluteString.hasSuffix("/v1/chat/completions") ?? false)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testAnthropicParsesTextBlock() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"content":[{"type":"text","text":"hello"}]}"#), makeHTTPResponse(200))
        }
        let client = AnthropicClient(transport: transport, apiKey: "k", model: "claude-x")
        let out = try await client.complete(req)
        XCTAssertEqual(out, "hello")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testGeminiParsesCandidate() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"candidates":[{"content":{"parts":[{"text":"g-out"}]}}]}"#), makeHTTPResponse(200))
        }
        let client = GeminiClient(transport: transport, apiKey: "k", model: "gemini-x")
        let out = try await client.complete(req)
        XCTAssertEqual(out, "g-out")
        XCTAssertTrue(transport.requests.first?.url?.query?.contains("key=k") ?? false)
    }

    func testOllamaParsesMessage() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"message":{"content":"local-out"}}"#), makeHTTPResponse(200))
        }
        let client = OllamaClient(transport: transport, model: "llama3")
        let out = try await client.complete(req)
        XCTAssertEqual(out, "local-out")
    }

    func testHTTPErrorMapsToLLMError() async {
        let transport = StubTransport { _ in (jsonData("{}"), makeHTTPResponse(500)) }
        let client = OllamaClient(transport: transport, model: "llama3")
        do { _ = try await client.complete(req); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LLMError, .http(500)) }
    }

    func testEmptyContentThrowsEmptyResponse() async {
        let transport = StubTransport { _ in (jsonData(#"{"choices":[]}"#), makeHTTPResponse(200)) }
        let client = OpenAICompatibleClient(
            transport: transport, baseURL: URL(string: "https://x/v1")!, apiKey: "k", model: "m")
        do { _ = try await client.complete(req); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LLMError, .emptyResponse) }
    }

    func testOpenAICompatibleWithoutAPIKeyDoesNotSendRequest() async {
        let transport = StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }
        let client = OpenAICompatibleClient(
            transport: transport, baseURL: URL(string: "https://x/v1")!, apiKey: "", model: "m")
        do { _ = try await client.complete(req); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? LLMError, .notConfigured) }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

/// Captures the CLI invocation and returns canned stdout.
final class StubCLIRunner: CLIRunner, @unchecked Sendable {
    var output: String
    private(set) var executable: String?
    private(set) var arguments: [String] = []
    private(set) var stdin: String?

    init(output: String) { self.output = output }

    func run(executable: String, arguments: [String], stdin: String?) async throws -> String {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        return output
    }
}

final class CLILLMClientTests: XCTestCase {
    func testReturnsTrimmedStdout() async throws {
        let runner = StubCLIRunner(output: "  result\n")
        let client = CLILLMClient(runner: runner, executable: "/bin/echo") { _ in (["x"], nil) }
        let out = try await client.complete(LLMRequest(system: "", user: "hi"))
        XCTAssertEqual(out, "result")
    }

    func testEmptyOutputThrows() async {
        let runner = StubCLIRunner(output: "   ")
        let client = CLILLMClient(runner: runner, executable: "/bin/echo") { _ in ([], nil) }
        do { _ = try await client.complete(LLMRequest(system: "", user: "hi")); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, .emptyResponse) }
    }

    func testCombinedPromptJoinsSystemAndUser() {
        let p = CLILLMClient.combinedPrompt(LLMRequest(system: "S", user: "U"))
        XCTAssertEqual(p, "S\n\nU")
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testOverrideWinsWhenExecutable() {
        // /bin/sh exists and is executable on macOS.
        let path = BinaryLocator.locate("anything", override: "/bin/sh")
        XCTAssertEqual(path, "/bin/sh")
    }

    func testFindsInSearchDirs() {
        let path = BinaryLocator.locate("sh", override: nil, searchDirs: ["/bin"])
        XCTAssertEqual(path, "/bin/sh")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(BinaryLocator.locate("definitely-not-a-real-binary-xyz", override: nil, searchDirs: ["/bin"]))
    }
}

final class LLMClientFactoryTests: XCTestCase {
    private func settings(_ provider: LLMProvider, model: String = "m", cliOverride: String = "") -> AppSettings {
        var s = AppSettings()
        s.llmProvider = provider
        s.llmModel = model
        s.cliPathOverride = cliOverride
        return s
    }

    func testBuildsHTTPProviderThatCallsEndpoint() async throws {
        let transport = StubTransport { _ in
            (jsonData(#"{"content":[{"type":"text","text":"ok"}]}"#), makeHTTPResponse(200))
        }
        let client = try LLMClientFactory.make(
            settings: settings(.anthropic), apiKey: "k", transport: transport
        )
        _ = try await client.complete(LLMRequest(system: "s", user: "u"))
        XCTAssertTrue(transport.requests.first?.url?.absoluteString.contains("anthropic.com") ?? false)
    }

    func testHTTPProviderWithoutAPIKeyIsNotConfigured() {
        XCTAssertThrowsError(
            try LLMClientFactory.make(settings: settings(.anthropic), apiKey: "  ")
        ) { error in
            XCTAssertEqual(error as? LLMError, .notConfigured)
        }
    }

    func testCodexCLIInvokesExecWithCombinedPrompt() async throws {
        let runner = StubCLIRunner(output: "verdict")
        let client = try LLMClientFactory.make(
            settings: settings(.codexCLI, cliOverride: "/usr/local/bin/codex"),
            apiKey: nil,
            runner: runner,
            locate: { _, override in override }  // honor the override path
        )
        _ = try await client.complete(LLMRequest(system: "S", user: "U"))
        XCTAssertEqual(runner.executable, "/usr/local/bin/codex")
        XCTAssertEqual(runner.arguments, ["exec", "--skip-git-repo-check", "S\n\nU"])
    }

    func testClaudeCodeCLIPipesPromptToStdin() async throws {
        let runner = StubCLIRunner(output: "verdict")
        let client = try LLMClientFactory.make(
            settings: settings(.claudeCode, cliOverride: "/opt/homebrew/bin/claude"),
            apiKey: nil,
            runner: runner,
            locate: { _, override in override }
        )
        _ = try await client.complete(LLMRequest(system: "S", user: "U"))
        XCTAssertEqual(runner.arguments, ["-p"])
        XCTAssertEqual(runner.stdin, "S\n\nU")
    }

    func testCLINotFoundThrows() {
        XCTAssertThrowsError(
            try LLMClientFactory.make(
                settings: settings(.codexCLI), apiKey: nil,
                runner: StubCLIRunner(output: ""),
                locate: { _, _ in nil }  // not found
            )
        ) { error in
            XCTAssertEqual(error as? LLMClientFactory.FactoryError, .cliNotFound("codex"))
        }
    }
}
