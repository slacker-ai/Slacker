import XCTest
import GRDB
@testable import Slacker

final class IngestionServiceTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func service(_ transport: StubTransport, _ db: AppDatabase) -> IngestionService {
        IngestionService(
            client: SlackClient(transport: transport, sleep: { _ in }),
            database: db,
            now: { self.fixedNow }
        )
    }

    private func watchedChannel(_ db: AppDatabase, id: String = "C1", lastPolledTS: String? = nil) throws {
        try db.dbWriter.write { dbc in
            try Channel(id: id, workspaceID: "T1", name: "general", isPrivate: false, isWatched: true, lastPolledTS: lastPolledTS)
                .insert(dbc)
        }
    }

    func testPollPersistsHistoryAndAdvancesBoundary() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"200.0","user":"U1","text":"newer"},
                  {"ts":"100.0","user":"U2","text":"older"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            // users.info
            return (jsonData(#"{"ok":true,"user":{"id":"U?","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let count = try await db.dbWriter.read { try Message.fetchCount($0) }
        XCTAssertEqual(count, 2)
        let lastPolled = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastPolledTS }
        XCTAssertEqual(lastPolled, "200.0", "boundary advances to newest top-level ts")
    }

    func testThreadRepliesAreCaptured() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"root question?","reply_count":2}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"root question?","thread_ts":"100.0","reply_count":2},
                  {"ts":"101.0","user":"U2","text":"a reply","thread_ts":"100.0"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:101.0") }
        XCTAssertNotNil(reply, "thread reply must be captured, not just the root")
        XCTAssertEqual(reply?.threadTS, "100.0")
    }

    func testReingestionIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        // Always returns the same message regardless of `oldest` — simulates overlap.
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.history") {
                return (jsonData(#"""
                {"ok":true,"messages":[{"ts":"100.0","user":"U1","text":"hi"}],
                 "response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }
        let svc = service(transport, db)

        try await svc.pollWorkspace(workspaceID: "T1", token: "t")
        try await svc.pollWorkspace(workspaceID: "T1", token: "t")

        let count = try await db.dbWriter.read { try Message.fetchCount($0) }
        XCTAssertEqual(count, 1, "re-ingesting the same ts must not duplicate (dedupe on channelID:ts)")
    }

    func testBackfillSendsOldestParam() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "150.0")
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let historyURL = transport.requests
            .compactMap { $0.url?.absoluteString }
            .first { $0.contains("conversations.history") } ?? ""
        XCTAssertTrue(historyURL.contains("oldest=150.0"), "backfill polls from last boundary")
    }

    func testInitialSyncIsBoundedToRecentHistory() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let historyURL = transport.requests
            .compactMap { $0.url }
            .first { $0.absoluteString.contains("conversations.history") }
        let oldest = URLComponents(url: try XCTUnwrap(historyURL), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "oldest" })?.value
        XCTAssertEqual(oldest, "1699740800.000000", "first sync is bounded to the configured recent-history window")
    }

    func testUnknownUsersResolvedAndCached() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"""
                {"ok":true,"messages":[{"ts":"100.0","user":"U7","text":"hi"}],
                 "response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            // users.info for U7
            return (jsonData(#"""
            {"ok":true,"user":{"id":"U7","name":"gail","profile":{"display_name":"gail"}}}
            """#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let cached = try await db.dbWriter.read { try CachedUser.fetchOne($0, key: "U7") }
        XCTAssertEqual(cached?.displayName, "gail")
    }

    func testRefreshesOpenItemThreadsForResolution() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0") // boundary past the old thread
        // An existing open item on an OLD thread (root ts 100.0, before the boundary).
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "<@U2> can you confirm?", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .missedFollowup, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                // No new top-level messages — the old thread won't appear here.
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"<@U2> can you confirm?","thread_ts":"100.0"},
                  {"ts":"600.0","user":"U2","text":"yep, fixed it","thread_ts":"100.0"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U2","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        // The new reply on the old thread must now be in the DB.
        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNotNil(reply, "resolving reply on an old thread must be re-fetched")

        // And the ResolutionDetector should then close the item (explicit "fixed").
        try await ResolutionDetector(database: db, now: { self.fixedNow }).resolveOpenItems()
        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testMissingTrackedThreadDoesNotFailRefreshCycle() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "deleted thread", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "200.0", threadTS: "200.0", userID: "U1",
                        text: "live thread", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "missing", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
            try Item(id: "live", channelID: "C1", rootMessageTS: "200.0", threadTS: "200.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                let ts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "ts" })?.value
                if ts == "100.0" {
                    return (jsonData(#"{"ok":false,"error":"thread_not_found"}"#), makeHTTPResponse(200))
                }
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"200.0","user":"U1","text":"live thread","thread_ts":"200.0"},
                  {"ts":"600.0","user":"U2","text":"new reply","thread_ts":"200.0"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U2","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let droppedItem = try await db.dbWriter.read { try Item.fetchOne($0, key: "missing") }
        let liveItem = try await db.dbWriter.read { try Item.fetchOne($0, key: "live") }
        let liveReply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNil(droppedItem, "missing Slack threads should be dropped so they do not fail every poll")
        XCTAssertNotNil(liveItem, "unrelated tracked threads must be preserved")
        XCTAssertNotNil(liveReply, "refresh should continue after a missing tracked thread")
    }

    func testRefreshesDismissedItemThreadsForMentionRevival() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "old thread", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .dismissed, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"old thread","thread_ts":"100.0"},
                  {"ts":"600.0","user":"U2","text":"<@U_SELF> please check","thread_ts":"100.0"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U2","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNotNil(reply, "new mention replies on dismissed threads must be re-fetched")
    }

    func testNewDoneReactionOnOlderThreadMessageCanResolveNewerOpenText() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "blocked on the API key", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "400.0", threadTS: "100.0", userID: "U1",
                        text: "it's still failing, can someone look?", reactionsJSON: nil,
                        ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"blocked on the API key","thread_ts":"100.0","reactions":[{"name":"white_check_mark","count":1}]},
                  {"ts":"400.0","user":"U1","text":"it's still failing, can someone look?","thread_ts":"100.0"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")
        try await ResolutionDetector(database: db, now: { self.fixedNow }).resolveOpenItems()

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        let root = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:100.0") }
        XCTAssertEqual(root?.resolvedReactionObservedAt, fixedNow)
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testOnlyWatchedChannelsArePolled() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "watched", isPrivate: false, isWatched: true).insert(dbc)
            try Channel(id: "C2", workspaceID: "T1", name: "ignored", isPrivate: false, isWatched: false).insert(dbc)
        }
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let polledChannels = transport.requests
            .compactMap { $0.url }
            .filter { $0.absoluteString.contains("conversations.history") }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "channel" })?.value }
        XCTAssertEqual(polledChannels, ["C1"], "only watched channels are polled")
    }
}
