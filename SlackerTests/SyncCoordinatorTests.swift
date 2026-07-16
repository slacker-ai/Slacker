import XCTest
import GRDB
@testable import Slacker

final class SyncCoordinatorTests: XCTestCase {
    func testLaunchCatchupRunsOnceAndNeverRepeatsWhileIdle() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let calls = await ingestion.calls
        let reason = await coordinator.lastReconciliationReason
        let state = await coordinator.state(for: "T1")
        XCTAssertEqual(calls, [.all, .recovery(nil)])
        XCTAssertEqual(analysis.value, 1)
        XCTAssertEqual(reason, .launch)
        XCTAssertEqual(state, .setupRequired)
        await coordinator.stop()
    }

    func testWakeIsAnExplicitOneShotGapRecovery() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.recoverAll(reason: .wake)

        let calls = await ingestion.calls
        let reason = await coordinator.lastReconciliationReason
        XCTAssertEqual(calls, [.all, .recovery(nil)])
        XCTAssertEqual(analysis.value, 1)
        XCTAssertEqual(reason, .wake)
    }

    func testLifecycleRecoveryAnalyzesOnlyChangedThreadBatches() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion(
            cursorRootsByChannel: [:],
            recoveryBatches: [
                ["C1": ["100.0", "200.0"]],
                ["C1": ["300.0"]],
            ]
        )
        let analysis = AnalysisRecorder()
        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            appTokenProvider: { _ in nil },
            runAnalysis: { batch in analysis.record(batch) }
        )

        await coordinator.recoverAll(reason: .wake)

        XCTAssertEqual(analysis.batches, [
            .init(rootsByChannel: ["C1": ["100.0", "200.0"]], editedRootsByChannel: [:]),
            .init(rootsByChannel: ["C1": ["300.0"]], editedRootsByChannel: [:]),
        ])
    }

    func testLifecycleRecoveryDoesNoAnalysisWhenNothingChanged() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion(cursorRootsByChannel: [:])
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.recoverAll(reason: .wake)

        XCTAssertEqual(analysis.value, 0)
    }

    func testTopLevelMessageBurstsDebounceToOneChannelSyncAndAnalysisPass() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        for index in 1...3 {
            await coordinator.receive(delivery(eventID: "Ev\(index)", event: SlackSocketEvent(
                type: "message", channel: "C1", ts: "\(index).0"
            )))
        }
        try await waitForDebounce()

        let calls = await ingestion.calls
        XCTAssertEqual(calls, [.channel("T1", "C1")])
        XCTAssertEqual(analysis.value, 1)
    }

    func testNewlyWatchedChannelRunsImmediateTargetedBackfill() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion(reconciledChannelRoots: ["100.0", "200.0"])
        let analysis = AnalysisRecorder()
        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            appTokenProvider: { _ in nil },
            runAnalysis: { scope in analysis.record(scope) }
        )

        await coordinator.reconcileNewlyWatchedChannel(workspaceID: "T1", channelID: "C1")

        let calls = await ingestion.calls
        XCTAssertEqual(calls, [.channel("T1", "C1")])
        XCTAssertEqual(analysis.batches, [
            .init(
                rootsByChannel: ["C1": ["100.0", "200.0"]],
                editedRootsByChannel: [:]
            )
        ])
    }

    func testSocketBatchAnalyzesOnlyAffectedRoots() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion(reconciledChannelRoots: ["0.5"])
        let analysis = AnalysisRecorder()
        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            debounceNanoseconds: 10_000_000,
            appTokenProvider: { _ in nil },
            runAnalysis: { scope in analysis.record(scope) }
        )

        await coordinator.receive(delivery(eventID: "one", event: SlackSocketEvent(
            type: "message", channel: "C1", ts: "1.0"
        )))
        await coordinator.receive(delivery(eventID: "two", event: SlackSocketEvent(
            type: "message", channel: "C1", ts: "2.0"
        )))
        try await waitForDebounce()

        XCTAssertEqual(analysis.batches, [
            .init(
                rootsByChannel: ["C1": ["0.5", "1.0", "2.0"]],
                editedRootsByChannel: [:]
            )
        ])
    }

    func testReplyAndReactionUseTargetedThreadRefreshes() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.receive(delivery(eventID: "reply", event: SlackSocketEvent(
            type: "message", channel: "C1", ts: "101.0", threadTS: "100.0"
        )))
        await coordinator.receive(delivery(eventID: "reaction", event: SlackSocketEvent(
            type: "reaction_added",
            item: SlackSocketItem(type: "message", channel: "C1", ts: "101.0")
        )))
        try await waitForDebounce()

        let calls = await ingestion.calls
        XCTAssertTrue(calls.contains(.thread("T1", "C1", "100.0")))
        XCTAssertTrue(calls.contains(.reaction("T1", "C1", "101.0")))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(analysis.value, 1, "one batch must run downstream analysis once")
    }

    func testEditAndDeletionReconcileAffectedThreadOnce() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion(removedMessageRoot: "100.0")
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.receive(delivery(eventID: "edit", event: SlackSocketEvent(
            type: "message",
            subtype: "message_changed",
            channel: "C1",
            message: SlackSocketMessage(ts: "100.0")
        )))
        await coordinator.receive(delivery(eventID: "delete", event: SlackSocketEvent(
            type: "message",
            subtype: "message_deleted",
            channel: "C1",
            deletedTS: "101.0",
            previousMessage: SlackSocketMessage(ts: "101.0", threadTS: "100.0")
        )))
        try await waitForDebounce()

        let calls = await ingestion.calls
        XCTAssertEqual(calls.filter { if case .deletion = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(calls.filter { $0 == .thread("T1", "C1", "100.0") }.count, 1)
        XCTAssertEqual(analysis.value, 1)
    }

    func testRootDeletionReloadsAffectedRootWithoutFetchingMissingThread() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AnalysisRecorder()
        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            debounceNanoseconds: 10_000_000,
            appTokenProvider: { _ in nil },
            runAnalysis: { batch in analysis.record(batch) }
        )

        await coordinator.receive(delivery(eventID: "delete-root", event: SlackSocketEvent(
            type: "message",
            subtype: "message_deleted",
            channel: "C1",
            deletedTS: "100.0",
            previousMessage: SlackSocketMessage(ts: "100.0")
        )))
        try await waitForDebounce()

        let calls = await ingestion.calls
        XCTAssertEqual(calls, [.deletion("C1", "100.0")])
        XCTAssertEqual(analysis.batches, [
            .init(rootsByChannel: ["C1": ["100.0"]], editedRootsByChannel: [:]),
        ])
    }

    func testIgnoresUnwatchedChannelsAndCrossWorkspaceDeliveries() async throws {
        let db = try await seededDatabase()
        try await db.dbWriter.write { db in
            try Channel(
                id: "C2", workspaceID: "T1", name: "ignored", isPrivate: false, isWatched: false
            ).insert(db)
        }
        let ingestion = RecordingIngestion()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: AtomicInt())

        await coordinator.receive(delivery(teamID: "T2", eventID: "wrong-team", event: SlackSocketEvent(
            type: "message", channel: "C1", ts: "1.0"
        )))
        await coordinator.receive(delivery(eventID: "unwatched", event: SlackSocketEvent(
            type: "message", channel: "C2", ts: "2.0"
        )))
        try await waitForDebounce()

        let calls = await ingestion.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSecondConnectedStateRunsWorkspaceReconnectCatchup() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let analysis = AtomicInt()
        let coordinator = makeCoordinator(database: db, ingestion: ingestion, analysis: analysis)

        await coordinator.connectionStateChanged(.connected, workspaceID: "T1")
        await coordinator.connectionStateChanged(.disconnected, workspaceID: "T1")
        await coordinator.connectionStateChanged(.connected, workspaceID: "T1")

        let calls = await ingestion.calls
        let reason = await coordinator.lastReconciliationReason
        XCTAssertEqual(calls, [.workspace("T1"), .recovery("T1")])
        XCTAssertEqual(analysis.value, 1)
        XCTAssertEqual(reason, .reconnect)
    }

    func testLifecycleRecoveryDoesNotWaitForBackgroundEnrichment() async throws {
        let db = try await seededDatabase()
        let ingestion = RecordingIngestion()
        let gate = EnrichmentGate()
        let recoveryFinished = expectation(description: "critical recovery finished")
        let coordinator = SyncCoordinator(
            ingestion: ingestion,
            database: db,
            appTokenProvider: { _ in nil },
            runAnalysis: { _ in },
            runEnrichment: { _ in await gate.waitUntilReleased() }
        )

        Task {
            await coordinator.recoverAll(reason: .wake)
            recoveryFinished.fulfill()
        }
        await fulfillment(of: [recoveryFinished], timeout: 0.5)

        for _ in 0..<20 where !(await gate.hasStarted) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let enrichmentStarted = await gate.hasStarted
        await gate.release()
        XCTAssertTrue(enrichmentStarted)
    }

    private func seededDatabase() async throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { db in
            try Workspace(
                id: "T1",
                name: "Acme",
                authUserID: "U1",
                manifestVariant: .publicOnly,
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
            try Channel(
                id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true
            ).insert(db)
        }
        return db
    }

    private func makeCoordinator(
        database: AppDatabase,
        ingestion: RecordingIngestion,
        analysis: AtomicInt
    ) -> SyncCoordinator {
        SyncCoordinator(
            ingestion: ingestion,
            database: database,
            debounceNanoseconds: 10_000_000,
            appTokenProvider: { _ in nil },
            runAnalysis: { _ in analysis.increment() }
        )
    }

    private func delivery(
        teamID: String = "T1",
        eventID: String,
        event: SlackSocketEvent
    ) -> SocketModeEvent {
        SocketModeEvent(
            envelopeID: "envelope-\(eventID)",
            teamID: teamID,
            eventID: eventID,
            event: event
        )
    }

    private func waitForDebounce() async throws {
        try await Task.sleep(nanoseconds: 60_000_000)
    }
}

