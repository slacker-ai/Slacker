import XCTest
@testable import Slacker

final class KeychainStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate from the real app's secrets.
        KeychainStore.service = "com.slacker.Slacker.tests"
        try? KeychainStore.delete(.slackUserToken)
        try? KeychainStore.delete(.llmAPIKey)
    }

    override func tearDown() {
        try? KeychainStore.delete(.slackUserToken)
        try? KeychainStore.delete(.llmAPIKey)
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
}
