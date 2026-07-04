import Foundation

/// Intermediate message classes (§6b-C). These map onto surfaced signals:
/// open questions → missed follow-ups; pending decisions + blockers → stale.
enum MessageClass: String, Equatable {
    case openQuestion
    case decisionPending
    case blocker
    case contextOnly
}

/// A rule verdict: the class plus a confidence in [0, 1].
struct RuleVerdict: Equatable {
    let messageClass: MessageClass
    let confidence: Double

    static let contextOnly = RuleVerdict(messageClass: .contextOnly, confidence: 0.0)
}

/// High-confidence, deterministic, LLM-free classification (§7.1).
///
/// Rules handle the easy, unambiguous cases for free; anything they can't place
/// confidently is left to the LLM (M4). Patterns are intentionally narrow — a
/// narrow definition raises precision (§6b).
///
/// The static `base*` banks are the immutable, shipped defaults. A `LearnedPhraseBank`
/// can be injected to extend them per-channel/globally (§7.5, self-evolution) — the
/// merge happens at `init`, composing base + learned into per-instance arrays so the
/// shared static base is never mutated.
struct RuleEngine {

    // MARK: - Base banks (immutable, shipped defaults)

    /// Verbs/phrases that signal a request directed at someone.
    static let baseAsk = [
        "can you", "could you", "can someone", "could someone", "can anyone",
        "can anybody", "who can", "anyone able", "please can", "any chance you",
        "would you mind", "let me know", "please review", "please approve",
        "please send", "please share", "please add", "please confirm",
        "need you to", "need someone to", "need somebody to", "need someone on",
        "can we get", "could we get", "can i get", "could i get",
        "please take a look", "take a look at", "take a look when",
        "follow up with", "check with", "confirm with", "sync with",
        "ping the", "page the", "loop in", "loop them in", "bring in",
        "route this to", "hand this to", "get eyes on", "review this",
        "approve this", "sign off", "send over", "share the", "add the",
    ]
    static let baseBlocker = [
        "blocked on", "blocked by", "blocker", "waiting on", "waiting for",
        "stuck on", "can't proceed", "cannot proceed", "need this to",
        "need access", "missing access", "no access", "need permissions",
        "missing permissions", "can't deploy until", "cannot deploy until",
        "can't merge until", "cannot merge until", "can't ship until",
        "cannot ship until", "held up by", "held up on", "dependent on",
        "depends on", "need approval before", "need signoff before",
        "blocking release", "blocking the release", "blocking deploy",
        "blocking deployment", "blocking ship", "blocking launch",
    ]
    /// Implicit blockers — someone reporting that something is broken / not working.
    /// Curated to stay specific (avoids matching e.g. "broken link") for precision.
    static let baseProblem = [
        "is failing", "are failing", "keeps failing", "build failed", "build is failing",
        "won't build", "wont build", "can't build", "cannot build", "can't run", "cannot run",
        "not working", "doesn't work", "does not work", "isn't working", "having trouble",
        "facing issue", "facing issues", "issue with", "issues with",
        "getting an error", "hitting an error", "throwing an error", "throws an error",
        "getting errors", "fails to", "failed to", "timing out", "timeouts",
        "timeout errors", "latency spike", "latency spikes", "error rate",
        "elevated errors", "5xx", "500s", "degraded", "outage", "incident",
        "prod is down", "production is down", "staging is down", "service is down",
        "prod issue", "prod issues", "production issue", "production issues",
        "affecting prod", "affecting production", "impacting prod", "impacting production",
        "api is down", "deploy failed", "deployment failed", "pipeline failed",
        "pipeline is failing", "tests failed", "tests are failing", "ci is red",
        "ci failed", "job failed", "job is failing", "alerts firing", "alert firing",
    ]
    /// Implicit help requests that may not end in a question mark.
    static let baseHelp = [
        "any idea", "any ideas", "anyone know", "anyone seen", "does anyone", "did anyone",
        "how do i", "how do you", "how can i", "need help", "can't figure", "cannot figure",
        "please help", "not sure how", "not sure why", "any pointers", "any thoughts",
        "what's the right way", "whats the right way", "what is the right way",
        "where do i", "where can i", "who owns", "who is oncall", "who is on-call",
        "who's oncall", "whos oncall", "who can help", "anyone available",
    ]
    static let baseDecision = [
        "should we", "do we want", "are we going to", "which option", "which one",
        "decision on", "need a decision", "do we go with", "thoughts on", "wdyt",
        "can we decide", "need to decide", "pick one", "which approach",
        "which path", "go/no-go", "go no-go", "are we shipping", "ship or hold",
        "approve or reject", "merge or wait", "roll forward or rollback",
    ]
    static let baseDeadline = [
        "by eod", "by end of day", "by tomorrow", "by today", "by monday",
        "by tuesday", "by wednesday", "by thursday", "by friday", "by next week",
        "due ", "deadline", "asap", "by cob", "before eod", "before end of day",
        "before tomorrow", "before launch", "before release", "before deploy",
        "before the deploy", "before the release", "today if possible",
        "this morning", "this afternoon", "this week",
    ]

