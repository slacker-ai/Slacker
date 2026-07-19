import XCTest
import GRDB
@testable import Slacker

final class SummaryServiceTests: XCTestCase {
    // Fixed "now" so day-boundary math is deterministic.
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 ~22:13 UTC
    private var startOfDay: Double { Calendar.current.startOfDay(for: fixedNow).timeIntervalSince1970 }

    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        return db
    }

    private func addMessage(_ db: AppDatabase, ts: Double, text: String) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: String(ts), threadTS: nil, userID: "U1",
                        text: text, reactionsJSON: nil, ingestedAt: fixedNow).insert(dbc)
        }
    }

    private func service(
        _ db: AppDatabase,
        _ llm: LLMClient?,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
        interval: TimeInterval = 0
    ) -> SummaryService {
        SummaryService(
            database: db,
            llm: llm,
            now: now,
            minimumRefreshIntervalSeconds: { interval }
        )
    }

    func testGeneratesSummaryFromTodaysMessages() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "we shipped the release")
        let stub = StubLLMClient(response: "The team shipped the release today.")

        try await service(db, stub).generateDailySummaries(channelIDs: ["C1"])

        let summary = try await db.dbWriter.read { try Summary.fetchAll($0).first }
        XCTAssertEqual(summary?.text, "The team shipped the release today.")
        XCTAssertEqual(stub.callCount, 1)
    }

    func testSummaryPromptStripsFencedLogs() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "deploy update\n```production is down\n5xx errors\n```")
        let stub = StubLLMClient(response: "The deploy had an update.")

        try await service(db, stub).generateDailySummaries(channelIDs: ["C1"])

        XCTAssertTrue(stub.lastRequest?.user.contains("deploy update") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("production is down") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("5xx errors") == true)
    }

    func testSkipsWhenNoMessagesToday() async throws {
        let db = try makeDB()
        // A message from before today should be ignored.
        try addMessage(db, ts: startOfDay - 10_000, text: "yesterday")
        let stub = StubLLMClient(response: "should not be called")

        try await service(db, stub).generateDailySummaries(channelIDs: ["C1"])

        let count = try await db.dbWriter.read { try Summary.fetchCount($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(stub.callCount, 0, "no LLM call when there's nothing to summarize")
    }

    func testGeneratesOnlyForExplicitlyChangedChannels() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "changed channel")
        try await db.dbWriter.write { dbc in
            try Channel(id: "C2", workspaceID: "T1", name: "other", isPrivate: false, isWatched: true).insert(dbc)
            try Message(channelID: "C2", ts: String(self.startOfDay + 200), threadTS: nil,
                        userID: "U2", text: "untouched channel", reactionsJSON: nil,
                        ingestedAt: self.fixedNow).insert(dbc)
        }
        let stub = StubLLMClient(response: "summary")

        try await service(db, stub).generateDailySummaries(channelIDs: ["C1"])

        let summaries = try await db.dbWriter.read { try Summary.fetchAll($0) }
        XCTAssertEqual(summaries.map(\.channelID), ["C1"])
        XCTAssertEqual(stub.callCount, 1)
    }

    func testOncePerDayDoesNotRegenerate() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "activity")
        let stub = StubLLMClient(response: "summary")
        let svc = service(db, stub)

        try await svc.generateDailySummaries(channelIDs: ["C1"])
        try await svc.generateDailySummaries(channelIDs: ["C1"]) // second run same day

        XCTAssertEqual(stub.callCount, 1, "summary is generated at most once per channel per day")
    }

    func testRegeneratesWhenNewActivityArrives() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "early activity")
        let stub = StubLLMClient(response: "summary")
        let svc = service(db, stub)

        try await svc.generateDailySummaries(channelIDs: ["C1"]) // first generation (call 1)

        // A message AFTER the summary was generated (generatedAt == fixedNow) → regenerate.
        try addMessage(db, ts: fixedNow.timeIntervalSince1970 + 10, text: "new activity")
        try await svc.generateDailySummaries(channelIDs: ["C1"])

        XCTAssertEqual(stub.callCount, 2, "summary refreshes when new messages arrive")
    }

    func testDoesNotRegenerateBeforeConfiguredInterval() async throws {
        let db = try makeDB()
        var now = fixedNow
        try addMessage(db, ts: startOfDay + 100, text: "early activity")
        let stub = StubLLMClient(response: "summary")
        let svc = service(db, stub, now: { now }, interval: 6 * 60 * 60)

        try await svc.generateDailySummaries(channelIDs: ["C1"])

        now = fixedNow.addingTimeInterval(10 * 60)
        try addMessage(db, ts: now.timeIntervalSince1970 + 1, text: "new activity too soon")
        try await svc.generateDailySummaries(channelIDs: ["C1"])

        XCTAssertEqual(stub.callCount, 1, "summary should not regenerate on every refresh")

        now = fixedNow.addingTimeInterval(6 * 60 * 60 + 60)
        try addMessage(db, ts: now.timeIntervalSince1970 + 1, text: "new activity after interval")
        try await svc.generateDailySummaries(channelIDs: ["C1"])

        XCTAssertEqual(stub.callCount, 2, "summary regenerates once the configured interval has elapsed")
    }

    func testNoLLMIsNoOp() async throws {
        let db = try makeDB()
        try addMessage(db, ts: startOfDay + 100, text: "activity")

        try await service(db, nil).generateDailySummaries(channelIDs: ["C1"])

        let count = try await db.dbWriter.read { try Summary.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }
}

@MainActor
final class OverviewViewModelTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func testOverviewAggregatesPerChannel() async throws {
        let db = try AppDatabase.makeInMemory()
        let today: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: fixedNow)
        }()
        try await db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
            try Channel(id: "C2", workspaceID: "T1", name: "ignored", isPrivate: false, isWatched: false).insert(dbc)
            try Summary(channelID: "C1", date: today, text: "today's digest", generatedAt: self.fixedNow).insert(dbc)
            try Message(channelID: "C1", ts: "1700000000", threadTS: nil, userID: "U1",
                        text: "hi", reactionsJSON: nil, ingestedAt: self.fixedNow).insert(dbc)
            try Item(id: "i1", channelID: "C1", rootMessageTS: "1700000000", threadTS: nil,
                     type: .missedFollowup, state: .surfaced, confidence: 0.9,
                     createdAt: self.fixedNow, lastEvaluatedAt: self.fixedNow,
                     snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }

        let vm = OverviewViewModel(database: db, now: { self.fixedNow })
        await vm.reload()

        XCTAssertEqual(vm.channels.count, 1, "only watched channels appear")
        XCTAssertEqual(vm.channels.first?.name, "general")
        XCTAssertEqual(vm.channels.first?.summary, "today's digest")
        XCTAssertEqual(vm.channels.first?.openCount, 1)
        XCTAssertEqual(vm.channels.first?.lastActivityTS, "1700000000")
    }
}
