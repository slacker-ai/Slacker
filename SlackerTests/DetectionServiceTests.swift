import XCTest
import GRDB
@testable import Slacker

final class DetectionServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var idCounter = 0

    private func makeService(_ db: AppDatabase) -> DetectionService {
        idCounter = 0
        return DetectionService(
            database: db,
            now: { self.fixedNow },
            makeID: { self.idCounter += 1; return "item-\(self.idCounter)" }
        )
    }

    private func seedChannel(_ db: AppDatabase, sensitivity: ChannelSensitivity = .normal, lastDetectedTS: String? = nil) throws {
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true, sensitivity: sensitivity, lastDetectedTS: lastDetectedTS)
                .insert(dbc)
        }
    }

    private func seedWorkspaceAndChannel(_ db: AppDatabase, authUserID: String = "U_SELF", lastDetectedTS: String? = nil) throws {
        try db.dbWriter.write { dbc in
            try Workspace(id: "T1", name: "Acme", authUserID: authUserID, manifestVariant: .publicAndPrivate, createdAt: fixedNow)
                .insert(dbc)
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true, lastDetectedTS: lastDetectedTS)
                .insert(dbc)
        }
    }

    private func insert(
        _ db: AppDatabase,
        ts: String,
        user: String,
        text: String,
        threadTS: String? = nil,
        reactionsJSON: String? = nil,
        firstObservedAt: Date? = nil,
        contentEditedAt: Date? = nil,
        openReactionObservedAt: Date? = nil,
        resolvedReactionObservedAt: Date? = nil,
        resolvedReactionRemovedAt: Date? = nil
    ) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: threadTS, userID: user,
                        text: text, reactionsJSON: reactionsJSON,
                        firstObservedAt: firstObservedAt,
                        contentEditedAt: contentEditedAt,
                        openReactionObservedAt: openReactionObservedAt,
                        resolvedReactionObservedAt: resolvedReactionObservedAt,
                        resolvedReactionRemovedAt: resolvedReactionRemovedAt,
                        ingestedAt: fixedNow).insert(dbc)
        }
    }

    private func insertItem(
        _ db: AppDatabase,
        id: String = "item-100.0",
        root: String = "100.0",
        type: ItemType = .missedFollowup,
        state: ItemState = .surfaced,
        lastEvaluatedAt: Date? = nil,
        resolutionReason: ResolutionReason? = nil
    ) async throws {
        _ = try await db.dbWriter.write { dbc in
            try Item(id: id, channelID: "C1", rootMessageTS: root, threadTS: root,
                     type: type, state: state, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: lastEvaluatedAt ?? self.fixedNow,
                     snoozedUntil: nil, resolutionReason: resolutionReason).insert(dbc)
        }
    }

    func testSurfacesHighConfidenceQuestion() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout time?")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.type, .missedFollowup)
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.rootMessageTS, "100.0")
    }

    func testContextOnlyCreatesNoItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished, all green")

        try await makeService(db).detectWatchedChannels()

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testLearnedDismissPhraseDismissesActiveItemWithoutCreatingNewItems() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(
            db,
            ts: "100.0",
            user: "U1",
            text: "Automated status report: production is down, can someone investigate?"
        )
        try insert(
            db,
            ts: "200.0",
            user: "U1",
            text: "Automated status report: build failed, can someone investigate?"
        )
        try await insertItem(db, root: "100.0", type: .stale, state: .surfaced)

        let store = PatternStore(database: db)
        try await store.saveManualPattern(
            channelID: nil,
            bucket: .dismiss,
            phrase: "automated status report"
        )
        var service = makeService(db)
        service.patternStore = store

        try await service.detectWatchedChannels()

        let items = try await db.dbWriter.read { try Item.fetchAll($0) }
        XCTAssertEqual(items.count, 1, "suppression must not create hidden tombstone items")
        XCTAssertEqual(items.first?.rootMessageTS, "100.0")
        XCTAssertEqual(items.first?.state, .dismissed)
        let labelCount = try await db.dbWriter.read { try TriageLabel.fetchCount($0) }
        XCTAssertEqual(labelCount, 0, "automatic keyword suppression is not a user triage label")

        try insert(
            db,
            ts: "201.0",
            user: "U2",
            text: "the outage is back",
            threadTS: "100.0",
            firstObservedAt: fixedNow.addingTimeInterval(1)
        )
        try await service.detectChangedRoots(["C1": ["100.0"]])

        let stateAfterReply = try await db.dbWriter.read {
            try Item.fetchOne($0, key: "item-100.0")?.state
        }
        XCTAssertEqual(stateAfterReply, .dismissed, "new activity must not bypass an active dismiss phrase")
    }

    func testAlreadyResolvedThreadDoesNotCreateTransientItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "staging config", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U1", text: "following up on this", threadTS: "100.0")
        try insert(db, ts: "102.0", user: "U2", text: "fixed", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 0, "detection must not briefly surface a thread that is already resolved")
    }

    func testAlreadyResolvedActiveThreadIsClosedDuringDetection() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "staging config", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U1", text: "following up on this", threadTS: "100.0")
        try insert(db, ts: "102.0", user: "U2", text: "fixed", threadTS: "100.0")
        try await insertItem(db, root: "100.0", type: .stale, state: .surfaced)

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testNoUncertainItemIsEverSurfaced() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "is staging up?") // bare question → review

        try await makeService(db).detectWatchedChannels()

        let surfaced = try await db.dbWriter.read {
            try Item.filter(Column("state") == ItemState.surfaced.rawValue).fetchCount($0)
        }
        XCTAssertEqual(surfaced, 0, "ambiguous items must never be surfaced")
        let review = try await db.dbWriter.read {
            try Item.filter(Column("state") == ItemState.review.rawValue).fetchCount($0)
        }
        XCTAssertEqual(review, 1)
    }

    func testReDetectionIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()
        try await svc.detectWatchedChannels()

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 1, "re-running detection must not duplicate items")
    }

    func testDetectionCursorSkipsAlreadyEvaluatedRoots() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished, all green")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()

        let firstCursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(firstCursor, "100.0")

        try insert(db, ts: "099.0", user: "U1", text: "<@U2> can you confirm the old rollout?")
        try insert(db, ts: "101.0", user: "U1", text: "<@U2> can you confirm the new rollout?")

        try await svc.detectWatchedChannels()

        let items = try await db.dbWriter.read { try Item.order(Column("rootMessageTS")).fetchAll($0) }
        XCTAssertEqual(items.map(\.rootMessageTS), ["101.0"], "messages at or below the detection cursor should not be reprocessed")
        let finalCursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(finalCursor, "101.0")
    }

    func testForcedEditedRootIsDetectedEvenBeforeCursor() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db, lastDetectedTS: "500.0")
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?")

        try await makeService(db).detectWatchedChannels(
            forcedRootTSByChannel: ["C1": ["100.0"]]
        )

        let item = try await db.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.rootMessageTS, "100.0")
        XCTAssertEqual(item?.state, .surfaced)
        let cursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(cursor, "500.0", "forcing an old edit must not move the durable cursor backward")
    }

    func testSocketDetectionEvaluatesOnlyNamedRoots() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db, lastDetectedTS: "500.0")
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?")
        try insert(db, ts: "200.0", user: "U1", text: "<@U2> can you review the release notes?")

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let items = try await db.dbWriter.read { try Item.fetchAll($0) }
        XCTAssertEqual(items.map(\.rootMessageTS), ["100.0"])
        let cursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(cursor, "500.0")
    }

    func testTargetedReplyRecheckDoesNotRemoveExistingItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db, lastDetectedTS: "500.0")
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished, all green")
        try await insertItem(db, root: "100.0", type: .stale, state: .surfaced)

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "ordinary thread activity must not act like a source-message edit")
    }

    func testForcedEditRemovesActiveItemWhenRootIsNoLongerActionable() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db, lastDetectedTS: "500.0")
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished, all green")
        try await insertItem(db, root: "100.0", type: .stale, state: .surfaced)

        try await makeService(db).detectWatchedChannels(
            forcedRootTSByChannel: ["C1": ["100.0"]]
        )

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testFollowUpReplyRetagsExistingOpenItemAsStale() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()
        try insert(db, ts: "101.0", user: "U1", text: "following up on this", threadTS: "100.0")
        try await svc.detectWatchedChannels()

        let item = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100.0").fetchOne($0)
        }
        XCTAssertEqual(item?.type, .stale)
        XCTAssertEqual(item?.state, .surfaced)
    }

    func testMentionedRootCreatesMentionItemForConnectedUser() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "FYI <@U_SELF> this changed")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.type, .mention)
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.confidence, 1.0)
    }

    func testLegacyMembershipMentionAndItsDismissalLabelAreRemoved() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(
            db,
            ts: "100.0",
            user: "U_SELF",
            text: "<@U_SELF|Daanish> has joined the channel"
        )
        try await insertItem(db, state: .dismissed)
        try await db.dbWriter.write { database in
            try TriageLabel(
                id: "label-1",
                itemID: "item-100.0",
                messageTS: "100.0",
                channelID: "C1",
                userVerdict: .ignore,
                source: .dismissal,
                createdAt: self.fixedNow
            ).insert(database)
        }

        try await makeService(db).detectWatchedChannels()

        let messageCount = try await db.dbWriter.read { try Message.fetchCount($0) }
        let itemCount = try await db.dbWriter.read { try Item.fetchCount($0) }
        let labelCount = try await db.dbWriter.read { try TriageLabel.fetchCount($0) }
        XCTAssertEqual(messageCount, 0)
        XCTAssertEqual(itemCount, 0)
        XCTAssertEqual(labelCount, 0, "Slack system notices must not influence calibration")
    }

    func testMentionedReplyCreatesMentionItemForOldThreadRoot() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db, lastDetectedTS: "150.0")
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished", threadTS: "100.0")
        try insert(db, ts: "200.0", user: "U2", text: "<@U_SELF> can you take a look?", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.rootMessageTS, "100.0")
        XCTAssertEqual(item?.type, .mention)
        XCTAssertEqual(item?.state, .surfaced)
        let cursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(cursor, "200.0")
    }

    func testMentionOfOtherUserDoesNotCreateMentionItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "FYI <@U_OTHER> this changed")

        try await makeService(db).detectWatchedChannels()

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testMentionInsideFencedLogsDoesNotCreateMentionItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "```\n<@U_SELF> noisy log\n```")

        try await makeService(db).detectWatchedChannels()

        let count = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testMentionDoesNotRetagExistingActiveItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()
        try insert(db, ts: "101.0", user: "U2", text: "<@U_SELF> FYI", threadTS: "100.0")
        try await svc.detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.type, .missedFollowup)
        XCTAssertEqual(item?.state, .surfaced)
    }

    func testDismissedItemRevivesAsMentionOnNewMentionReply() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished", threadTS: "100.0")
        try await insertItem(db, type: .stale, state: .dismissed)
        try insert(db, ts: "1700000001.0", user: "U2", text: "<@U_SELF> this needs you", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.type, .mention)
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
        XCTAssertNil(item?.threadSummary)
        XCTAssertNil(item?.summarizedReplyCount)
    }

    func testResolvedItemRevivesAsMentionOnNewMentionReply() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished", threadTS: "100.0")
        try await insertItem(db, type: .stale, state: .resolved, resolutionReason: .stated)
        try insert(db, ts: "1700000001.0", user: "U2", text: "<@U_SELF> this needs you", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.type, .mention)
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
    }

    func testOldMentionDoesNotReviveDismissedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "deploy finished", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U2", text: "<@U_SELF> old ping", threadTS: "100.0")
        try await insertItem(db, type: .stale, state: .dismissed)

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.type, .stale)
        XCTAssertEqual(item?.state, .dismissed)
    }

    func testActiveRootRecheckDoesNotMoveDetectionCursorBackwards() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedWorkspaceAndChannel(db, lastDetectedTS: "200.0")
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        try await insertItem(db, root: "100.0", type: .missedFollowup, state: .surfaced)

        try await makeService(db).detectWatchedChannels()

        let cursor = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastDetectedTS }
        XCTAssertEqual(cursor, "200.0")
    }

    func testUserResolvedStateIsPreserved() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()
        // User resolves it.
        _ = try await db.dbWriter.write { dbc in
            try Item.filter(Column("rootMessageTS") == "100.0")
                .updateAll(dbc, Column("state").set(to: ItemState.resolved.rawValue))
        }
        // Re-running detection must not resurrect it to surfaced.
        try await svc.detectWatchedChannels()

        let state = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100.0").fetchOne($0)?.state
        }
        XCTAssertEqual(state, .resolved)
    }

    func testNewActionableReplyReopensResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        try await db.dbWriter.write { dbc in
            try Item(id: "item-100.0", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .missedFollowup, state: .resolved, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: self.fixedNow,
                     snoozedUntil: nil, resolutionReason: .stated).insert(dbc)
        }
        try insert(db, ts: "1700000001.0", user: "U2", text: "actually this is failing again, can someone look?", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.type, .stale)
        XCTAssertNil(item?.resolutionReason)
        XCTAssertNil(item?.threadSummary)
        XCTAssertNil(item?.summarizedReplyCount)
    }

    func testProductionImpactReplyReopensResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "can someone eyeball the staging config?", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U2", text: "looks like this config is leading to some prod issues", threadTS: "100.0")
        try await db.dbWriter.write { dbc in
            try Item(id: "item-100.0", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .missedFollowup, state: .resolved, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: self.fixedNow,
                     snoozedUntil: nil, resolutionReason: .stated).insert(dbc)
        }
        try insert(db, ts: "1700000001.0", user: "U2", text: "the issue is affecting prod", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.type, .stale)
        XCTAssertNil(item?.resolutionReason)
    }

    func testNonActionableReplyDoesNotReopenResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        try await db.dbWriter.write { dbc in
            try Item(id: "item-100.0", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .missedFollowup, state: .resolved, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: self.fixedNow,
                     snoozedUntil: nil, resolutionReason: .stated).insert(dbc)
        }
        try insert(db, ts: "1700000001.0", user: "U2", text: "thanks again", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testOldReplyDoesNotReopenResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U2", text: "actually this is failing again, can someone look?", threadTS: "100.0")
        try await db.dbWriter.write { dbc in
            try Item(id: "item-100.0", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .missedFollowup, state: .resolved, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: self.fixedNow,
                     snoozedUntil: nil, resolutionReason: .stated).insert(dbc)
        }

        try await makeService(db).detectWatchedChannels()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved, "reopen only considers replies after the resolution time")
    }

    func testRegexReopensResolvedItemFromEditedOldReply() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "rollout status", threadTS: "100.0")
        try insert(
            db,
            ts: "101.0",
            user: "U2",
            text: "this is still failing",
            threadTS: "100.0",
            firstObservedAt: fixedNow.addingTimeInterval(-60),
            contentEditedAt: fixedNow.addingTimeInterval(1)
        )
        try await insertItem(
            db,
            type: .stale,
            state: .resolved,
            resolutionReason: .stated
        )

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.type, .stale)
        XCTAssertNil(item?.resolutionReason)
    }

    func testNewActionableReplyReopensDismissedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "rollout status", threadTS: "100.0")
        try insert(
            db,
            ts: "101.0",
            user: "U2",
            text: "the outage is back",
            threadTS: "100.0",
            // Local observation ordering remains correct even if Slack/server time and
            // the Mac's clock differ substantially.
            firstObservedAt: fixedNow.addingTimeInterval(1)
        )
        try await insertItem(db, type: .stale, state: .dismissed)

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.type, .stale)
    }

    func testNewOpenReactionReopensResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(
            db,
            ts: "100.0",
            user: "U1",
            text: "rollout status",
            threadTS: "100.0",
            reactionsJSON: #"[{"name":"eyes","count":1}]"#,
            openReactionObservedAt: fixedNow.addingTimeInterval(1)
        )
        try await insertItem(
            db,
            type: .stale,
            state: .resolved,
            resolutionReason: .stated
        )

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.confidence, 1.0)
    }

    func testNewOpenEmojiReplyReopensResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "rollout status", threadTS: "100.0")
        try insert(
            db,
            ts: "101.0",
            user: "U2",
            text: "👀",
            threadTS: "100.0",
            firstObservedAt: fixedNow.addingTimeInterval(1)
        )
        try await insertItem(
            db,
            type: .stale,
            state: .resolved,
            resolutionReason: .stated
        )

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertEqual(item?.confidence, 1.0)
    }

    func testRemovingFinalCheckReactionReopensReactionResolvedItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(
            db,
            ts: "100.0",
            user: "U1",
            text: "rollout status",
            threadTS: "100.0",
            resolvedReactionRemovedAt: fixedNow.addingTimeInterval(1)
        )
        try await insertItem(
            db,
            type: .stale,
            state: .resolved,
            resolutionReason: .reacted
        )

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
    }

    func testNewCheckClosesReopenedThreadEvenWhenRootClassificationDropsBelowReview() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(
            db,
            ts: "100.0",
            user: "U1",
            text: "blocked on the rollout",
            threadTS: "100.0",
            reactionsJSON: #"[{"name":"eyes","count":1},{"name":"white_check_mark","count":1}]"#,
            openReactionObservedAt: fixedNow.addingTimeInterval(-10),
            resolvedReactionObservedAt: fixedNow.addingTimeInterval(1)
        )
        try insert(
            db,
            ts: "101.0",
            user: "U2",
            text: "this is still failing, can someone look?",
            threadTS: "100.0",
            firstObservedAt: fixedNow.addingTimeInterval(-5)
        )
        try await insertItem(db, type: .stale, state: .surfaced)

        try await makeService(db).detectChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testPromotedReviewItemStaysSurfaced() async throws {
        // A bare question lands in review; the user promotes it ("This matters"). A later
        // detection cycle must NOT demote it back to review.
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "is the checkout service on fire again?")
        let svc = makeService(db)

        try await svc.detectWatchedChannels()
        let firstState = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100.0").fetchOne($0)?.state
        }
        XCTAssertEqual(firstState, .review)

        // Simulate the user promoting it to surfaced.
        _ = try await db.dbWriter.write { dbc in
            try Item.filter(Column("rootMessageTS") == "100.0")
                .updateAll(dbc, Column("state").set(to: ItemState.surfaced.rawValue))
        }

        // Re-run detection — the rules still say review, but the promotion must hold.
        try await svc.detectWatchedChannels()
        let finalState = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100.0").fetchOne($0)?.state
        }
        XCTAssertEqual(finalState, .surfaced, "a user-promoted item must not be auto-demoted to review")
    }

    func testAnsweredThreadDoesNotSurface() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try insert(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout?", threadTS: "100.0")
        try insert(db, ts: "101.0", user: "U2", text: "yes, 3pm", threadTS: "100.0")

        try await makeService(db).detectWatchedChannels()

        let surfaced = try await db.dbWriter.read {
            try Item.filter(Column("state") == ItemState.surfaced.rawValue).fetchCount($0)
        }
        XCTAssertEqual(surfaced, 0, "a question answered by the asked party should not surface")
    }
}
