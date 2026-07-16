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

    private func connectedWorkspace(_ db: AppDatabase, userID: String = "U_SELF") throws {
        try db.dbWriter.write { dbc in
            try Workspace(
                id: "T1", name: "Acme", authUserID: userID,
                manifestVariant: .publicOnly, createdAt: self.fixedNow
            ).insert(dbc)
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

    func testMembershipNotificationsAreNotPersisted() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"500.0","user":"U1","text":"<@U1> has left the group","subtype":"group_leave"},
                  {"ts":"400.0","user":"U1","text":"<@U1> has joined the group","subtype":"group_join"},
                  {"ts":"300.0","user":"U1","text":"<@U1> has left the channel","subtype":"channel_leave"},
                  {"ts":"200.0","user":"U1","text":"<@U1> has joined the channel","subtype":"channel_join"},
                  {"ts":"100.0","user":"U2","text":"ordinary message"}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U2","name":"user"}}"#), makeHTTPResponse(200))
        }

        try await service(transport, db).pollWorkspace(workspaceID: "T1", token: "t")

        let messages = try await db.dbWriter.read { try Message.fetchAll($0) }
        let lastPolled = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.lastPolledTS }
        XCTAssertEqual(messages.map(\.ts), ["100.0"])
        XCTAssertEqual(lastPolled, "500.0", "ignored system history must still advance reconciliation")
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

    func testInitialSyncStartsAtBeginningOfCurrentDay() async throws {
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
        let expected = String(
            format: "%.6f",
            Calendar.autoupdatingCurrent.startOfDay(for: fixedNow).timeIntervalSince1970
        )
        XCTAssertEqual(oldest, expected, "first sync should retrieve only the current day's activity")
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

    func testGapRecoverySkipsUnchangedThreadSnapshots() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: nil, userID: "U1",
                        text: "same root", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.replies") {
                return (jsonData(#"{"ok":true,"messages":[{"ts":"100.0","user":"U1","text":"same root","thread_ts":"100.0"}],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }
        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }

        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")

        XCTAssertTrue(changedBatches.isEmpty, "unchanged snapshots must not trigger downstream analysis")
    }

    func testGapRecoveryRemovesRepliesMissingFromFullSnapshot() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "root", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "101.0", threadTS: "100.0", userID: "U2",
                        text: "deleted in Slack", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.replies") {
                return (jsonData(#"{"ok":true,"messages":[{"ts":"100.0","user":"U1","text":"root","thread_ts":"100.0"}],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }
        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }

        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")
        let deletedReply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:101.0") }

        XCTAssertEqual(changedBatches, [["C1": ["100.0"]]])
        XCTAssertNil(deletedReply, "a full Slack snapshot is authoritative for reply membership")
    }

    func testGapRecoveryFetchesChangedOpenItemThreadForResolution() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
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

        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }
        let cursorRoots = try await ingestion.pollWorkspace(workspaceID: "T1", token: "t")

        XCTAssertTrue(cursorRoots.isEmpty)
        let beforeRecovery = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNil(beforeRecovery, "cursor recovery must not scan old threads")

        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")
        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertEqual(changedBatches, [["C1": ["100.0"]]])
        XCTAssertNotNil(reply, "resolving reply on an old thread must be re-fetched")

        // And the ResolutionDetector should then close the item (explicit "fixed").
        try await ResolutionDetector(database: db, now: { self.fixedNow })
            .resolveChangedRoots(["C1": ["100.0"]])
        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .stated)
    }

    func testMissingTrackedThreadDoesNotFailGapRecoveryBatch() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
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

        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }
        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")

        let droppedItem = try await db.dbWriter.read { try Item.fetchOne($0, key: "missing") }
        let liveItem = try await db.dbWriter.read { try Item.fetchOne($0, key: "live") }
        let liveReply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNil(droppedItem, "missing Slack threads should be dropped so they do not fail every reconciliation")
        XCTAssertNotNil(liveItem, "unrelated tracked threads must be preserved")
        XCTAssertNotNil(liveReply, "refresh should continue after a missing tracked thread")
        XCTAssertEqual(changedBatches, [["C1": ["100.0", "200.0"]]])
    }

    func testGapRecoveryFetchesDismissedItemThreadsForMentionRevival() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try Workspace(
                id: "T1", name: "Acme", authUserID: "U_SELF",
                manifestVariant: .publicOnly, createdAt: self.fixedNow
            ).insert(dbc)
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

        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }
        try await ingestion.pollWorkspace(workspaceID: "T1", token: "t")

        let foregroundReply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertNil(foregroundReply, "dismissed threads should not delay foreground reconciliation")

        let affectedRoots = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")

        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:600.0") }
        XCTAssertEqual(affectedRoots, [["C1": ["100.0"]]])
        XCTAssertNotNil(reply, "new mention replies on dismissed threads must be re-fetched")
    }

    func testGapRecoveryBatchesActiveAndTerminalTrackedThreadsOffCursorPath() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db, lastPolledTS: "500.0")
        let oldDate = fixedNow.addingTimeInterval(-8 * 24 * 60 * 60)
        try await db.dbWriter.write { dbc in
            try Workspace(
                id: "T1", name: "Acme", authUserID: "U_SELF",
                manifestVariant: .publicOnly, createdAt: oldDate
            ).insert(dbc)
            try Message(channelID: "C1", ts: "100.0", threadTS: "100.0", userID: "U1",
                        text: "active thread", reactionsJSON: nil, ingestedAt: oldDate).insert(dbc)
            try Message(channelID: "C1", ts: "200.0", threadTS: "200.0", userID: "U1",
                        text: "old dismissed thread", reactionsJSON: nil, ingestedAt: oldDate).insert(dbc)
            try Item(id: "active", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: oldDate,
                     lastEvaluatedAt: oldDate, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
            try Item(id: "terminal", channelID: "C1", rootMessageTS: "200.0", threadTS: "200.0",
                     type: .stale, state: .dismissed, confidence: 0.9, createdAt: oldDate,
                     lastEvaluatedAt: oldDate, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("conversations.history") {
                return (jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            if url.contains("conversations.replies") {
                let ts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "ts" })?.value ?? ""
                return (jsonData(#"{"ok":true,"messages":[{"ts":"\#(ts)","user":"U1","text":"root","thread_ts":"\#(ts)"}],"response_metadata":{"next_cursor":""}}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }

        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }
        try await ingestion.pollWorkspace(workspaceID: "T1", token: "t")

        func refreshedRoots() -> Set<String> {
            Set(transport.requests.compactMap { request -> String? in
                guard (request.url?.absoluteString ?? "").contains("conversations.replies") else { return nil }
                return URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "ts" })?.value
            })
        }
        XCTAssertEqual(refreshedRoots(), [], "cursor reconciliation must not scan tracked threads")

        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")

        XCTAssertEqual(changedBatches, [["C1": ["100.0", "200.0"]]])
        XCTAssertEqual(refreshedRoots(), ["100.0", "200.0"], "background recovery must inspect tracked threads")
    }

    func testNewDoneReactionOnOlderThreadMessageCanResolveNewerOpenText() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
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

        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }
        _ = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")
        try await ResolutionDetector(database: db, now: { self.fixedNow })
            .resolveChangedRoots(["C1": ["100.0"]])

        let item = try await db.dbWriter.read { try Item.fetchOne($0, key: "i1") }
        let root = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:100.0") }
        XCTAssertEqual(root?.resolvedReactionObservedAt, fixedNow)
        XCTAssertEqual(item?.state, .resolved)
        XCTAssertEqual(item?.resolutionReason, .reacted)
    }

    func testThreadRefreshTracksEditOpenReactionAndFinalCheckRemoval() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
        try watchedChannel(db)
        let originallyObserved = fixedNow.addingTimeInterval(-60)
        try await db.dbWriter.write { dbc in
            try Message(
                channelID: "C1",
                ts: "100.0",
                threadTS: nil,
                userID: "U1",
                text: "fixed",
                reactionsJSON: #"[{"name":"white_check_mark","count":1}]"#,
                firstObservedAt: originallyObserved,
                resolvedReactionObservedAt: originallyObserved,
                ingestedAt: originallyObserved
            ).insert(dbc)
        }
        let transport = StubTransport { request in
            if (request.url?.absoluteString ?? "").contains("conversations.replies") {
                return (jsonData(#"""
                {"ok":true,"messages":[
                  {"ts":"100.0","user":"U1","text":"this is still failing","thread_ts":"100.0","reactions":[{"name":"eyes","count":1}]}
                ],"response_metadata":{"next_cursor":""}}
                """#), makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"user":{"id":"U1","name":"x"}}"#), makeHTTPResponse(200))
        }
        var ingestion = service(transport, db)
        ingestion.tokenProvider = { _ in "t" }

        try await ingestion.refreshThread(
            workspaceID: "T1",
            channelID: "C1",
            threadTS: "100.0"
        )

        let message = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:100.0") }
        XCTAssertEqual(message?.firstObservedAt, originallyObserved)
        XCTAssertEqual(message?.ingestedAt, originallyObserved)
        XCTAssertEqual(message?.contentEditedAt, fixedNow)
        XCTAssertEqual(message?.openReactionObservedAt, fixedNow)
        XCTAssertEqual(message?.resolvedReactionRemovedAt, fixedNow)
    }

    func testTrackedThreadRecoveryUsesBatchesOfTwelveAndThreeRequests() async throws {
        let db = try AppDatabase.makeInMemory()
        try connectedWorkspace(db)
        try watchedChannel(db, lastPolledTS: "500.0")
        try await db.dbWriter.write { dbc in
            try CachedUser(id: "U1", displayName: "user", realName: nil).insert(dbc)
            for index in 1...13 {
                let rootTS = "\(index).0"
                try Message(channelID: "C1", ts: rootTS, threadTS: rootTS, userID: "U1",
                            text: "old", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
                try Item(id: "i\(index)", channelID: "C1", rootMessageTS: rootTS, threadTS: rootTS,
                         type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                         lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
            }
        }
        let transport = TrackedThreadConcurrencyTransport()
        var ingestion = IngestionService(
            client: SlackClient(transport: transport),
            database: db,
            now: { self.fixedNow }
        )
        ingestion.tokenProvider = { _ in "t" }

        let changedBatches = try await ingestion.recoverTrackedItemThreads(workspaceID: "T1")
        let peak = await transport.peakRequestCount
        let requestCount = await transport.replyRequestCount

        XCTAssertEqual(changedBatches.map { $0["C1"]?.count }, [12, 1])
        XCTAssertEqual(requestCount, 13)
        XCTAssertEqual(peak, 3)
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

    func testWatchedChannelsPollWithBoundedConcurrency() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            for index in 1...6 {
                try Channel(
                    id: "C\(index)", workspaceID: "T1", name: "channel-\(index)",
                    isPrivate: false, isWatched: true
                ).insert(dbc)
            }
        }
        let transport = ConcurrencyTrackingTransport()
        let ingestion = IngestionService(
            client: SlackClient(transport: transport),
            database: db,
            now: { self.fixedNow }
        )

        try await ingestion.pollWorkspace(workspaceID: "T1", token: "t")

        let peak = await transport.peakRequestCount
        XCTAssertEqual(peak, 3, "Slack polling should hide latency without creating an unbounded request burst")
    }

    func testIndependentEventRefreshesShareTheGlobalRequestLimit() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        let transport = ConcurrencyTrackingTransport()
        let ingestion = IngestionService(
            client: SlackClient(transport: transport),
            database: db,
            now: { self.fixedNow },
            tokenProvider: { _ in "t" }
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...6 {
                group.addTask {
                    try await ingestion.refreshThread(
                        workspaceID: "T1",
                        channelID: "C1",
                        threadTS: "\(index).0"
                    )
                }
            }
            try await group.waitForAll()
        }

        let peak = await transport.peakRequestCount
        XCTAssertEqual(peak, 3, "live events and lifecycle work must share one Slack request budget")
    }

    func testDeletingRootRemovesThreadAndItem() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: nil, userID: "U1",
                        text: "root", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "101.0", threadTS: "100.0", userID: "U2",
                        text: "reply", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "100.0", threadTS: "100.0",
                     type: .stale, state: .surfaced, confidence: 0.9, createdAt: self.fixedNow,
                     lastEvaluatedAt: self.fixedNow, snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
        let transport = StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }

        let returnedRoot = try await service(transport, db).removeLocalMessage(
            channelID: "C1", messageTS: "100.0"
        )

        XCTAssertNil(returnedRoot)
        let messageCount = try await db.dbWriter.read { try Message.fetchCount($0) }
        let itemCount = try await db.dbWriter.read { try Item.fetchCount($0) }
        XCTAssertEqual(messageCount, 0)
        XCTAssertEqual(itemCount, 0)
    }

    func testDeletingReplyReturnsRootForTargetedRefresh() async throws {
        let db = try AppDatabase.makeInMemory()
        try watchedChannel(db)
        try await db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: "100.0", threadTS: nil, userID: "U1",
                        text: "root", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "101.0", threadTS: "100.0", userID: "U2",
                        text: "reply", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
        }
        let transport = StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }

        let returnedRoot = try await service(transport, db).removeLocalMessage(
            channelID: "C1", messageTS: "101.0"
        )

        XCTAssertEqual(returnedRoot, "100.0")
        let root = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:100.0") }
        let reply = try await db.dbWriter.read { try Message.fetchOne($0, key: "C1:101.0") }
        XCTAssertNotNil(root)
        XCTAssertNil(reply)
    }
}

private actor ConcurrencyTrackingTransport: HTTPTransport {
    private var activeRequestCount = 0
    private(set) var peakRequestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        activeRequestCount += 1
        peakRequestCount = max(peakRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }

        try await Task.sleep(nanoseconds: 20_000_000)
        return (
            jsonData(#"{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}"#),
            makeHTTPResponse(200)
        )
    }
}

private actor TrackedThreadConcurrencyTransport: HTTPTransport {
    private var activeRequestCount = 0
    private(set) var peakRequestCount = 0
    private(set) var replyRequestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        activeRequestCount += 1
        peakRequestCount = max(peakRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }
        try await Task.sleep(nanoseconds: 10_000_000)

        let url = request.url?.absoluteString ?? ""
        guard url.contains("conversations.replies") else {
            return (jsonData(#"{"ok":true}"#), makeHTTPResponse(200))
        }
        replyRequestCount += 1
        let rootTS = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ts" })?.value ?? "0.0"
        return (
            jsonData(#"{"ok":true,"messages":[{"ts":"\#(rootTS)","user":"U1","text":"new","thread_ts":"\#(rootTS)"}],"response_metadata":{"next_cursor":""}}"#),
            makeHTTPResponse(200)
        )
    }
}
