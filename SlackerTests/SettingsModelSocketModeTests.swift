import XCTest
@testable import Slacker

@MainActor
final class SettingsModelSocketModeTests: XCTestCase {
    func testExistingWorkspaceWithoutAppTokenRequiresSocketModeSetup() async throws {
        let db = try seededDatabase()
        let model = SettingsModel(database: db, appTokenProvider: { _ in nil })

        await model.load()

        XCTAssertEqual(model.workspacesNeedingSocketModeSetup.map(\.id), ["T1"])
        XCTAssertEqual(model.socketState(for: try XCTUnwrap(model.workspaces.first)), .setupRequired)
    }

    func testConfiguredWorkspaceDoesNotShowMigrationBlocker() async throws {
        let db = try seededDatabase()
        let model = SettingsModel(database: db, appTokenProvider: { _ in "xapp-configured" })

        await model.load()

        XCTAssertTrue(model.workspacesNeedingSocketModeSetup.isEmpty)
        XCTAssertEqual(model.socketState(for: try XCTUnwrap(model.workspaces.first)), .disconnected)
    }

    func testValidReplacementIsStoredAndRestartsOnlyThatWorkspace() async throws {
        let db = try seededDatabase()
        var stored: (String, String)?
        var restartedWorkspace: String?
        let model = SettingsModel(
            database: db,
            appTokenProvider: { _ in nil },
            storeAppToken: { stored = ($0, $1) },
            validateAppToken: { token in XCTAssertEqual(token, "xapp-new-token") }
        )
        await model.load()
        let workspace = try XCTUnwrap(model.workspaces.first)
        model.appTokenInputs[workspace.id] = "  xapp-new-token  "
        model.onConnectionsChanged = { restartedWorkspace = $0 }

        await model.saveAppToken(for: workspace)

        XCTAssertEqual(stored?.0, "xapp-new-token")
        XCTAssertEqual(stored?.1, "T1")
        XCTAssertEqual(restartedWorkspace, "T1")
        XCTAssertEqual(model.appTokenInputs["T1"], "")
    }

    func testWatchingChannelStartsImmediateBackgroundProcessing() async throws {
        let db = try seededDatabase()
        try await db.dbWriter.write { database in
            try Channel(
                id: "C1", workspaceID: "T1", name: "general",
                isPrivate: false, isWatched: false
            ).insert(database)
        }
        let model = SettingsModel(database: db, appTokenProvider: { _ in "xapp-configured" })
        await model.load()
        let processed = expectation(description: "new channel processing started")
        var receivedWorkspaceID: String?
        var receivedChannelID: String?
        model.onChannelWatched = { workspaceID, channelID in
            receivedWorkspaceID = workspaceID
            receivedChannelID = channelID
            processed.fulfill()
        }

        model.addChannel(try XCTUnwrap(model.channels.first))
        await fulfillment(of: [processed], timeout: 0.5)

        let isWatched = try await db.dbWriter.read {
            try Channel.fetchOne($0, key: "C1")?.isWatched
        }
        XCTAssertEqual(receivedWorkspaceID, "T1")
        XCTAssertEqual(receivedChannelID, "C1")
        XCTAssertEqual(isWatched, true)
    }

    private func seededDatabase() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { database in
            try Workspace(
                id: "T1",
                name: "Acme",
                authUserID: "U1",
                manifestVariant: .publicOnly,
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(database)
        }
        return db
    }
}
