import XCTest
import GRDB
@testable import Slacker

final class ItemThreadSummaryTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "build is failing", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
        return db
    }

    private func updateRootText(_ db: AppDatabase, _ text: String) throws {
        try db.dbWriter.write { dbc in
            var root = try XCTUnwrap(Message.fetchOne(dbc, key: Message.makeID(channelID: "C1", ts: "100.0")))
            root.text = text
            try root.update(dbc)
        }
    }

    private func addReply(_ db: AppDatabase, ts: String, user: String, text: String) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: "100.0", userID: user, text: text,
                        reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
        }
    }

    private func unresolvedJSON(_ summary: String) -> String {
        #"{"summary":"\#(summary)","resolved":false,"confidence":0.2}"#
    }

    func testSummarizesThreadWithReplies() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "looking into it")
        let stub = StubLLMClient(response: unresolvedJSON("U1 reported a build failure; U2 is investigating."))
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.threadSummary, "U1 reported a build failure; U2 is investigating.")
        XCTAssertEqual(item?.summarizedReplyCount, 1)
        XCTAssertEqual(item?.state, .surfaced, "unresolved thread stays open")
    }

    func testThreadAnalyzerPromptStripsFencedLogs() async throws {
        let db = try makeDB()
        try updateRootText(db, "can someone check this?\n```production is down\nfixed\n```")
        try addReply(db, ts: "101.0", user: "U2", text: "looking now\n```5xx errors\n```")
        let stub = StubLLMClient(response: unresolvedJSON("checking"))
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        XCTAssertTrue(stub.lastRequest?.user.contains("can someone check this?") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("looking now") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("production is down") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("5xx errors") == true)
    }

    func testSkipsThreadsWithoutReplies() async throws {
        let db = try makeDB()
        let stub = StubLLMClient(response: unresolvedJSON("x"))
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        XCTAssertEqual(stub.callCount, 0, "no replies → nothing to analyze")
    }

    func testAnalyzesOnlyExplicitlyChangedRoots() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "looking into it")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "200.0", threadTS: "200.0", userID: "U1",
                        text: "another blocker", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "201.0", threadTS: "200.0", userID: "U2",
                        text: "another reply", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i2", channelID: "C1", rootMessageTS: "200.0", threadTS: "200.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
        let stub = StubLLMClient(response: unresolvedJSON("changed root only"))
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let untouched = try await db.dbWriter.read { try Item.fetchOne($0, key: "i2") }
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertNil(untouched?.threadSummary)
    }

    func testDoesNotRegenerateWhenReplyCountUnchanged() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "looking into it")
        let stub = StubLLMClient(response: unresolvedJSON("summary"))
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])
        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        XCTAssertEqual(stub.callCount, 1, "re-analyzes only when the reply count grows")
    }

    func testLLMResolvesLongResolvedThread() async throws {
        let db = try makeDB()
        // A long back-and-forth ending in resolution, but WITHOUT the heuristic keywords.
        try addReply(db, ts: "101.0", user: "U2", text: "let me check the CI config")
        try addReply(db, ts: "102.0", user: "U1", text: "thanks")
        try addReply(db, ts: "103.0", user: "U2", text: "yeah it was a stale cache, cleared it and green now")
        let stub = StubLLMClient(
            response: #"{"summary":"Build failure caused by a stale cache; cleared and green.","resolved":true,"confidence":0.92}"#
        )
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved, "LLM should auto-close a clearly-resolved long thread")
        XCTAssertEqual(item?.resolutionReason, .inferred)
    }

    func testLowConfidenceDoesNotAutoClose() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "a")
        try addReply(db, ts: "102.0", user: "U1", text: "b")
        try addReply(db, ts: "103.0", user: "U2", text: "maybe fixed? not sure")
        let stub = StubLLMClient(response: #"{"summary":"unclear","resolved":true,"confidence":0.5}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .surfaced, "low-confidence resolution must not auto-close")
    }

    func testResolutionConfidenceThresholdIsEightyPercent() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "cleared the cache, green now")
        let stub = StubLLMClient(response: #"{"summary":"cleared cache and green now","resolved":true,"confidence":0.8}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved, "80% confidence is enough to auto-close")
        XCTAssertEqual(item?.resolutionReason, .inferred)
    }

    func testUnresolvedVerdictDoesNotAutoCloseEvenWithHighConfidence() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "still investigating")
        let stub = StubLLMClient(response: #"{"summary":"still investigating","resolved":false,"confidence":0.86}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .surfaced, "confidence applies to the unresolved verdict too")
    }

    func testLLMDoesNotAutoCloseWhenLatestReplyIsActionable() async throws {
        let db = try makeDB()
        try updateRootText(db, "@team any final tests we want to do on this? Please let me know.")
        try addReply(db, ts: "101.0", user: "U2", text: "Is there anything pending from performance perspective?")
        try addReply(db, ts: "102.0", user: "U3", text: "please help - maybe the test on standby DR TB can be done prior to return")
        let stub = StubLLMClient(response: #"{"summary":"U3 asks for help running the standby DR test before return.","resolved":true,"confidence":0.91}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .surfaced, "a fresh actionable reply must prevent LLM inferred auto-close")
        XCTAssertEqual(item?.threadSummary, "U3 asks for help running the standby DR test before return.")
        XCTAssertNil(item?.resolutionReason)
    }

    func testSingleReplySolutionAutoCloses() async throws {
        let db = try makeDB()
        // A single reply that actually solves it → the LLM closes it (resolveMinReplies = 1).
        try addReply(db, ts: "101.0", user: "U2", text: "cleared the cache, it's green now")
        let stub = StubLLMClient(response: #"{"summary":"resolved by clearing cache","resolved":true,"confidence":0.95}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved, "a single real solution closes the item")
        XCTAssertEqual(item?.resolutionReason, .inferred)
    }

    func testCoordinationAskResolvesWhenReplySaysPagingNow() async throws {
        let db = try makeDB()
        try updateRootText(db, "can you ping the oncall about the payments timeouts?")
        try addReply(db, ts: "101.0", user: "U2", text: "on it - paging now, adding the dashboard link here")
        let stub = StubLLMClient(response: #"{"summary":"U2 is paging on-call and adding the dashboard link.","resolved":true,"confidence":0.86}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved, "doing the requested ping resolves the coordination ask")
        XCTAssertEqual(item?.resolutionReason, .inferred)
    }

    func testApprovedGuidanceIsIncludedInThreadAnalyzerPrompt() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "team-specific done phrase")
        let store = PatternStore(database: db)
        try await store.insertProposals([], guidance: LearnedGuidance(
            id: "g1",
            channelID: "C1",
            text: "In this workspace, 'dashboard linked' means the ping/page handoff is complete.",
            status: .approved,
            version: 1,
            createdAt: fixedNow
        ))
        let stub = StubLLMClient(response: unresolvedJSON("summary"))
        let svc = ItemThreadSummaryService(database: db, llm: stub, patternStore: store, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        XCTAssertTrue(stub.lastRequest?.system.contains("Approved workspace-specific guidance") == true)
        XCTAssertTrue(stub.lastRequest?.system.contains("dashboard linked") == true)
    }

    func testSingleNonSolutionReplyStaysOpen() async throws {
        let db = try makeDB()
        // A "looking into it" reply → LLM says not resolved → stays open.
        try addReply(db, ts: "101.0", user: "U2", text: "looking into it")
        let stub = StubLLMClient(response: #"{"summary":"U2 investigating","resolved":false,"confidence":0.3}"#)
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .surfaced, "a non-solution reply must not close the item")
        XCTAssertEqual(item?.threadSummary, "U2 investigating", "but the summary is still generated")
    }

    func testParseFailureLeavesItemOpen() async throws {
        let db = try makeDB()
        try addReply(db, ts: "101.0", user: "U2", text: "x")
        try addReply(db, ts: "102.0", user: "U2", text: "y")
        try addReply(db, ts: "103.0", user: "U2", text: "z")
        let stub = StubLLMClient(response: "I can't produce JSON")
        let svc = ItemThreadSummaryService(database: db, llm: stub, now: { self.fixedNow })

        try await svc.analyzeOpenThreads(rootsByChannel: ["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.threadSummary, "unparseable output → no summary, no crash")
    }
}
