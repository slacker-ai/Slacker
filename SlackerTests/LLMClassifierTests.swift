import XCTest
@testable import Slacker

/// Stub LLM that returns a fixed string and counts calls.
final class StubLLMClient: LLMClient, @unchecked Sendable {
    var response: String
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var lastRequest: LLMRequest?

    init(response: String) { self.response = response }

    func complete(_ request: LLMRequest) async throws -> String {
        lock.lock()
        callCount += 1
        lastRequest = request
        lock.unlock()
        return response
    }
}

final class LLMClassifierParseTests: XCTestCase {
    func testBasePromptTreatsSlackMembershipEventsAsContextOnly() {
        XCTAssertTrue(LLMClassifier.baseSystem.contains(
            "Slack system join/leave notifications are membership events"
        ))
        XCTAssertTrue(LLMClassifier.baseSystem.contains("Always classify them as contextOnly"))
    }

    func testParsesStrictJSON() {
        let v = LLMClassifier.parse(#"{"class":"blocker","confidence":0.9}"#)
        XCTAssertEqual(v?.messageClass, .blocker)
        XCTAssertEqual(v?.confidence, 0.9)
    }

    func testParsesJSONWrappedInCodeFences() {
        let raw = "```json\n{\"class\":\"openQuestion\",\"confidence\":0.7}\n```"
        XCTAssertEqual(LLMClassifier.parse(raw)?.messageClass, .openQuestion)
    }

    func testParsesJSONWithSurroundingProse() {
        let raw = "Sure! Here is the result: {\"class\":\"decisionPending\",\"confidence\":0.6} hope that helps"
        XCTAssertEqual(LLMClassifier.parse(raw)?.messageClass, .decisionPending)
    }

    func testClampsConfidence() {
        XCTAssertEqual(LLMClassifier.parse(#"{"class":"blocker","confidence":5}"#)?.confidence, 1.0)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(LLMClassifier.parse("not json at all"))
        XCTAssertNil(LLMClassifier.parse(#"{"class":"unknownClass","confidence":0.9}"#))
    }
}

final class LLMDetectionIntegrationTests: XCTestCase {
    private func db(_ sensitivity: ChannelSensitivity = .normal) throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true, sensitivity: sensitivity)
                .insert(dbc)
        }
        return db
    }

    private func insert(_ db: AppDatabase, ts: String, user: String, text: String) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: nil, userID: user, text: text,
                        reactionsJSON: nil, ingestedAt: Date(timeIntervalSince1970: 1)).insert(dbc)
        }
    }

    func testLLMNotCalledForRuleResolvedMessages() async throws {
        let database = try db()
        // A high-confidence directed question — rules surface it without the LLM.
        try insert(database, ts: "100.0", user: "U1", text: "<@U2> can you confirm the rollout time?")
        let stub = StubLLMClient(response: #"{"class":"contextOnly","confidence":0.9}"#)
        var svc = DetectionService(database: database, makeID: { "id" })
        svc.llmClassifier = LLMClassifier(client: stub)

        try await svc.detectWatchedChannels()

        XCTAssertEqual(stub.callCount, 0, "LLM must not be called when rules are confident")
    }

    func testApprovedGuidanceCanSuppressSimilarHighConfidenceRuleHit() async throws {
        let database = try db()
        try insert(database, ts: "100.0", user: "U1", text: "Did anyone record todays meeting?")
        let store = PatternStore(database: database)
        try await store.saveActiveGuidanceDocument(
            "Treat general questions asking whether anyone recorded a meeting as context-only."
        )
        let stub = StubLLMClient(response: #"{"class":"contextOnly","confidence":0.95}"#)
        var svc = DetectionService(database: database, makeID: { "id" })
        svc.llmClassifier = LLMClassifier(client: stub)
        svc.patternStore = store

        try await svc.detectWatchedChannels()

        XCTAssertEqual(stub.callCount, 1, "approved guidance must review a surfaced built-in rule hit")
        XCTAssertTrue(stub.lastRequest?.system.contains("questions asking whether anyone recorded a meeting") == true)
        let itemCount = try await database.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(itemCount, 0, "the learned ignore guidance should suppress the semantically equivalent message")
    }

    func testLLMEscalationPromotesAmbiguousToSurfaced() async throws {
        let database = try db()
        // A bare question is review-band for the rules → escalates to LLM.
        try insert(database, ts: "100.0", user: "U1", text: "is staging up?")
        let stub = StubLLMClient(response: #"{"class":"openQuestion","confidence":0.95}"#)
        var svc = DetectionService(database: database, makeID: { "id" })
        svc.llmClassifier = LLMClassifier(client: stub)

        try await svc.detectWatchedChannels()

        XCTAssertEqual(stub.callCount, 1)
        let item = try await database.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.state, .surfaced, "confident LLM verdict surfaces the item")
    }

    func testLLMParseFailureLeavesItemInReview() async throws {
        let database = try db()
        try insert(database, ts: "100.0", user: "U1", text: "is staging up?")
        let stub = StubLLMClient(response: "I cannot answer that")  // unparseable
        var svc = DetectionService(database: database, makeID: { "id" })
        svc.llmClassifier = LLMClassifier(client: stub)

        try await svc.detectWatchedChannels()

        let item = try await database.dbWriter.read { try Item.fetchOne($0) }
        XCTAssertEqual(item?.state, .review, "uncertain LLM output keeps the item in review, never surfaced")
    }
}
