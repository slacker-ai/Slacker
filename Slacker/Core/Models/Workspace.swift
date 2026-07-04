import Foundation
import GRDB

/// A connected Slack workspace. Each has its own user token (Keychain) and its own
/// set of channels. Slacker supports several at once (multi-workspace).
struct Workspace: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspace"

    /// Slack team id (e.g. `T0123ABCD`). Also the deep-link `team` parameter.
    var id: String
    var name: String
    /// The connected user's Slack id in this workspace (for grounding/"as {name}").
    var authUserID: String
    /// Which manifest variant was installed for this workspace (public-only vs. +private).
    var manifestVariant: ManifestVariant
    var createdAt: Date
}
