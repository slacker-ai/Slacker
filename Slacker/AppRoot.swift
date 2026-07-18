import Foundation
import Observation
import AppKit

/// Top-level app state: owns the database + real-time sync and decides onboarding vs. main UI.
@MainActor
@Observable
final class AppRoot {
    let database: AppDatabase
    var isOnboarded: Bool
    /// Non-nil when the on-disk database couldn't be opened; the app falls back to an
    /// ephemeral in-memory DB and shows a banner instead of crashing.
    private(set) var startupError: String?

    /// UI models, created once the user is connected.
    private(set) var mainViewModel: MainViewModel?
    private(set) var overviewViewModel: OverviewViewModel?
    private(set) var settingsModel: SettingsModel?

    @ObservationIgnored private var syncCoordinator: SyncCoordinator?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// Open-item badge for the menu bar (§8.1).
    var badgeCount: Int { mainViewModel?.surfacedCount ?? 0 }

    init() {
        // Fall back to an in-memory DB rather than crashing if the store can't open.
        do {
            database = try AppDatabase.makeShared()
        } catch {
            Log.error("Failed to open database: \(error)")
            startupError = "Couldn't open the local database. Your data won't be saved this session."
            // makeInMemory only throws in extreme conditions; if even that fails, there's
            // nothing usable to run, so a trap here is the honest outcome.
            database = try! AppDatabase.makeInMemory()
        }

        do {
            let completed = try database.dbWriter.read { db in
                try AppSettings.fetchOne(db, key: 1)?.onboardingCompleted
            }
            isOnboarded = completed ?? false
        } catch {
            isOnboarded = false
        }

        // Under XCTest the app is the test host; do NOT boot live Socket Mode/UI (it would
        // make real network calls with the real Keychain token — slow + flaky in CI).
        guard !AppRoot.isRunningUnderTests else { return }

        if isOnboarded { setupMainUI() }
        startSyncIfReady()
    }

    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func makeOnboardingModel() -> OnboardingModel {
        let service = SlackConnectionService(client: SlackClient(), database: database)
        let model = OnboardingModel(service: service)
        model.onFinished = { [weak self] in
            self?.isOnboarded = true
            self?.setupMainUI()
            self?.startSyncIfReady()
        }
        return model
    }

    private func setupMainUI() {
        guard mainViewModel == nil else { return }
        let main = MainViewModel(database: database)
        main.start()
        mainViewModel = main
        overviewViewModel = OverviewViewModel(database: database)
        let settings = SettingsModel(database: database)
        let db = database
        settings.onFindNewChannels = {
            // Reload the channel catalog for every workspace, each with its own token.
            let workspaces = (try? await db.dbWriter.read { try Workspace.fetchAll($0) }) ?? []
            let service = SlackConnectionService(client: SlackClient(), database: db)
            for workspace in workspaces {
                guard let token = (try? KeychainStore.getToken(workspaceID: workspace.id)) ?? nil else { continue }
                _ = try? await service.refreshChannels(
                    token: token, variant: workspace.manifestVariant, workspaceID: workspace.id
                )
            }
        }
        settingsModel = settings
    }

    // MARK: - Real-time sync

