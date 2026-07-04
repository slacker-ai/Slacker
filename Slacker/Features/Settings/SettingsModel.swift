import Foundation
import Observation
import GRDB

/// Loads and persists user settings (§8.5): watched channels + sensitivity, staleness
/// threshold, LLM provider/model + key (Keychain), endpoint/CLI overrides.
@MainActor
@Observable
final class SettingsModel {
    private let database: AppDatabase

    var settings: AppSettings
    var apiKey: String
    var channels: [Channel] = []
    var workspaces: [Workspace] = []
    var savedConfirmation = false

    /// Non-nil while the "Add workspace" sheet is presented.
    var addWorkspaceModel: OnboardingModel?
    /// Whether the "Add channel" sheet is presented.
    var isShowingAddChannel = false

    /// Review screen for self-evolving learned patterns (§7.5). Stable instance so its
    /// state survives Settings re-renders.
    let learnedPatternsModel: LearnedPatternsModel

    var pendingEvolutionUpdateCount: Int {
        learnedPatternsModel.pendingProposalCount
    }

    /// Re-fetches the channel list from Slack (wired by `AppRoot`). Adds channels the
    /// user has joined since onboarding.
    @ObservationIgnored var onRefreshChannels: (() async -> Void)?
    var isRefreshingChannels = false

    init(database: AppDatabase) {
        self.database = database
        self.settings = (try? database.dbWriter.read { try AppSettings.fetchOne($0, key: 1) })
            .flatMap { $0 } ?? AppSettings()
        self.apiKey = ((try? KeychainStore.get(.llmAPIKey)) ?? nil) ?? ""
        self.learnedPatternsModel = LearnedPatternsModel(database: database)
    }

    func load() async {
        channels = (try? await database.dbWriter.read { db in
            try Channel.order(Column("name")).fetchAll(db)
        }) ?? []
        workspaces = (try? await database.dbWriter.read { db in
            try Workspace.order(Column("name")).fetchAll(db)
        }) ?? []
        await learnedPatternsModel.load()
    }

    /// Watched channels in a workspace (the "manage" list).
    func watchedChannels(for workspaceID: String) -> [Channel] {
        channels.filter { $0.workspaceID == workspaceID && $0.isWatched }
    }

    /// Member channels in a workspace not yet watched (the "add" list).
    func unwatchedChannels(for workspaceID: String) -> [Channel] {
        channels.filter { $0.workspaceID == workspaceID && !$0.isWatched }
    }

    /// Start watching a channel (used by the Add-channel sheet).
    func addChannel(_ channel: Channel) {
        guard !channel.isWatched else { return }
        toggleWatched(channel)
    }

    var hasUnwatchedChannels: Bool { channels.contains { !$0.isWatched } }

    // MARK: - Workspaces

    /// Begin the add-workspace flow (presented as a sheet). Reuses the onboarding wizard
    /// in add-workspace mode (no LLM step).
    func startAddWorkspace() {
        let service = SlackConnectionService(client: SlackClient(), database: database)
        let model = OnboardingModel(service: service, mode: .addWorkspace)
        model.onFinished = { [weak self] in
            self?.addWorkspaceModel = nil
            Task { await self?.load() }
        }
        addWorkspaceModel = model
    }

    func cancelAddWorkspace() { addWorkspaceModel = nil }

    /// Remove a workspace and everything under it (token + channels + messages/items).
    func removeWorkspace(_ workspace: Workspace) {
        let service = SlackConnectionService(client: SlackClient(), database: database)
        try? service.removeWorkspace(workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        channels.removeAll { $0.workspaceID == workspace.id }
    }

    func toggleWatched(_ channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        var updated = channels[index]
        updated.isWatched.toggle()
        channels[index] = updated
        persistChannel(updated)
    }

    func setSensitivity(_ sensitivity: ChannelSensitivity, for channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        var updated = channels[index]
        updated.sensitivity = sensitivity
        channels[index] = updated
        persistChannel(updated)
    }

    func save() {
        try? database.dbWriter.write { db in
            try settings.update(db)
        }
        // Empty key clears the stored secret; otherwise upsert it.
        if apiKey.isEmpty {
            try? KeychainStore.delete(.llmAPIKey)
        } else {
            try? KeychainStore.set(apiKey, for: .llmAPIKey)
        }
        savedConfirmation = true
    }

    /// Pull the latest channel list from Slack, then reload.
    func refreshChannels() async {
        guard let onRefreshChannels, !isRefreshingChannels else { return }
        isRefreshingChannels = true
        await onRefreshChannels()
        await load()
        isRefreshingChannels = false
    }

    /// Remove a channel entirely (its messages/items cascade). Use for channels you've
    /// left or don't want tracked; a Refresh re-adds it if you're still a member.
    func removeChannel(_ channel: Channel) {
        try? database.dbWriter.write { db in
            _ = try Channel.deleteOne(db, key: channel.id)
        }
        channels.removeAll { $0.id == channel.id }
    }

    private func persistChannel(_ channel: Channel) {
        try? database.dbWriter.write { db in
            try channel.update(db)
        }
    }
}
