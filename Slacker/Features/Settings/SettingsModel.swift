import Foundation
import Observation
import GRDB

/// Loads and persists user settings (§8.5): watched channels + sensitivity, staleness
/// threshold, LLM provider/model + key (Keychain), endpoint/CLI overrides.
@MainActor
@Observable
final class SettingsModel {
    private let database: AppDatabase
    private let appTokenProvider: (_ workspaceID: String) -> String?
    private let storeAppToken: (_ token: String, _ workspaceID: String) throws -> Void
    private let validateAppToken: (_ token: String) async throws -> Void

    var settings: AppSettings
    var apiKey: String
    var channels: [Channel] = []
    var workspaces: [Workspace] = []
    /// App tokens are never loaded back into UI state. This dictionary contains only
    /// replacement values typed during the current Settings session.
    var appTokenInputs: [String: String] = [:]
    var socketStates: [String: SocketModeConnectionState] = [:]
    var savingAppTokenWorkspaceIDs = Set<String>()
    var autosaveStatus = "Autosaved"

    /// Non-nil while the "Add workspace" sheet is presented.
    var addWorkspaceModel: OnboardingModel?
    /// Whether the "Add channel" sheet is presented.
    var isShowingAddChannel = false

    /// Stable learned-prompt editor model so draft state survives Settings re-renders.
    let learnedPatternsModel: LearnedPatternsModel

    /// Re-fetches the channel list from Slack (wired by `AppRoot`). Adds channels the
    /// user has joined since onboarding.
    @ObservationIgnored var onFindNewChannels: (() async -> Void)?
    /// Starts an immediate background backfill when a channel becomes watched.
    @ObservationIgnored var onChannelWatched: ((_ workspaceID: String, _ channelID: String) async -> Void)?
    /// Reload/restart Socket Mode after a workspace is added or its app token changes.
    @ObservationIgnored var onConnectionsChanged: ((_ workspaceID: String?) async -> Void)?
    @ObservationIgnored var onWorkspaceWillRemove: ((_ workspaceID: String) async -> Void)?
    var isFindingChannels = false
    @ObservationIgnored private var lastSavedSettings: AppSettings
    @ObservationIgnored private var lastSavedAPIKey: String
    @ObservationIgnored private var autosaveGeneration = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(
        database: AppDatabase,
        appTokenProvider: @escaping (_ workspaceID: String) -> String? = {
            (try? KeychainStore.getAppToken(workspaceID: $0)) ?? nil
        },
        storeAppToken: @escaping (_ token: String, _ workspaceID: String) throws -> Void = {
            try KeychainStore.setAppToken($0, workspaceID: $1)
        },
        validateAppToken: @escaping (_ token: String) async throws -> Void = {
            _ = try await SlackClient().openSocketModeConnection(appToken: $0)
        }
    ) {
        let loadedSettings = (try? database.dbWriter.read { try AppSettings.fetchOne($0, key: 1) })
            .flatMap { $0 } ?? AppSettings()
        let loadedAPIKey = ((try? KeychainStore.get(.llmAPIKey)) ?? nil) ?? ""

        self.database = database
        self.appTokenProvider = appTokenProvider
        self.storeAppToken = storeAppToken
        self.validateAppToken = validateAppToken
        self.settings = loadedSettings
        self.apiKey = loadedAPIKey
        self.lastSavedSettings = loadedSettings
        self.lastSavedAPIKey = loadedAPIKey
        self.learnedPatternsModel = LearnedPatternsModel(database: database)
    }

    func load() async {
        channels = (try? await database.dbWriter.read { db in
            try Channel.order(Column("name")).fetchAll(db)
        }) ?? []
        workspaces = (try? await database.dbWriter.read { db in
            try Workspace.order(Column("name")).fetchAll(db)
        }) ?? []
        let activeWorkspaceIDs = Set(workspaces.map(\.id))
        socketStates = socketStates.filter { activeWorkspaceIDs.contains($0.key) }
        appTokenInputs = appTokenInputs.filter { activeWorkspaceIDs.contains($0.key) }
        for workspace in workspaces {
            let hasAppToken = !(appTokenProvider(workspace.id) ?? "").isEmpty
            if !hasAppToken {
                socketStates[workspace.id] = .setupRequired
            } else if socketStates[workspace.id] == nil || socketStates[workspace.id] == .setupRequired {
                socketStates[workspace.id] = .disconnected
            }
        }
        await learnedPatternsModel.load()
    }