    /// Start Socket Mode once the user is connected. HTTP is retained only for bounded
    /// gap recovery on launch, wake, reconnect, and foreground activation.
    private func startSyncIfReady() {
        guard isOnboarded, syncCoordinator == nil else { return }

        let ingestion = IngestionService(client: SlackClient(), database: database)
        let db = database

        // Build the optional LLM classifier from current settings + Keychain key.
        // If unconfigured (no key / CLI missing), detection runs rules-only.
        let settings = (try? db.dbWriter.read { try AppSettings.fetchOne($0, key: 1) }) ?? AppSettings()
        let apiKey = (try? KeychainStore.get(.llmAPIKey)) ?? nil
        let llmClient = try? LLMClientFactory.make(settings: settings, apiKey: apiKey)
        let llmClassifier = llmClient.map { LLMClassifier(client: $0) }

        let patternStore = PatternStore(database: db)
        var detection = DetectionService(
            database: db,
            llmClassifier: llmClassifier,
            calibration: CalibrationService(database: db),
            patternStore: patternStore
        )
        detection.isSelfEvolutionEnabled = {
            let enabled = try? await db.dbWriter.read {
                try AppSettings.fetchOne($0, key: 1)?.selfEvolutionEnabled
            }
            return (enabled ?? nil) ?? true
        }
        let detectionService = detection
        var summary = SummaryService(database: db, llm: llmClient)
        summary.minimumRefreshIntervalSeconds = {
            let minutes = try? db.dbWriter.read {
                try AppSettings.fetchOne($0, key: 1)?.summaryRefreshIntervalMinutes
            }
            return TimeInterval(max((minutes ?? nil) ?? 360, 1) * 60)
        }
        let summaryService = summary
        let threadSummaries = ItemThreadSummaryService(database: db, llm: llmClient, patternStore: patternStore)
        let evolution = PatternEvolutionService(database: db, llm: llmClient, store: patternStore)

        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            stateSink: { [weak self] workspaceID, state in
                await self?.socketStateDidChange(state, workspaceID: workspaceID)
            },
            runAnalysis: { [weak self] batch in
                try await detectionService.detectChangedRoots(
                    batch.rootsByChannel,
                    editedRootTSByChannel: batch.editedRootsByChannel
                )
                await self?.mainViewModel?.reload()
                await self?.overviewViewModel?.reload()
            },
            runEnrichment: { [weak self] rootsByChannel in
                // AI recaps are coalesced and restricted to the roots/channels that
                // changed, so they never hold up Socket Mode event processing.
                try await threadSummaries.analyzeOpenThreads(rootsByChannel: rootsByChannel)
                try await summaryService.generateDailySummaries(
                    channelIDs: Set(rootsByChannel.keys)
                )
                await self?.mainViewModel?.reload()
                await self?.overviewViewModel?.reload()
            }
        )
        self.syncCoordinator = coordinator

        settingsModel?.onChannelWatched = { workspaceID, channelID in
            await coordinator.reconcileNewlyWatchedChannel(
                workspaceID: workspaceID,
                channelID: channelID
            )
        }

        settingsModel?.onConnectionsChanged = { workspaceID in
            if let workspaceID {
                await coordinator.restartConnection(workspaceID: workspaceID)
            } else {
                await coordinator.reloadConnections()
            }
        }
        settingsModel?.onWorkspaceWillRemove = { workspaceID in
            await coordinator.disconnectWorkspace(workspaceID)
        }

        Task { await coordinator.start() }

        // Every explicit user action immediately learns approved phrases/guidance in the
        // background. The action itself never waits for the model.
        mainViewModel?.onTriageLabeled = { [weak self] channelID, messageTS, verdict, source in
            let enabled = try? await db.dbWriter.read {
                try AppSettings.fetchOne($0, key: 1)?.selfEvolutionEnabled
            }
            guard (enabled ?? nil) ?? true else { return }

            await evolution.evolveFromTriage(channelID: channelID, messageTS: messageTS, verdict: verdict, source: source)
            await self?.settingsModel?.learnedPatternsModel.load()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let coordinator = self.syncCoordinator else { return }
                await coordinator.recoverAll(reason: .wake)
                await self.mainViewModel?.reload()
                await self.overviewViewModel?.reload()
            }
        }

        // Socket Mode is the fast path, but Slack delivery can be unavailable or an
        // event can land while the connection is being replaced. Returning to Slacker
        // is a natural, bounded opportunity to reconcile those gaps without a timer.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let coordinator = self.syncCoordinator else { return }
                await coordinator.recoverAll(reason: .foreground)
                await self.mainViewModel?.reload()
                await self.overviewViewModel?.reload()
            }
        }
    }

    private func socketStateDidChange(
        _ state: SocketModeConnectionState,
        workspaceID: String
    ) {
        settingsModel?.setSocketState(state, workspaceID: workspaceID)
    }

}
