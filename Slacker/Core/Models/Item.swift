import Foundation
import GRDB

/// The surfaced action signals (§3, §6b).
enum ItemType: String, Codable {
    case missedFollowup = "missed_followup"
    case stale
    case mention
}

/// Item lifecycle (§4). Only `surfaced` items appear in Needs attention.
enum ItemState: String, Codable {
    case open       // detected, not yet routed
    case surfaced   // high-confidence → Needs attention
    case review     // ambiguous → review queue
    case resolved
    case dismissed
    case snoozed    // legacy state kept so existing local databases still decode
}

/// Why an item was auto-closed (§6b-R / §7.4).
enum ResolutionReason: String, Codable {
    case replied
    case reacted
    case stated
    /// LLM judged the thread resolved from its full content (long/implicit resolutions).
    case inferred
}

/// The unit of attention (§4). Populated by detection in M3+.
struct Item: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item"

    var id: String           // UUID string
    var channelID: String
    var rootMessageTS: String
    var threadTS: String?
    var type: ItemType
    var state: ItemState
    var confidence: Double
    var createdAt: Date
    var lastEvaluatedAt: Date
    var snoozedUntil: Date?
    var resolutionReason: ResolutionReason?
    /// LLM summary of the thread for this open item (§ user request); nil until generated.
    var threadSummary: String? = nil
    /// Reply count at the time the summary was generated, so it can be refreshed when the thread grows.
    var summarizedReplyCount: Int? = nil
}
