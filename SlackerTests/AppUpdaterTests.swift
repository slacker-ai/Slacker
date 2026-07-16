import Foundation
import XCTest
@testable import Slacker

@MainActor
final class AppUpdaterTests: XCTestCase {
    private let validKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

    func testAcceptsSecureFeedAndEdDSAPublicKey() throws {
        let configuration = try XCTUnwrap(AppUpdater.configuration(from: [
            "SUFeedURL": "https://github.com/slacker-ai/Slacker/releases/latest/download/appcast.xml",
            "SUPublicEDKey": validKey,
        ]))

        XCTAssertEqual(
            configuration.feedURL.absoluteString,
            "https://github.com/slacker-ai/Slacker/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(configuration.publicEDKey, validKey)
    }

    func testRejectsMissingOrInsecureReleaseConfiguration() {
        XCTAssertNil(AppUpdater.configuration(from: [:]))
        XCTAssertNil(AppUpdater.configuration(from: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": validKey,
        ]))
        XCTAssertNil(AppUpdater.configuration(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": validKey,
        ]))
        XCTAssertNil(AppUpdater.configuration(from: [
            "SUFeedURL": "https://github.com/slacker-ai/Slacker/releases/latest/download/other.xml",
            "SUPublicEDKey": validKey,
        ]))
        XCTAssertNil(AppUpdater.configuration(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "not-a-valid-key",
        ]))
        XCTAssertNil(AppUpdater.configuration(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
        ]))
    }

    func testUnconfiguredBuildDoesNotStartUpdater() {
        let updater = AppUpdater(infoDictionary: [:])

        XCTAssertFalse(updater.isConfigured)
        updater.checkForUpdates()
    }
}
