import Foundation
import GRDB

/// Lifecycle of a learned pattern/guidance row (§7.5, self-evolution). New automatic
/// evolution writes approved rows; the other states preserve older database history.
enum PatternStatus: String, Codable, Sendable {
    case proposed
    case approved
    case rejected
    case retired
}

/// How a learned pattern was created.
enum PatternSource: String, Codable, Sendable {
    /// Mined by the evolution loop from labeled examples.
    case llm
    /// Hand-entered by the user in Settings.
    case manual
}

/// A learned rule-engine phrase, mined from this workspace's triage labels (§7.5).
/// `channelID == nil` means the phrase applies globally; otherwise it's scoped to one
/// channel. Stored in the `learnedPattern` table; injected into `RuleEngine` only when
/// `status == .approved`.
struct LearnedPattern: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learnedPattern"

    var id: String              // UUID string
    var channelID: String?      // nil = global
    var bucket: RuleBucket
    var phrase: String
    var status: PatternStatus
    var source: PatternSource
    /// The LLM's one-line reason, shown with the active phrase in Settings.
    var rationale: String?
    /// How many labeled examples supported this proposal (review signal).
    var supportingLabelCount: Int
    var createdAt: Date
    /// When approved/rejected/retired; nil while `proposed`.
    var decidedAt: Date?

    init(
        id: String,
        channelID: String?,
        bucket: RuleBucket,
        phrase: String,
        status: PatternStatus,
        source: PatternSource,
        rationale: String?,
        supportingLabelCount: Int,
        createdAt: Date,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.bucket = bucket
        self.phrase = phrase
        self.status = status
        self.source = source
        self.rationale = rationale
        self.supportingLabelCount = supportingLabelCount
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}
