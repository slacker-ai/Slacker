import XCTest
@testable import Slacker

final class SlackManifestTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: SlackManifestTests.self) }

    /// The host app bundle holds the manifest resources; in unit tests with a host
    /// app, that is `Bundle.main`. Fall back to the test bundle just in case.
    private func scopes(_ variant: ManifestVariant) throws -> [String] {
        do {
            return try SlackManifest.userScopes(for: variant, bundle: .main)
        } catch {
            return try SlackManifest.userScopes(for: variant, bundle: bundle)
        }
    }

    func testDefaultVariantIncludesPrivateScopes() throws {
        let scopes = try scopes(.publicAndPrivate)
        XCTAssertTrue(scopes.contains("groups:history"))
        XCTAssertTrue(scopes.contains("groups:read"))
        XCTAssertTrue(scopes.contains("channels:history"))
        XCTAssertEqual(scopes.count, 5)
    }

    func testPublicOnlyVariantOmitsGroupScopes() throws {
        let scopes = try scopes(.publicOnly)
        XCTAssertFalse(scopes.contains { $0.hasPrefix("groups:") },
                       "public-only manifest must not request any private-channel scope")
        XCTAssertEqual(Set(scopes), ["channels:history", "channels:read", "users:read"])
    }

    func testNoVariantRequestsDMOrWriteScopes() throws {
        for variant in ManifestVariant.allCases {
            let scopes = try scopes(variant)
            XCTAssertFalse(scopes.contains { $0.hasPrefix("im:") || $0.hasPrefix("mpim:") },
                           "DMs are never read (\(variant))")
            XCTAssertFalse(scopes.contains { $0.hasSuffix(":write") },
                           "no write scopes ever (\(variant))")
        }
    }
}
