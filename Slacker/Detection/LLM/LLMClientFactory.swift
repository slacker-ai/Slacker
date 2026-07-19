import Foundation

/// Builds the configured `LLMClient` from settings + secrets (§9).
/// All providers share this single entry point; callers don't branch on provider.
enum LLMClientFactory {
    enum FactoryError: Error, Equatable {
        case cliNotFound(String)
    }

    static func make(
        settings: AppSettings,
        apiKey: String?,
        transport: HTTPTransport = URLSessionTransport(),
        runner: CLIRunner = ProcessCLIRunner(),
        locate: (_ name: String, _ override: String?) -> String? = { name, override in
            BinaryLocator.locate(name, override: override)
        }
    ) throws -> LLMClient {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A blank model would make HTTP providers fail (e.g. Anthropic 400). Fall back to
        // a sensible per-provider default so detection/summaries never silently no-op.
        let model = settings.llmModel.isEmpty ? defaultModel(for: settings.llmProvider) : settings.llmModel

        switch settings.llmProvider {
        case .openAI:
            guard !key.isEmpty else { throw LLMError.notConfigured }
            return OpenAICompatibleClient(
                transport: transport,
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: key,
                model: model
            )

        case .genericAPI:
            guard !key.isEmpty else { throw LLMError.notConfigured }
            let base = URL(string: settings.llmBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return OpenAICompatibleClient(transport: transport, baseURL: base, apiKey: key, model: model)

        case .anthropic:
            guard !key.isEmpty else { throw LLMError.notConfigured }
            return AnthropicClient(transport: transport, apiKey: key, model: model)

        case .gemini:
            guard !key.isEmpty else { throw LLMError.notConfigured }
            return GeminiClient(transport: transport, apiKey: key, model: model)

        case .ollama:
            if let base = URL(string: settings.llmBaseURL), !settings.llmBaseURL.isEmpty {
                return OllamaClient(transport: transport, model: model, baseURL: base)
            }
            return OllamaClient(transport: transport, model: model)

        case .codexCLI:
            let path = try resolve("codex", override: settings.cliPathOverride, locate: locate)
            return CLILLMClient(runner: runner, executable: path) { request in
                // Slacker needs only model output. Loading the user's Codex config would also
                // start their MCP servers, plugins, and notification hooks on every request.
                // Let Codex select its account-compatible default model; API model IDs such as
                // gpt-4o are not necessarily available through ChatGPT subscription auth.
                ([
                    "exec",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--disable", "shell_tool",
                    "--disable", "shell_snapshot",
                    "--ephemeral",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    "-",
                ], CLILLMClient.combinedPrompt(request))
            }

        case .claudeCode:
            let path = try resolve("claude", override: settings.cliPathOverride, locate: locate)
            return CLILLMClient(runner: runner, executable: path) { request in
                // `claude -p` reads the prompt from stdin and prints the response.
                (["-p"], CLILLMClient.combinedPrompt(request))
            }
        }
    }

    /// A reasonable default model per provider, used when the user hasn't picked one.
    static func defaultModel(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic, .claudeCode: return "claude-opus-4-8"
        case .openAI, .genericAPI: return "gpt-4o"
        case .codexCLI: return ""
        case .gemini: return "gemini-2.0-flash"
        case .ollama: return "llama3"
        }
    }

    private static func resolve(
        _ name: String,
        override: String,
        locate: (_ name: String, _ override: String?) -> String?
    ) throws -> String {
        guard let path = locate(name, override.isEmpty ? nil : override) else {
            throw FactoryError.cliNotFound(name)
        }
        return path
    }
}
