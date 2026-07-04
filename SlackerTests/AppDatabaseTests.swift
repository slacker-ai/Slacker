import XCTest
import GRDB
@testable import Slacker

final class AppDatabaseTests: XCTestCase {
    func testMigrationsCreateAppSettingsTable() throws {
        // Arrange + Act
        let appDB = try AppDatabase.makeInMemory()

        // Assert
        let exists = try appDB.dbWriter.read { db in
            try db.tableExists("appSettings")
        }
        XCTAssertTrue(exists, "appSettings table should exist after migration")
    }

    func testMigrationsAreIdempotent() throws {
        // Running the migrator twice on the same connection must not throw.
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        XCTAssertNoThrow(try AppDatabase(queue))
    }
}
