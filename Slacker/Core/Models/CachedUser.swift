import Foundation
import GRDB

/// Cached Slack user for grounding (§7) — populated from `users.info`.
/// Distinct from the `SlackUser` API model; this is the persisted DB record.
struct CachedUser: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user"

    /// Slack user id (e.g. `U0123ABCD`).
    var id: String
    var displayName: String?
    var realName: String?

    /// Build a cache record from an API `SlackUser`.
    init(from apiUser: SlackUser) {
        self.id = apiUser.id
        self.displayName = apiUser.profile?.displayName ?? apiUser.name
        self.realName = apiUser.realName ?? apiUser.profile?.realName
    }

    init(id: String, displayName: String?, realName: String?) {
        self.id = id
        self.displayName = displayName
        self.realName = realName
    }
}
