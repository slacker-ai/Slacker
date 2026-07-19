import Foundation
import GRDB

/// A learned "skill" guidance block for the LLM classifier, mined from this workspace's
/// triage labels (§7.5, self-evolution). Appended to `LLMClassifier`'s stable base
/// prompt only when `status == .approved`. `channelID == nil` means global.
///
/// Guidance is versioned on automatic append, condensation, and manual edit.
struct LearnedGuidance: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learnedGuidance"

    var id: String              // UUID string
    var channelID: String?      // nil = global
    var text: String
    var status: PatternStatus
    var version: Int
    var createdAt: Date
    var decidedAt: Date?

    init(
        id: String,
        channelID: String?,
        text: String,
        status: PatternStatus,
        version: Int,
        createdAt: Date,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.text = text
        self.status = status
        self.version = version
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}
