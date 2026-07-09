import XCTest
import GRDB
@testable import Slacker

final class AppSettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        // The PRD/§11 defaults: 48h staleness, choose-don't-default manifest, Anthropic default.
        let settings = AppSettings()
        XCTAssertEqual(settings.stalenessHours, 48)
        XCTAssertEqual(settings.pollIntervalSeconds, 180)
        XCTAssertEqual(settings.summaryRefreshIntervalMinutes, 360)
        XCTAssertEqual(settings.manifestVariant, .publicAndPrivate)
        XCTAssertEqual(settings.llmProvider, .anthropic)
        XCTAssertTrue(settings.selfEvolutionEnabled)
        XCTAssertFalse(settings.onboardingCompleted)
    }

    func testLoadOrCreateInsertsDefaultsThenReturnsSameRow() throws {
        let appDB = try AppDatabase.makeInMemory()

        let created = try appDB.dbWriter.write { db in
            try AppSettings.loadOrCreate(db)
        }
        XCTAssertEqual(created.id, 1)

        // Second call returns the existing row, not a duplicate.
        let reloaded = try appDB.dbWriter.write { db in
            try AppSettings.loadOrCreate(db)
        }
        XCTAssertEqual(created, reloaded)

        let count = try appDB.dbWriter.read { db in
            try AppSettings.fetchCount(db)
        }
        XCTAssertEqual(count, 1, "there must only ever be one settings row")
    }

    func testRoundTripPersistsChanges() throws {
        let appDB = try AppDatabase.makeInMemory()

        try appDB.dbWriter.write { db in
            var settings = try AppSettings.loadOrCreate(db)
            settings.stalenessHours = 24
            settings.llmProvider = .ollama
            settings.onboardingCompleted = true
            try settings.update(db)
        }

        let loaded = try appDB.dbWriter.read { db in
            try AppSettings.fetchOne(db, key: 1)
        }
        XCTAssertEqual(loaded?.stalenessHours, 24)
        XCTAssertEqual(loaded?.llmProvider, .ollama)
        XCTAssertEqual(loaded?.onboardingCompleted, true)
    }
}
