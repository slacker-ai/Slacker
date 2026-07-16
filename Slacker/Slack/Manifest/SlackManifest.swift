import Foundation

/// Loads the bundled Slack app manifest JSON for a given variant (§5.1).
///
/// The JSON files are the source of truth (also published in the repo/README); this
/// type reads the actual shipped artifact rather than duplicating the scope list in
/// code, so a test can assert the public-only variant truly omits `groups:*`.
enum SlackManifest {
    enum ManifestError: Error, Equatable {
        case resourceMissing(String)
        case malformed
    }

    static func resourceName(for variant: ManifestVariant) -> String {
        switch variant {
        case .publicAndPrivate: return "manifest-public-private"
        case .publicOnly: return "manifest-public-only"
        }
    }

    /// Raw JSON string for the variant, as the user will paste into Slack.
    static func json(for variant: ManifestVariant, bundle: Bundle = .main) throws -> String {
        let name = resourceName(for: variant)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ManifestError.resourceMissing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The user-token scopes declared in the variant's manifest, parsed from the JSON.
    static func userScopes(for variant: ManifestVariant, bundle: Bundle = .main) throws -> [String] {
        let root = try object(for: variant, bundle: bundle)
        guard
              let oauth = root["oauth_config"] as? [String: Any],
              let scopes = oauth["scopes"] as? [String: Any],
              let user = scopes["user"] as? [String] else {
            throw ManifestError.malformed
        }
        return user
    }

    static func socketModeEnabled(for variant: ManifestVariant, bundle: Bundle = .main) throws -> Bool {
        let root = try object(for: variant, bundle: bundle)
        guard let settings = root["settings"] as? [String: Any],
              let enabled = settings["socket_mode_enabled"] as? Bool else {
            throw ManifestError.malformed
        }
        return enabled
    }

    static func userEvents(for variant: ManifestVariant, bundle: Bundle = .main) throws -> [String] {
        let root = try object(for: variant, bundle: bundle)
        guard let settings = root["settings"] as? [String: Any],
              let subscriptions = settings["event_subscriptions"] as? [String: Any],
              let events = subscriptions["user_events"] as? [String] else {
            throw ManifestError.malformed
        }
        return events
    }

    private static func object(
        for variant: ManifestVariant,
        bundle: Bundle
    ) throws -> [String: Any] {
        let raw = try json(for: variant, bundle: bundle)
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError.malformed
        }
        return root
    }
}