    /// Handoff/coordination asks that should remain missed-followup style asks even when
    /// the topic contains incident words like "timeouts" or "rollback".
    private static let coordinationAskPhrases = [
        "ping the", "page the", "loop in", "loop them in", "bring in",
        "route this to", "hand this to", "get eyes on", "follow up with",
        "check with", "confirm with", "sync with",
    ]

    /// Every shipped phrase, lowercased — for de-duping learned proposals against the base.
    static let allBasePhrases: Set<String> = Set(
        (baseAsk + baseBlocker + baseProblem + baseHelp + baseDecision + baseDeadline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    )

    /// Minimum length for a learned phrase to be trusted (single short tokens like "fix"
    /// explode false positives — precision over recall).
    static let minLearnedPhraseLength = 4

    /// A learned phrase is admissible only if it's multi-word and long enough. Keeps the
    /// learned overlay from broadening the rules into noise (§6b precision invariant).
    static func isAdmissibleLearnedPhrase(_ raw: String) -> Bool {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard phrase.count >= minLearnedPhraseLength, phrase.contains(" ") else { return false }
        return !allBasePhrases.contains(phrase)
    }

    // MARK: - Per-instance banks (base + learned)

    private let askPhrases: [String]
    private let blockerPhrases: [String]
    private let problemPhrases: [String]
    private let helpPhrases: [String]
    private let decisionPhrases: [String]
    private let deadlinePhrases: [String]

    let learned: LearnedPhraseBank

    init(learned: LearnedPhraseBank = .empty) {
        self.learned = learned
        self.askPhrases = Self.merged(Self.baseAsk, learned.phrases(for: .ask))
        self.blockerPhrases = Self.merged(Self.baseBlocker, learned.phrases(for: .blocker))
        self.problemPhrases = Self.merged(Self.baseProblem, learned.phrases(for: .problem))
        self.helpPhrases = Self.merged(Self.baseHelp, learned.phrases(for: .help))
        self.decisionPhrases = Self.merged(Self.baseDecision, learned.phrases(for: .decision))
        self.deadlinePhrases = Self.merged(Self.baseDeadline, learned.phrases(for: .deadline))
    }

    /// Base + admissible learned phrases (lowercased), de-duplicated.
    private static func merged(_ base: [String], _ learnedPhrases: [String]) -> [String] {
        let admissible = learnedPhrases
            .filter(isAdmissibleLearnedPhrase)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        // Base first (preserves existing precedence); learned appended, no duplicates.
        var seen = Set(base)
        return base + admissible.filter { seen.insert($0).inserted }
    }

    func classify(text rawText: String) -> RuleVerdict {
        let rawText = SlackTextSanitizer.stripFencedBlocks(rawText)
        let text = rawText.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .contextOnly }

        let isDirected = rawText.contains("<@") || rawText.contains("@here") || rawText.contains("@channel")
        let isQuestion = trimmed.hasSuffix("?") || contains(text, askPhrases)
        let hasDeadline = contains(text, deadlinePhrases)

        // Blockers are the strongest stale signal.
        if contains(text, blockerPhrases) {
            return RuleVerdict(messageClass: .blocker, confidence: 0.85)
        }

        // Explicit handoff/help language is an ask, even if the topic is an incident.
        if contains(text, Self.coordinationAskPhrases) {
            return RuleVerdict(messageClass: .openQuestion, confidence: trimmed.hasSuffix("?") ? 0.9 : 0.8)
        }

        // Help requests that may not end in "?".
        if contains(text, helpPhrases) {
            return RuleVerdict(messageClass: .openQuestion, confidence: 0.8)
        }

        // Problem reports ("X is failing", "trying to … but …") are implicit blockers.
        if contains(text, problemPhrases) || isStruggleReport(text) {
            return RuleVerdict(messageClass: .blocker, confidence: 0.8)
        }

        // Pending decisions → stale candidates.
        if contains(text, decisionPhrases) {
            let confidence = trimmed.hasSuffix("?") ? 0.8 : 0.7
            return RuleVerdict(messageClass: .decisionPending, confidence: confidence)
        }

        // Open questions / requests → missed-followup candidates.
        if isQuestion {
            // Directed asks and explicit group asks are high-confidence.
            if isDirected && trimmed.hasSuffix("?") {
                return RuleVerdict(messageClass: .openQuestion, confidence: 0.9)
            }
            if contains(text, askPhrases) {
                let base = trimmed.hasSuffix("?") ? 0.85 : 0.75
                return RuleVerdict(messageClass: .openQuestion, confidence: hasDeadline ? min(0.95, base + 0.05) : base)
            }
            // A bare question with no direction is ambiguous — medium confidence.
            return RuleVerdict(messageClass: .openQuestion, confidence: 0.55)
        }

        // A directed message with a deadline but no question mark — likely an ask.
        if isDirected && hasDeadline {
            return RuleVerdict(messageClass: .openQuestion, confidence: 0.7)
        }

        return .contextOnly
    }

    private func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// "trying to … but …" / "trying to … fail/error" — describing an attempt that isn't working.
    private func isStruggleReport(_ text: String) -> Bool {
        guard text.contains("trying to") || text.contains("attempting to") else { return false }
        return text.contains("but ") || text.contains("fail") || text.contains("error")
            || text.contains("can't") || text.contains("cannot") || text.contains("won't")
    }
}