    var workspacesNeedingSocketModeSetup: [Workspace] {
        workspaces.filter { socketStates[$0.id] == .setupRequired }
    }

    func setSocketState(_ state: SocketModeConnectionState, workspaceID: String) {
        socketStates[workspaceID] = state
    }

    func socketState(for workspace: Workspace) -> SocketModeConnectionState {
        socketStates[workspace.id] ?? .disconnected
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
            Task {
                await self?.load()
                await self?.onConnectionsChanged?(nil)
            }
        }
        addWorkspaceModel = model
    }

    func cancelAddWorkspace() { addWorkspaceModel = nil }

    /// Remove a workspace and everything under it (token + channels + messages/items).
    func removeWorkspace(_ workspace: Workspace) async {
        await onWorkspaceWillRemove?(workspace.id)
        let service = SlackConnectionService(client: SlackClient(), database: database)
        try? service.removeWorkspace(workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        channels.removeAll { $0.workspaceID == workspace.id }
        appTokenInputs.removeValue(forKey: workspace.id)
        socketStates.removeValue(forKey: workspace.id)
    }

    /// Validate and replace one workspace's app-level token. The one-time WebSocket URL
    /// returned by Slack is discarded immediately and never reaches observable UI state.
    func saveAppToken(for workspace: Workspace) async {
        guard !savingAppTokenWorkspaceIDs.contains(workspace.id) else { return }
        let token = (appTokenInputs[workspace.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xapp-") else {
            socketStates[workspace.id] = .failed(
                "Paste an app-level token that starts with xapp-."
            )
            return
        }

        savingAppTokenWorkspaceIDs.insert(workspace.id)
        socketStates[workspace.id] = .connecting
        defer { savingAppTokenWorkspaceIDs.remove(workspace.id) }

        do {
            try await validateAppToken(token)
            try storeAppToken(token, workspace.id)
            appTokenInputs[workspace.id] = ""
            socketStates[workspace.id] = .disconnected
            await onConnectionsChanged?(workspace.id)
        } catch {
            socketStates[workspace.id] = .failed(
                "Slack rejected this token. Generate a new app-level token with connections:write."
            )
        }
    }

    func toggleWatched(_ channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        var updated = channels[index]
        updated.isWatched.toggle()
        channels[index] = updated
        persistChannel(updated)
        if updated.isWatched, let onChannelWatched {
            let workspaceID = updated.workspaceID
            let channelID = updated.id
            Task { await onChannelWatched(workspaceID, channelID) }
        }
    }

    func setSensitivity(_ sensitivity: ChannelSensitivity, for channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        var updated = channels[index]
        updated.sensitivity = sensitivity
        channels[index] = updated
        persistChannel(updated)
    }

    func scheduleAutosave() {
        autosaveGeneration += 1
        autosaveTask?.cancel()

        guard settings != lastSavedSettings || apiKey != lastSavedAPIKey else {
            autosaveStatus = "Autosaved"
            return
        }

        autosaveStatus = "Saving..."
        let generation = autosaveGeneration
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.saveIfCurrent(generation: generation)
        }
    }

    private func saveIfCurrent(generation: Int) async {
        guard generation == autosaveGeneration else { return }
        let settingsToSave = settings
        let apiKeyToSave = apiKey
        do {
            try await database.dbWriter.write { db in
                try settingsToSave.update(db)
            }
            // Empty key clears the stored secret; otherwise upsert it.
            if apiKeyToSave.isEmpty {
                try KeychainStore.delete(.llmAPIKey)
            } else {
                try KeychainStore.set(apiKeyToSave, for: .llmAPIKey)
            }
            guard generation == autosaveGeneration else { return }
            lastSavedSettings = settingsToSave
            lastSavedAPIKey = apiKeyToSave
            autosaveStatus = "Autosaved"
        } catch {
            guard generation == autosaveGeneration else { return }
            autosaveStatus = "Autosave failed"
        }
    }

    /// Pull the latest channel list from Slack, then reload.
    func findNewChannels() async {
        guard let onFindNewChannels, !isFindingChannels else { return }
        isFindingChannels = true
        await onFindNewChannels()
        await load()
        isFindingChannels = false
    }

    /// Remove a channel entirely (its messages/items cascade). Use for channels you've
    /// left or don't want tracked; the channel catalog can re-add it if you're still a member.
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
