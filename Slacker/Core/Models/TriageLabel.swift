import Foundation
import GRDB

/// User's triage verdict (§4, §7.5).
enum UserVerdict: String, Codable {
    case matters
    case ignore
}

/// Where a label came from (§7.5). Every triage is a labeled example for calibration.
enum LabelSource: String, Codable {
    case reviewTriage = "review_triage"
    case dismissal
    case markResolved = "mark_resolved"
}

/// Calibration training data — the flywheel (§4, §6b-D, §7.5).
struct TriageLabel: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label"

    var id: String          // UUID string
    var itemID: String?
    var messageTS: String
    var channelID: String
    var userVerdict: UserVerdict
    var source: LabelSource
    var createdAt: Date
}
