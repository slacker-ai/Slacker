import Foundation
import Observation
import AppKit

/// View-state coordinator for the onboarding flow (§5.2).
/// Owns the step machine and delegates real work to `SlackConnectionService`.
@MainActor
@Observable
final class OnboardingModel {
    enum Step {
        case intro
        case manifestChoice
        case createAndInstall
        case pasteToken
        case channels
        case llm
    }

    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
    }

    /// First-run sets up the app (incl. LLM); add-workspace just connects another workspace.
    enum Mode { case firstRun, addWorkspace }

    private let service: SlackConnectionService
    let mode: Mode

    var step: Step = .intro
    var phase: Phase = .idle

    var selectedVariant: ManifestVariant = .publicAndPrivate
    var tokenInput: String = ""

    // LLM selection (final onboarding step).
    var llmProvider: LLMProvider = .anthropic {
        didSet { syncDefaultModelForProvider() }
    }
    var llmModel: String = LLMClientFactory.defaultModel(for: .anthropic)
    var llmAPIKey: String = ""
    var llmBaseURL: String = ""
    var cliPath: String = ""

    /// Whether the selected provider needs an API key entered.
    var llmNeedsAPIKey: Bool {
        switch llmProvider {
        case .ollama, .codexCLI, .claudeCode: return false
        default: return true
        }
    }
    /// Whether the selected provider needs a custom endpoint URL.
    var llmNeedsEndpoint: Bool {
        llmProvider == .genericAPI || llmProvider == .ollama
    }
    /// Whether the selected provider is a CLI/subprocess backend.
    var llmIsCLI: Bool {
        llmProvider == .codexCLI || llmProvider == .claudeCode
    }

    var connection: SlackConnectionService.Connection?
    var channels: [Channel] = []

    /// Called when the user finishes onboarding so the app can advance to the main UI.
    var onFinished: () -> Void = {}

    init(service: SlackConnectionService, mode: Mode = .firstRun) {
        self.service = service
        self.mode = mode
        // Adding a workspace skips the welcome intro.
        if mode == .addWorkspace { step = .manifestChoice }
    }

    // MARK: - Navigation

    func advance(to step: Step) {
        phase = .idle
        self.step = step
    }

    private func syncDefaultModelForProvider() {
        let current = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownDefaults = Set(LLMProvider.allCases.map { LLMClientFactory.defaultModel(for: $0) })
        guard current.isEmpty || knownDefaults.contains(current) else { return }
        llmModel = LLMClientFactory.defaultModel(for: llmProvider)
    }

    // MARK: - Manifest

    /// Copy the chosen manifest JSON to the clipboard for pasting into Slack.
    func copyManifestToClipboard() {
        guard let json = try? SlackManifest.json(for: selectedVariant) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
    }

    func openSlackAppCreatePage() {
        if let url = URL(string: "https://api.slack.com/apps?new_app=1") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Connect

    func validateTokenAndLoadChannels() async {
        phase = .working
        do {
            let connection = try await service.connect(token: tokenInput)
            self.connection = connection
            try service.upsertWorkspace(connection, variant: selectedVariant)
            let loaded = try await service.refreshChannels(
                token: tokenInput.trimmingCharacters(in: .whitespacesAndNewlines),
                variant: selectedVariant,
                workspaceID: connection.teamID
            )
            self.channels = loaded
            phase = .idle
            step = .channels
        } catch {
            phase = .failed(OnboardingError.message(for: error))
        }
    }

    // MARK: - Channels

    func toggleWatched(_ channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        let newValue = !channels[index].isWatched
        // Immutable update of the local array element.
        var updated = channels[index]
        updated.isWatched = newValue
        channels[index] = updated
        try? service.setWatched(newValue, channelID: channel.id)
    }

    var watchedCount: Int { channels.filter(\.isWatched).count }

    func finish() {
        // The workspace + channels are already persisted (during connect). First-run
        // additionally records the global LLM choice and marks onboarding complete.
        if mode == .firstRun {
            let llm = SlackConnectionService.LLMConfig(
                provider: llmProvider,
                model: llmModel,
                baseURL: llmBaseURL,
                cliPath: cliPath,
                apiKey: llmAPIKey
            )
            try? service.completeOnboarding(llm: llm)
        }
        onFinished()
    }
}