private actor RecordingIngestion: SlackIngestionServing {
    enum Call: Equatable {
        case all
        case workspace(String)
        case channel(String, String)
        case thread(String, String, String)
        case reaction(String, String, String)
        case deletion(String, String)
        case recovery(String?)
    }

    private(set) var calls: [Call] = []
    private let removedMessageRoot: String?
    private let reconciledChannelRoots: Set<String>
    private let cursorRootsByChannel: [String: Set<String>]
    private let recoveryBatches: [[String: Set<String>]]

    init(
        removedMessageRoot: String? = nil,
        reconciledChannelRoots: Set<String> = [],
        cursorRootsByChannel: [String: Set<String>] = ["C1": ["1.0"]],
        recoveryBatches: [[String: Set<String>]] = []
    ) {
        self.removedMessageRoot = removedMessageRoot
        self.reconciledChannelRoots = reconciledChannelRoots
        self.cursorRootsByChannel = cursorRootsByChannel
        self.recoveryBatches = recoveryBatches
    }

    func reconcileAllWorkspaces() -> [String: Set<String>] {
        calls.append(.all)
        return cursorRootsByChannel
    }
    func reconcileWorkspace(workspaceID: String) -> [String: Set<String>] {
        calls.append(.workspace(workspaceID))
        return cursorRootsByChannel
    }
    func reconcileChannel(workspaceID: String, channelID: String) -> Set<String> {
        calls.append(.channel(workspaceID, channelID))
        return reconciledChannelRoots
    }
    func refreshThread(workspaceID: String, channelID: String, threadTS: String) {
        calls.append(.thread(workspaceID, channelID, threadTS))
    }
    func refreshThreadContainingMessage(
        workspaceID: String,
        channelID: String,
        messageTS: String
    ) -> String? {
        calls.append(.reaction(workspaceID, channelID, messageTS))
        return nil
    }
    func recoverTrackedItemThreads(workspaceID: String?) -> [[String: Set<String>]] {
        calls.append(.recovery(workspaceID))
        return recoveryBatches
    }
    func removeLocalMessage(channelID: String, messageTS: String) -> String? {
        calls.append(.deletion(channelID, messageTS))
        return removedMessageRoot
    }
}

private final class AnalysisRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncCoordinator.AnalysisBatch] = []

    func record(_ batch: SyncCoordinator.AnalysisBatch) {
        lock.lock(); defer { lock.unlock() }
        storage.append(batch)
    }

    var batches: [SyncCoordinator.AnalysisBatch] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private actor EnrichmentGate {
    private(set) var hasStarted = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        hasStarted = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
