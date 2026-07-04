import XCTest
import GRDB
@testable import Slacker

final class ResolutionDetectorTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        return db
    }

    private func addRoot(
        _ db: AppDatabase,
        ts: String,
        user: String,
        text: String,
        reactionsJSON: String? = nil,
        resolvedReactionObservedAt: Date? = nil
    ) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: ts, userID: user, text: text,
                        reactionsJSON: reactionsJSON,
                        resolvedReactionObservedAt: resolvedReactionObservedAt,
                        ingestedAt: fixedNow).insert(dbc)
        }
    }

    private func addReply(
        _ db: AppDatabase,
        ts: String,
        root: String,
        user: String,
        text: String,
        reactionsJSON: String? = nil,
        resolvedReactionObservedAt: Date? = nil
    ) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: root, userID: user, text: text,
                        reactionsJSON: reactionsJSON,
                        resolvedReactionObservedAt: resolvedReactionObservedAt,
                        ingestedAt: fixedNow).insert(dbc)
        }
    }

    private func addItem(_ db: AppDatabase, root: String, type: ItemType, state: ItemState = .surfaced) throws {
        try db.dbWriter.write { dbc in
            try Item(id: "item-\(root)", channelID: "C1", rootMessageTS: root, threadTS: root,
                     type: type, state: state, confidence: 0.9, createdAt: fixedNow,
                     lastEvaluatedAt: fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
    }

    private func detector(_ db: AppDatabase) -> ResolutionDetector {
        ResolutionDetector(database: db, now: { self.fixedNow })
    }

    func testBareReplyDoesNotResolveMissedFollowup() async throws {
        // A non-solution reply ("looking into it") must NOT close the question — that's
        // the LLM solution-judge's job, not the heuristic's.
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "sure, will check")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "a bare reply should not auto-close a question")
    }

    func testPagingNowResolvesCoordinationAsk() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "@Daanish Hindustani can you ping the oncall about the payments timeouts?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "paging now, adding the dashboard link here")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testKeywordReplyResolvesMissedFollowup() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "yep, fixed it")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testActionableReplyContainingCanBeDoneDoesNotResolve() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "@team any final tests we want to do on this? Please let me know.")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "Is there anything pending from performance perspective?")
        try addReply(db, ts: "102.0", root: "100.0", user: "U3", text: "please help - maybe the test on standby DR TB can be done prior to the return of machines")
        try addReply(db, ts: "103.0", root: "100.0", user: "U3", text: "as it is already setup as MetroDR")
        try addReply(db, ts: "104.0", root: "100.0", user: "U3", text: "thanks")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "\"can be done\" is a proposed action, not a completed one")
        XCTAssertNil(item?.resolutionReason)
    }

    func testFencedLogKeywordsDoNotResolve() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "logs from the run:\n```fixed\n✅\n```")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
    }

    func testNewerFailureReplyPreventsOldKeywordFromReclosingReopenedItem() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "yep, fixed it")
        try addReply(db, ts: "102.0", root: "100.0", user: "U1", text: "it's still failing, can someone look?")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "a newer actionable reply must beat an older close signal")
        XCTAssertNil(item?.resolutionReason)
    }

    func testBareReplyDoesNotResolveStale() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "blocked on the API key")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "oof, that's annoying")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "a bare reply must not resolve a blocker/decision")
    }

    func testCheckReactionResolvesAnyType() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "blocked on the API key",
                    reactionsJSON: #"[{"name":"white_check_mark","count":1}]"#)
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testNewerFailureReplyPreventsOldReactionFromReclosingReopenedItem() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "blocked on the API key",
                    reactionsJSON: #"[{"name":"white_check_mark","count":1}]"#)
        try addReply(db, ts: "101.0", root: "100.0", user: "U1", text: "it's still failing, can someone look?")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "a newer actionable reply must beat an older resolved reaction")
        XCTAssertNil(item?.resolutionReason)
    }

    func testNewlyObservedDoneReactionOnOlderMessageResolvesNewerOpenReply() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "blocked on the API key",
                    reactionsJSON: #"[{"name":"white_check_mark","count":1}]"#,
                    resolvedReactionObservedAt: fixedNow)
        try addReply(db, ts: "101.0", root: "100.0", user: "U1", text: "it's still failing, can someone look?")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testResolvedEmojiInReplyTextResolves() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "✅ confirmed")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testResolvedReactionOnReplyResolves() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "confirmed",
                     reactionsJSON: #"[{"name":"thumbsup","count":1}]"#)
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testOpenEmojiDoesNotResolve() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?",
                    reactionsJSON: #"[{"name":"eyes","count":1}]"#)
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
    }

    func testOpenEmojiPreventsFalseResolvedKeywordClose() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "blocked on the rollout")
        try addReply(db, ts: "101.0", root: "100.0", user: "U2", text: "not fixed yet 👀")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced)
        XCTAssertNil(item?.resolutionReason)
    }

    func testResolvedLanguageResolves() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "should we ship the change")
        try addReply(db, ts: "101.0", root: "100.0", user: "U1", text: "done, shipped it")
        try addItem(db, root: "100.0", type: .stale)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testUnansweredItemStaysOpen() async throws {
        let db = try makeDB()
        try addRoot(db, ts: "100.0", user: "U1", text: "<@U2> can you confirm?")
        try addItem(db, root: "100.0", type: .missedFollowup)

        try await detector(db).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-100.0") }
        XCTAssertEqual(item?.state, .surfaced, "no resolution signal → stays surfaced")
    }
}
