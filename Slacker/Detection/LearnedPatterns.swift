import Foundation

/// Which rule-engine phrase bucket a learned phrase extends (§7.5, self-evolution).
/// Stable string contract — used as the LLM/JSON key and the `learnedPattern.bucket`
/// column, so do not rename cases without a migration.
enum RuleBucket: String, Codable, CaseIterable, Sendable {
    case ask
    case blocker
    case problem
    case help
    case decision
    case deadline

    /// Human-readable label for the Settings review UI.
    var displayName: String {
        switch self {
        case .ask:      return "Directed request"
        case .blocker:  return "Blocker"
        case .problem:  return "Problem report"
        case .help:     return "Help request"
        case .decision: return "Pending decision"
        case .deadline: return "Deadline"
        }
    }
}

/// Runtime-injected, learned phrase additions for `RuleEngine`. Immutable value type;
/// merged with the static base banks at `RuleEngine` init so the shared base is never
/// mutated (each engine instance composes base + injected).
struct LearnedPhraseBank: Sendable, Equatable {
    /// Additional phrases keyed by the bucket they extend.
    private let phrasesByBucket: [RuleBucket: [String]]

    static let empty = LearnedPhraseBank(phrasesByBucket: [:])

    init(phrasesByBucket: [RuleBucket: [String]]) {
        self.phrasesByBucket = phrasesByBucket
    }

    /// Build from learned-pattern rows (already filtered to the active set).
    init(patterns: [LearnedPattern]) {
        var grouped: [RuleBucket: [String]] = [:]
        for pattern in patterns {
            grouped[pattern.bucket, default: []].append(pattern.phrase)
        }
        self.phrasesByBucket = grouped
    }

    func phrases(for bucket: RuleBucket) -> [String] {
        phrasesByBucket[bucket] ?? []
    }

    var isEmpty: Bool { phrasesByBucket.values.allSatisfy(\.isEmpty) }
}
