import Foundation

/// Errors from any LLM backend (HTTP or CLI).
enum LLMError: Error, Equatable {
    case notConfigured          // missing key / model
    case http(Int)
    case decoding
    case emptyResponse
    case provider(String)       // provider-reported error message
    case cliNotFound(String)    // binary couldn't be located
    case cliFailed(String)      // subprocess exited non-zero
}

/// One completion request. Temperature defaults to 0 for deterministic classification.
struct LLMRequest: Equatable {
    let system: String
    let user: String
    var maxTokens: Int = 512
    var temperature: Double = 0
}

/// Provider-agnostic completion interface (§9). HTTP and CLI backends both conform.
/// The same abstraction serves ambiguous-message classification and daily summaries.
protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> String
}
