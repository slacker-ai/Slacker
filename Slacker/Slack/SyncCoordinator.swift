import Foundation
import GRDB

/// Event-driven synchronization. Socket Mode selects the smallest HTTP reconciliation
/// needed for each event; cursor/thread gap recovery is reserved for launch, wake,
/// reconnect, and foreground activation. There is deliberately no recurring timer or
/// whole-database refresh.
actor SyncCoordinator {
    enum ReconciliationReason: String, Sendable {
        case launch
        case wake
        case reconnect
        case foreground
    }

    struct SocketHandlers: Sendable {
        let onEvent: SocketModeClient.EventHandler
        let onStateChange: SocketModeClient.StateHandler
    }
    typealias SocketFactory = @Sendable (SocketHandlers) -> SocketModeClient
    typealias StateSink = @Sendable (
        _ workspaceID: String,
        _ state: SocketModeConnectionState
    ) async -> Void
    struct AnalysisBatch: Equatable, Sendable {
        let rootsByChannel: [String: Set<String>]
        let editedRootsByChannel: [String: Set<String>]
    }

    typealias AnalysisRunner = @Sendable (_ batch: AnalysisBatch) async throws -> Void
    typealias EnrichmentRunner = @Sendable (_ rootsByChannel: [String: Set<String>]) async throws -> Void

    private struct BatchKey: Hashable, Sendable {
        let workspaceID: String
        let channelID: String
    }

    private struct Deletion: Hashable, Sendable {
        let messageTS: String
        let hintedThreadTS: String?
    }

    private struct PendingBatch: Sendable {
        var reconcileChannel = false
        var topLevelRoots = Set<String>()
        var threadRoots = Set<String>()
        var editedRootTSs = Set<String>()
        var reactionMessageTSs = Set<String>()
        var deletions = Set<Deletion>()
    }

    private let ingestion: any SlackIngestionServing
    private let database: AppDatabase
    private let runAnalysis: AnalysisRunner
    private let runEnrichment: EnrichmentRunner
    private let appTokenProvider: @Sendable (_ workspaceID: String) -> String?
    private let socketFactory: SocketFactory
    private let stateSink: StateSink
    private let debounceNanoseconds: UInt64

    private var isStarted = false
    private var sockets: [String: SocketModeClient] = [:]
    private var connectionStates: [String: SocketModeConnectionState] = [:]
    private var connectedOnce = Set<String>()
    private var pendingBatches: [BatchKey: PendingBatch] = [:]
    private var debounceTasks: [BatchKey: Task<Void, Never>] = [:]
    private var enrichmentTask: Task<Void, Never>?
    private var pendingEnrichmentRoots: [String: Set<String>] = [:]
    private var recoveryInProgress = false
    private var pendingRecoveryAll = false
    private var pendingRecoveryWorkspaceIDs = Set<String>()
    private var pendingRecoveryReason: ReconciliationReason?

    private(set) var lastError: String?
    private(set) var lastReconciliationReason: ReconciliationReason?

    init(
        ingestion: any SlackIngestionServing,
        database: AppDatabase,
        debounceNanoseconds: UInt64 = 350_000_000,
        appTokenProvider: @escaping @Sendable (_ workspaceID: String) -> String? = {
            (try? KeychainStore.getAppToken(workspaceID: $0)) ?? nil
        },
        socketFactory: @escaping SocketFactory = { handlers in
            let client = SlackClient()
            return SocketModeClient(
                openConnection: { try await client.openSocketModeConnection(appToken: $0) },
                onEvent: handlers.onEvent,
                onStateChange: handlers.onStateChange
            )
        },
        stateSink: @escaping StateSink = { _, _ in },
        runAnalysis: @escaping AnalysisRunner,
        runEnrichment: @escaping EnrichmentRunner = { _ in }
    ) {
        self.ingestion = ingestion
        self.database = database
        self.debounceNanoseconds = debounceNanoseconds
        self.appTokenProvider = appTokenProvider
        self.socketFactory = socketFactory
        self.stateSink = stateSink
        self.runAnalysis = runAnalysis
        self.runEnrichment = runEnrichment
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reloadConnections(catchUpOnFirstConnection: false)
        await recoverAll(reason: .launch)
    }

    func stop() async {
        isStarted = false
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        pendingBatches.removeAll()
        pendingEnrichmentRoots.removeAll()
        pendingRecoveryAll = false
        pendingRecoveryWorkspaceIDs.removeAll()
        pendingRecoveryReason = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil

        let activeSockets = Array(sockets.values)
        sockets.removeAll()
        for socket in activeSockets { await socket.stop() }
        connectionStates.removeAll()
        connectedOnce.removeAll()
    }

    /// Re-scan workspace/token configuration after onboarding, token replacement, or a
    /// workspace removal. Existing healthy connections are left alone.
    func reloadConnections(catchUpOnFirstConnection: Bool = true) async {
        let workspaceIDs: Set<String>
        do {
            workspaceIDs = try await database.dbWriter.read { db in
                Set(try Workspace.fetchAll(db).map(\.id))
            }
        } catch {
            record(error, context: "loading Socket Mode workspaces")
            return
        }

        for workspaceID in Array(sockets.keys) where !workspaceIDs.contains(workspaceID) {
            await disconnectWorkspace(workspaceID)
        }

        for workspaceID in workspaceIDs where sockets[workspaceID] == nil {
            if catchUpOnFirstConnection, appTokenProvider(workspaceID) != nil {
                connectedOnce.insert(workspaceID)
            }
            await startConnection(workspaceID: workspaceID)
        }
    }

    func restartConnection(workspaceID: String) async {
        if let socket = sockets.removeValue(forKey: workspaceID) {
            await socket.stop()
        }
        connectionStates.removeValue(forKey: workspaceID)
        // Token setup/replacement can follow an arbitrarily long delivery gap. Treat the
        // first successful hello as a reconnect so it gets one targeted HTTP catch-up.
        connectedOnce.insert(workspaceID)
        await startConnection(workspaceID: workspaceID)
    }

    func disconnectWorkspace(_ workspaceID: String) async {
        if let socket = sockets.removeValue(forKey: workspaceID) {
            await socket.stop()
        }
        connectionStates[workspaceID] = .disconnected
        connectedOnce.remove(workspaceID)
        await stateSink(workspaceID, .disconnected)
    }

    func state(for workspaceID: String) -> SocketModeConnectionState {
        connectionStates[workspaceID] ?? .disconnected
    }

    /// Queue one bounded gap-recovery pass. Overlapping lifecycle/foreground requests are
    /// coalesced; the caller that owns the drain processes anything queued while awaiting
    /// Slack. This is never invoked by a timer.
    func recoverAll(reason: ReconciliationReason) async {
        pendingRecoveryAll = true
        pendingRecoveryWorkspaceIDs.removeAll()
        pendingRecoveryReason = reason
        await drainRecoveryRequests()
    }

    private func recoverWorkspace(_ workspaceID: String, reason: ReconciliationReason) async {
        if !pendingRecoveryAll { pendingRecoveryWorkspaceIDs.insert(workspaceID) }
        pendingRecoveryReason = reason
        await drainRecoveryRequests()
    }

    private func drainRecoveryRequests() async {
        guard !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }

        while pendingRecoveryAll || !pendingRecoveryWorkspaceIDs.isEmpty {
            let recoverAllWorkspaces = pendingRecoveryAll
            let workspaceIDs = pendingRecoveryWorkspaceIDs
            let reason = pendingRecoveryReason ?? .reconnect
            pendingRecoveryAll = false
            pendingRecoveryWorkspaceIDs.removeAll()
            pendingRecoveryReason = nil
            lastReconciliationReason = reason

            if recoverAllWorkspaces {
                await performRecovery(workspaceID: nil, reason: reason)
            } else {
                for workspaceID in workspaceIDs.sorted() {
                    await performRecovery(workspaceID: workspaceID, reason: reason)
                }
            }
        }
    }

    private func performRecovery(workspaceID: String?, reason: ReconciliationReason) async {
        var failed = false
        do {
            let roots = if let workspaceID {
                try await ingestion.reconcileWorkspace(workspaceID: workspaceID)
            } else {
                try await ingestion.reconcileAllWorkspaces()
            }
            try await analyzeAndEnrich(rootsByChannel: roots)
        } catch {
            failed = true
            record(error, context: "Slack cursor recovery")
        }

        do {
            let changedBatches = try await ingestion.recoverTrackedItemThreads(
                workspaceID: workspaceID
            )
            for roots in changedBatches {
                do {
                    try await analyzeAndEnrich(rootsByChannel: roots)
                } catch {
                    failed = true
                    record(error, context: "Slack tracked-thread batch analysis")
                }
            }
        } catch {
            failed = true
            record(error, context: "Slack tracked-thread recovery")
        }

        if !failed { lastError = nil }
        Log.info("Slack gap recovery finished (\(reason.rawValue)).")
    }

    private func analyzeAndEnrich(
        rootsByChannel: [String: Set<String>],
        editedRootsByChannel: [String: Set<String>] = [:]
    ) async throws {
        guard !rootsByChannel.isEmpty || !editedRootsByChannel.isEmpty else { return }
        try await runAnalysis(AnalysisBatch(
            rootsByChannel: rootsByChannel,
            editedRootsByChannel: editedRootsByChannel
        ))
        scheduleEnrichment(rootsByChannel: rootsByChannel)
    }

    /// Immediately backfill and evaluate a channel when the user starts watching it.
    /// Settings launches this in its own Task, so adding a channel never waits for the
    /// next lifecycle recovery and does not block the UI.
    func reconcileNewlyWatchedChannel(workspaceID: String, channelID: String) async {
        do {
            let roots = try await ingestion.reconcileChannel(
                workspaceID: workspaceID,
                channelID: channelID
            )
            if !roots.isEmpty {
                try await runAnalysis(AnalysisBatch(
                    rootsByChannel: [channelID: roots],
                    editedRootsByChannel: [:]
                ))
                scheduleEnrichment(rootsByChannel: [channelID: roots])
            }
            lastError = nil
            Log.info("Initial channel reconciliation finished (\(channelID)).")
        } catch {
            record(error, context: "initial channel reconciliation")
        }
    }

    /// Entry point for decoded Socket Mode deliveries. Team and watched-channel checks
    /// prevent cross-workspace routing and avoid work for channels the user did not select.
    func receive(_ delivery: SocketModeEvent, expectedWorkspaceID: String? = nil) async {
        if let expectedWorkspaceID, delivery.teamID != expectedWorkspaceID {
            Log.error("Socket Mode event workspace did not match its connection; ignoring it.")
            return
        }
        guard let channelID = delivery.event.channelID else { return }

        let isWatched = (try? await database.dbWriter.read { db in
            guard let channel = try Channel.fetchOne(db, key: channelID) else { return false }
            return channel.workspaceID == delivery.teamID && channel.isWatched
        }) ?? false
        guard isWatched else { return }

        let key = BatchKey(workspaceID: delivery.teamID, channelID: channelID)
        var batch = pendingBatches[key] ?? PendingBatch()
        let event = delivery.event

        switch event.type {
        case "message":
            switch event.subtype {
            case "message_changed":
                if let changed = event.message, let ts = changed.ts {
                    let rootTS = changed.threadTS ?? ts
                    batch.threadRoots.insert(rootTS)
                    batch.editedRootTSs.insert(rootTS)
                }

            case "message_deleted":
                if let deletedTS = event.deletedTS {
                    let hint = event.previousMessage?.threadTS
                    batch.deletions.insert(Deletion(messageTS: deletedTS, hintedThreadTS: hint))
                }

            case nil, "thread_broadcast":
                guard let ts = event.ts else { break }
                if let threadTS = event.threadTS, threadTS != ts {
                    batch.threadRoots.insert(threadTS)
                } else {
                    batch.reconcileChannel = true
                    batch.topLevelRoots.insert(ts)
                }

            default:
                break
            }

        case "reaction_added", "reaction_removed":
            if event.item?.type == "message", let messageTS = event.item?.ts {
                batch.reactionMessageTSs.insert(messageTS)
            }

        default:
            return
        }

        pendingBatches[key] = batch
        scheduleFlush(for: key)
    }

    private func startConnection(workspaceID: String) async {
        guard let appToken = appTokenProvider(workspaceID), !appToken.isEmpty else {
            connectionStates[workspaceID] = .setupRequired
            await stateSink(workspaceID, .setupRequired)
            return
        }

        let socket = socketFactory(SocketHandlers(
            onEvent: { [weak self] event in
                await self?.receive(event, expectedWorkspaceID: workspaceID)
            },
            onStateChange: { [weak self] state in
                await self?.connectionStateChanged(state, workspaceID: workspaceID)
            }
        ))
        sockets[workspaceID] = socket
        await socket.start(appToken: appToken)
    }

    func connectionStateChanged(
        _ state: SocketModeConnectionState,
        workspaceID: String
    ) async {
        connectionStates[workspaceID] = state
        await stateSink(workspaceID, state)

        guard state == .connected else { return }
        if connectedOnce.contains(workspaceID) {
            await recoverWorkspace(workspaceID, reason: .reconnect)
        } else {
            connectedOnce.insert(workspaceID)
        }
    }

    private func scheduleFlush(for key: BatchKey) {
        debounceTasks[key]?.cancel()
        let delay = debounceNanoseconds
        debounceTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.flush(key)
        }
    }

    private func flush(_ key: BatchKey) async {
        guard let batch = pendingBatches.removeValue(forKey: key) else { return }
        debounceTasks.removeValue(forKey: key)
        var didIngest = false
        var affectedRoots = batch.topLevelRoots
        var threadRoots = batch.threadRoots

        if batch.reconcileChannel {
            do {
                let ingestedRoots = try await ingestion.reconcileChannel(
                    workspaceID: key.workspaceID,
                    channelID: key.channelID
                )
                affectedRoots.formUnion(ingestedRoots)
                didIngest = true
            } catch {
                record(error, context: "channel event reconciliation")
            }
        }

        for deletion in batch.deletions {
            do {
                let storedRoot = try await ingestion.removeLocalMessage(
                    channelID: key.channelID,
                    messageTS: deletion.messageTS
                )
                if let root = storedRoot ?? deletion.hintedThreadTS, root != deletion.messageTS {
                    threadRoots.insert(root)
                    affectedRoots.insert(root)
                } else {
                    // The deleted message was the root (or had already disappeared
                    // locally). Keep the root in the batch so observers reload, without
                    // attempting a thread fetch that Slack will reject.
                    affectedRoots.insert(deletion.messageTS)
                }
                didIngest = true
            } catch {
                record(error, context: "message deletion reconciliation")
            }
        }

        for threadTS in threadRoots {
            do {
                try await ingestion.refreshThread(
                    workspaceID: key.workspaceID,
                    channelID: key.channelID,
                    threadTS: threadTS
                )
                affectedRoots.insert(threadTS)
                didIngest = true
            } catch {
                record(error, context: "thread event reconciliation")
            }
        }

        for messageTS in batch.reactionMessageTSs {
            do {
                let rootTS = try await ingestion.refreshThreadContainingMessage(
                    workspaceID: key.workspaceID,
                    channelID: key.channelID,
                    messageTS: messageTS
                )
                if let rootTS { affectedRoots.insert(rootTS) }
                didIngest = true
            } catch {
                record(error, context: "reaction event reconciliation")
            }
        }

        guard didIngest, !affectedRoots.isEmpty || !batch.editedRootTSs.isEmpty else { return }
        do {
            let editedRoots = batch.editedRootTSs.isEmpty
                ? [:]
                : [key.channelID: batch.editedRootTSs]
            let rootsByChannel = affectedRoots.isEmpty ? [:] : [key.channelID: affectedRoots]
            try await analyzeAndEnrich(
                rootsByChannel: rootsByChannel,
                editedRootsByChannel: editedRoots
            )
            lastError = nil
        } catch {
            record(error, context: "post-ingestion analysis")
        }
    }

    /// AI summaries are useful enrichment, but they must never hold up event processing
    /// or overlap when several Socket Mode batches arrive close together.
    private func scheduleEnrichment(rootsByChannel: [String: Set<String>]) {
        merge(rootsByChannel, into: &pendingEnrichmentRoots)
        guard !pendingEnrichmentRoots.isEmpty else { return }
        guard enrichmentTask == nil else { return }
        enrichmentTask = Task { [weak self] in
            await self?.drainEnrichmentRequests()
        }
    }

    private func drainEnrichmentRequests() async {
        while !pendingEnrichmentRoots.isEmpty, !Task.isCancelled {
            let roots = pendingEnrichmentRoots
            pendingEnrichmentRoots.removeAll()
            do {
                try await runEnrichment(roots)
            } catch is CancellationError {
                break
            } catch {
                let message = SecretRedaction.redact(String(describing: error))
                Log.error("Background enrichment failed: \(message)")
            }
        }
        enrichmentTask = nil
    }

    private func merge(
        _ source: [String: Set<String>],
        into destination: inout [String: Set<String>]
    ) {
        for (channelID, roots) in source {
            destination[channelID, default: []].formUnion(roots)
        }
    }

    private func record(_ error: Error, context: String) {
        let message = SecretRedaction.redact(String(describing: error))
        lastError = "\(context) failed: \(message)"
        Log.error("\(context) failed: \(message)")
    }
}
