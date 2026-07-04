import Foundation
import GRDB

/// Which Slack app manifest the user installed (§5.1, §6c).
enum ManifestVariant: String, Codable, CaseIterable {
    /// Reads the manager's own public AND private channels (5 user-token scopes).
    case publicAndPrivate
    /// Public channels only (3 user-token scopes) — trust-sensitive opt-out.
    case publicOnly
}

/// LLM backend (expanded beyond spec §9 per project decision).
/// HTTP-key providers and CLI/subprocess backends share one `LLMClient` protocol (M4).
enum LLMProvider: String, Codable, CaseIterable {
    case openAI
    case anthropic
    case gemini
    /// Generic OpenAI-compatible HTTP endpoint (BYO base URL).
    case genericAPI
    /// Local Llama via Ollama (localhost).
    case ollama
    /// OpenAI Codex CLI (subprocess).
    case codexCLI
    /// Claude Code subscription (subprocess).
    case claudeCode
}

/// Single-row application configuration, persisted in SQLite (`docs/IMPLEMENTATION.md` §4).
/// Secrets are NOT stored here — only in the Keychain (see `KeychainStore`).
struct AppSettings: Codable, Equatable {
    /// Fixed primary key — there is always exactly one settings row.
    var id: Int64 = 1

    /// Staleness threshold in hours. Default 48h (§11 decision).
    var stalenessHours: Int = 48

    /// Polling cadence in seconds. Default 180s (3 min), within internal-app rate limits (§6.4).
    var pollIntervalSeconds: Int = 180

    /// Minimum cadence for regenerating daily channel summaries when new activity arrives.
    /// Kept separate from polling so Refresh does not spend LLM calls every cycle.
    var summaryRefreshIntervalMinutes: Int = 360

    /// Selected install manifest. Chosen during onboarding, not silently defaulted (§5.2).
    var manifestVariant: ManifestVariant = .publicAndPrivate

    /// Selected LLM backend + model.
    var llmProvider: LLMProvider = .anthropic
    var llmModel: String = ""
    /// Custom endpoint for the generic-API and Ollama providers (empty = provider default).
    var llmBaseURL: String = ""
    /// Optional explicit path to the CLI binary (Codex / Claude Code); empty = auto-detect.
    var cliPathOverride: String = ""

    /// Whether the user has completed onboarding (token validated + channels picked).
    var onboardingCompleted: Bool = false

    /// Slack workspace id, captured at connect time — used to build `slack://` deep links.
    var teamID: String = ""
}

// MARK: - GRDB persistence

extension AppSettings: FetchableRecord, PersistableRecord {
    static let databaseTableName = "appSettings"

    /// Load the single settings row, creating it with defaults if it does not exist yet.
    static func loadOrCreate(_ db: Database) throws -> AppSettings {
        if let existing = try AppSettings.fetchOne(db, key: 1) {
            return existing
        }
        let fresh = AppSettings()
        try fresh.insert(db)
        return fresh
    }
}
