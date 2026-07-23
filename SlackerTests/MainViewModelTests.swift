import XCTest
import GRDB
@testable import Slacker

@MainActor
final class MainViewModelTests: XCTestCase {
    private func seed(_ db: AppDatabase, itemState: ItemState = .surfaced, type: ItemType = .missedFollowup) throws {
        try db.dbWriter.write { dbc in
            try AppSettings(id: 1, teamID: "T1").insert(dbc)
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
            try CachedUser(id: "U1", displayName: "gail", realName: "Gail").insert(dbc)
            try Message(channelID: "C1", ts: "100.0", threadTS: nil, userID: "U1",
                        text: "<@U2> can you confirm?", reactionsJSON: nil,
                        ingestedAt: Date(timeIntervalSince1970: 1)).insert(dbc)
            try Item(id: "item-1", channelID: "C1", rootMessageTS: "100.0", threadTS: nil,
                     type: type, state: itemState, confidence: 0.9,
                     createdAt: Date(timeIntervalSince1970: 1),
                     lastEvaluatedAt: Date(timeIntervalSince1970: 1),
                     snoozedUntil: nil, resolutionReason: nil).insert(dbc)
        }
    }

    func testReloadGroupsSurfacedByType() async throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, itemState: .surfaced, type: .missedFollowup)
        let vm = MainViewModel(database: db)

        await vm.reload()

        XCTAssertEqual(vm.missedFollowups.count, 1)
        XCTAssertEqual(vm.staleItems.count, 0)
        XCTAssertEqual(vm.mentions.count, 0)
        XCTAssertEqual(vm.surfacedCount, 1)
        XCTAssertEqual(vm.missedFollowups.first?.channelName, "general")
        XCTAssertEqual(vm.missedFollowups.first?.authorName, "gail")
        XCTAssertEqual(vm.teamID, "T1")
    }

    func testReloadGroupsMentions() async throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, itemState: .surfaced, type: .mention)
        let vm = MainViewModel(database: db)

        await vm.reload()

        XCTAssertEqual(vm.missedFollowups.count, 0)
        XCTAssertEqual(vm.staleItems.count, 0)
        XCTAssertEqual(vm.mentions.count, 1)
        XCTAssertEqual(vm.surfacedCount, 1)
        XCTAssertEqual(vm.mentions.first?.type, .mention)
    }

    func testResolveMovesItemOutAndWritesLabel() async throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let vm = MainViewModel(database: db)
        let evolutionStarted = expectation(description: "resolve starts evolution")
        vm.onTriageLabeled = { channelID, messageTS, verdict, source in
            XCTAssertEqual(channelID, "C1")
            XCTAssertEqual(messageTS, "100.0")
            XCTAssertEqual(verdict, .matters)
            XCTAssertEqual(source, .markResolved)
            evolutionStarted.fulfill()
        }
        await vm.reload()

        await vm.resolve(vm.missedFollowups[0])
        await fulfillment(of: [evolutionStarted], timeout: 1)

        XCTAssertEqual(vm.surfacedCount, 0, "resolved item leaves the attention list")
        let state = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-1")?.state }
        XCTAssertEqual(state, .resolved)
        let labels = try await db.dbWriter.read { try TriageLabel.fetchCount($0) }
        XCTAssertEqual(labels, 1, "triage writes a calibration label")
    }

    func testDismissStartsEvolutionBeforeRemovingRow() async throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let vm = MainViewModel(database: db)
        let evolutionStarted = expectation(description: "dismiss starts evolution")
        vm.onTriageLabeled = { channelID, messageTS, verdict, source in
            XCTAssertEqual(channelID, "C1")
            XCTAssertEqual(messageTS, "100.0")
            XCTAssertEqual(verdict, .ignore)
            XCTAssertEqual(source, .dismissal)
            evolutionStarted.fulfill()
        }
        await vm.reload()

        await vm.dismiss(vm.missedFollowups[0])
        await fulfillment(of: [evolutionStarted], timeout: 1)

        XCTAssertEqual(vm.surfacedCount, 0)
        let state = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-1")?.state }
        XCTAssertEqual(state, .dismissed)
    }

    func testReviewPromoteSurfacesAndLabels() async throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, itemState: .review)
        let vm = MainViewModel(database: db)
        await vm.reload()
        XCTAssertEqual(vm.reviewItems.count, 1)

        await vm.promote(vm.reviewItems[0])

        let state = try await db.dbWriter.read { try Item.fetchOne($0, key: "item-1")?.state }
        XCTAssertEqual(state, .surfaced)
        let verdict = try await db.dbWriter.read { try TriageLabel.fetchOne($0)?.userVerdict }
        XCTAssertEqual(verdict, .matters)
    }

}

final class ItemRowTests: XCTestCase {
    private func row(ts: String) -> ItemRow {
        ItemRow(
            item: Item(id: "i", channelID: "C1", rootMessageTS: ts, threadTS: nil,
                       type: .missedFollowup, state: .surfaced, confidence: 0.9,
                       createdAt: Date(), lastEvaluatedAt: Date(), snoozedUntil: nil, resolutionReason: nil),
            channelName: "general", channelID: "C1", teamID: "T1", snippet: "hi", authorName: "gail"
        )
    }

    func testDeepLinkContainsTeamChannelAndMessage() {
        let url = row(ts: "100.5").deepLink()
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.hasPrefix("slack://channel"))
        XCTAssertTrue(s.contains("team=T1"))
        XCTAssertTrue(s.contains("id=C1"))
        XCTAssertTrue(s.contains("message=100.5"))
    }

    func testAgeTextFormatsHoursAndDays() {
        let base = Date(timeIntervalSince1970: 1000)
        let now = base.addingTimeInterval(3 * 3600)
        XCTAssertEqual(row(ts: "1000").ageText(now: now), "3h ago")
        let later = base.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(row(ts: "1000").ageText(now: later), "2d ago")
    }
}
