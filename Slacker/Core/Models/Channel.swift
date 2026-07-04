import Foundation
import GRDB

/// Per-channel detection sensitivity (§7.5). Affects surfacing thresholds.
enum ChannelSensitivity: String, Codable, CaseIterable {
    case low, normal, high
}

/// A Slack channel the user can choose to watch (`docs/IMPLEMENTATION.md` §4).
struct Channel: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "channel"

    /// Slack channel id (e.g. `C0123ABCD`). Globally unique across Slack.
    var id: String
    /// Owning workspace (team id). Empty only for legacy single-workspace rows pre-migration.
    var workspaceID: String
    var name: String
    var isPrivate: Bool
    var isWatched: Bool
    var sensitivity: ChannelSensitivity
    /// Newest Slack `ts` ingested for this channel; drives incremental polling (M2).
    var lastPolledTS: String?
    /// Newest top-level Slack `ts` evaluated by detection; prevents restart reprocessing.
    var lastDetectedTS: String?

    init(
        id: String,
        workspaceID: String,
        name: String,
        isPrivate: Bool,
        isWatched: Bool = false,
        sensitivity: ChannelSensitivity = .normal,
        lastPolledTS: String? = nil,
        lastDetectedTS: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.isPrivate = isPrivate
        self.isWatched = isWatched
        self.sensitivity = sensitivity
        self.lastPolledTS = lastPolledTS
        self.lastDetectedTS = lastDetectedTS
    }
}
