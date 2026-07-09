import Foundation
import Observation
import AppKit

/// Top-level app state: owns the database + poller and decides onboarding vs. main UI.
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

    @ObservationIgnored private var poller: Poller?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let evolutionApprovalNotifier = EvolutionApprovalNotifier()

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

        // Under XCTest the app is the test host; do NOT boot the live poller/UI (it would
        // make real network calls with the real Keychain token — slow + flaky in CI).
        guard !AppRoot.isRunningUnderTests else { return }

        if isOnboarded { setupMainUI() }
        startPollingIfReady()
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
            self?.startPollingIfReady()
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
        settings.onRefreshChannels = {
            // Refresh channels for every connected workspace, each with its own token.
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

    // MARK: - Polling

    /// Spin up the poller once the user is connected. Polling immediately backfills
    /// the gap since the last run; system-wake also triggers a backfill (§6.3).
    private func startPollingIfReady() {
        guard isOnboarded, poller == nil else { return }

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
        let resolution = ResolutionDetector(database: db)
        var summary = SummaryService(database: db, llm: llmClient)
        summary.minimumRefreshIntervalSeconds = {
            let minutes = try? db.dbWriter.read {
                try AppSettings.fetchOne($0, key: 1)?.summaryRefreshIntervalMinutes
            }
            return TimeInterval(max((minutes ?? nil) ?? 360, 1) * 60)
        }
        let threadSummaries = ItemThreadSummaryService(database: db, llm: llmClient, patternStore: patternStore)
        let evolution = PatternEvolutionService(database: db, llm: llmClient, store: patternStore)

        let poller = Poller(
            ingestion: ingestion,
            intervalSeconds: {
                let value = try? db.dbWriter.read { try AppSettings.fetchOne($0, key: 1)?.pollIntervalSeconds }
                return (value ?? nil) ?? 180
            },
            onCycleComplete: {
                // Each cycle over the freshly-ingested mirror: detect, auto-close anything
                // already handled (§7.4), then refresh daily summaries (once/day, §8.3).
                try await detectionService.detectWatchedChannels()
                try await resolution.resolveOpenItems()
                try await threadSummaries.analyzeOpenThreads()
                try await summary.generateDailySummaries()
                // Self-evolution is now per-triage (wired via `mainViewModel.onTriageLabeled`
                // below), not a batched cycle pass — the system learns on every triage click.
            }
        )
        self.poller = poller
        Task { await poller.start() }

        // Wire the manual "Refresh now" buttons (both tabs) to an immediate cycle.
        let refresh: () async -> Void = { [weak self] in
            await poller.pollOnce()
            await self?.mainViewModel?.reload()
            await self?.overviewViewModel?.reload()
        }
        mainViewModel?.onRefresh = refresh
        overviewViewModel?.onRefresh = refresh

        // Per-triage learning (§7.5): every triage verdict immediately proposes a rule
        // phrase and/or LLM-guidance change (human-approved in Settings). Runs in the
        // background so triage stays instant.
        mainViewModel?.onTriageLabeled = { [weak self] channelID, messageTS, verdict, source in
            let enabled = try? await db.dbWriter.read {
                try AppSettings.fetchOne($0, key: 1)?.selfEvolutionEnabled
            }
            guard (enabled ?? nil) ?? true else { return }

            let before = await MainActor.run {
                self?.settingsModel?.pendingEvolutionUpdateCount ?? 0
            }
            await evolution.evolveFromTriage(channelID: channelID, messageTS: messageTS, verdict: verdict, source: source)
            await self?.settingsModel?.learnedPatternsModel.load()
            let after = await MainActor.run {
                self?.settingsModel?.pendingEvolutionUpdateCount ?? 0
            }
            if after > before {
                await self?.evolutionApprovalNotifier.notifyPendingApproval(count: after)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.poller?.pollOnce() }
        }
    }
}
