import Foundation

/// LLM backend that shells out to a CLI tool (Codex CLI or Claude Code).
/// The argument/stdin shape is supplied by the factory so this type stays generic.
struct CLILLMClient: LLMClient {
    let runner: CLIRunner
    let executable: String
    /// Builds the invocation for a request: command args + optional stdin payload.
    let invocation: @Sendable (LLMRequest) -> (arguments: [String], stdin: String?)

    func complete(_ request: LLMRequest) async throws -> String {
        let (arguments, stdin) = invocation(request)
        let output = try await runner.run(executable: executable, arguments: arguments, stdin: stdin)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }

    /// Combine system + user into a single prompt for tools that take one prompt.
    static func combinedPrompt(_ request: LLMRequest) -> String {
        request.system.isEmpty ? request.user : "\(request.system)\n\n\(request.user)"
    }
}
