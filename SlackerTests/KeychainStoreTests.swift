import XCTest
@testable import Slacker

final class KeychainStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate from the real app's secrets.
        KeychainStore.service = "com.slacker.Slacker.tests"
        try? KeychainStore.delete(.slackUserToken)
        try? KeychainStore.delete(.llmAPIKey)
        try? KeychainStore.deleteAppToken(workspaceID: "T1")
        try? KeychainStore.deleteAppToken(workspaceID: "T2")
    }

    override func tearDown() {
        try? KeychainStore.delete(.slackUserToken)
        try? KeychainStore.delete(.llmAPIKey)
        try? KeychainStore.deleteAppToken(workspaceID: "T1")
        try? KeychainStore.deleteAppToken(workspaceID: "T2")
        KeychainStore.service = "com.slacker.Slacker"
        super.tearDown()
    }

    func testSetThenGetRoundTrips() throws {
        try KeychainStore.set("xoxp-test-token", for: .slackUserToken)
        let value = try KeychainStore.get(.slackUserToken)
        XCTAssertEqual(value, "xoxp-test-token")
    }

    func testGetReturnsNilWhenAbsent() throws {
        XCTAssertNil(try KeychainStore.get(.llmAPIKey))
    }

    func testSetOverwritesExistingValue() throws {
        try KeychainStore.set("first", for: .llmAPIKey)
        try KeychainStore.set("second", for: .llmAPIKey)
        XCTAssertEqual(try KeychainStore.get(.llmAPIKey), "second")
    }

    func testDeleteRemovesValue() throws {
        try KeychainStore.set("to-be-deleted", for: .slackUserToken)
        try KeychainStore.delete(.slackUserToken)
        XCTAssertNil(try KeychainStore.get(.slackUserToken))
    }

    func testDeleteIsNoOpWhenAbsent() {
        XCTAssertNoThrow(try KeychainStore.delete(.slackUserToken))
    }

    func testAppTokensAreIsolatedByWorkspaceAndReplaceable() throws {
        try KeychainStore.setAppToken("xapp-one", workspaceID: "T1")
        try KeychainStore.setAppToken("xapp-two", workspaceID: "T2")
        try KeychainStore.setAppToken("xapp-one-replaced", workspaceID: "T1")

        XCTAssertEqual(try KeychainStore.getAppToken(workspaceID: "T1"), "xapp-one-replaced")
        XCTAssertEqual(try KeychainStore.getAppToken(workspaceID: "T2"), "xapp-two")
    }

    func testDeleteAppTokenRemovesOnlyThatWorkspace() throws {
        try KeychainStore.setAppToken("xapp-one", workspaceID: "T1")
        try KeychainStore.setAppToken("xapp-two", workspaceID: "T2")

        try KeychainStore.deleteAppToken(workspaceID: "T1")

        XCTAssertNil(try KeychainStore.getAppToken(workspaceID: "T1"))
        XCTAssertEqual(try KeychainStore.getAppToken(workspaceID: "T2"), "xapp-two")
    }

    func testDeletingMigratedWorkspaceRemovesLegacyUserTokenFallback() throws {
        try KeychainStore.set("xoxp-legacy", for: .slackUserToken)

        try KeychainStore.deleteToken(workspaceID: "T1")

        XCTAssertNil(try KeychainStore.get(.slackUserToken))
        XCTAssertNil(try KeychainStore.getToken(workspaceID: "T1"))
    }
}
