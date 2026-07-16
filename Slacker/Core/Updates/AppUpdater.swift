import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the application. Development and test builds have
/// empty update settings, so they never start an updater or make update-feed requests.
@MainActor
final class AppUpdater {
    static let releaseFeedURL = URL(
        string: "https://github.com/slacker-ai/Slacker/releases/latest/download/appcast.xml"
    )!

    struct Configuration: Equatable {
        let feedURL: URL
        let publicEDKey: String
    }

    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let configuration = Self.configuration(from: infoDictionary)
        isConfigured = configuration != nil
        controller = configuration.map { _ in
            SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        if configuration == nil {
            Log.info("Application updates are disabled for this build.")
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static func configuration(from infoDictionary: [String: Any]) -> Configuration? {
        guard let feedValue = infoDictionary["SUFeedURL"] as? String,
              let feedURL = URL(string: feedValue),
              feedURL == releaseFeedURL,
              let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
              !publicEDKey.isEmpty,
              !publicEDKey.contains("$("),
              Data(base64Encoded: publicEDKey)?.count == 32 else {
            return nil
        }
        return Configuration(feedURL: feedURL, publicEDKey: publicEDKey)
    }
}
