import Foundation
import GRDB

/// Lifecycle of a learned pattern/guidance proposal (§7.5, self-evolution).
/// Detection only ever consumes `approved` rows, so a proposal is inert until a human
/// approves it in Settings — precision can never silently regress.
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
    /// Hand-entered by the user (reserved for a future manual-add affordance).
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
    /// The LLM's one-line reason, shown in the review UI.
    var rationale: String?
    /// How many labeled examples supported this proposal (review signal).
    var supportingLabelCount: Int
    var createdAt: Date
    /// When approved/rejected/retired; nil while `proposed`.
    var decidedAt: Date?
}
