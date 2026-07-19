import Foundation

/// Confidence-gated routing thresholds (§7.3), adjustable per channel sensitivity (§7.5).
struct DetectionThresholds: Equatable {
    var surface: Double = 0.8
    var review: Double = 0.5

    func adjusted(for sensitivity: ChannelSensitivity) -> DetectionThresholds {
        switch sensitivity {
        case .high:   return DetectionThresholds(surface: surface - 0.1, review: review - 0.1)
        case .normal: return self
        case .low:    return DetectionThresholds(surface: surface + 0.1, review: review + 0.1)
        }
    }
}

/// The routing decision for one candidate. `state == nil` means no item is created.
struct Classification: Equatable {
    let type: ItemType?
    let state: ItemState?
    let confidence: Double
    let shouldDismiss: Bool

    init(type: ItemType?, state: ItemState?, confidence: Double, shouldDismiss: Bool = false) {
        self.type = type
        self.state = state
        self.confidence = confidence
        self.shouldDismiss = shouldDismiss
    }

    static let none = Classification(type: nil, state: nil, confidence: 0)
}

/// Orchestrates detection (§7.2–§7.3): rules first, then map to a signal, apply a
/// thread-context resolution heuristic, and route by confidence. The LLM path for
/// ambiguous messages is added in M4 — this is the rules-only orchestrator.
struct Classifier {
    var ruleEngine = RuleEngine()
    var thresholds = DetectionThresholds()

    /// How much a likely-answered thread discounts confidence (rough heuristic;
    /// the first-class ResolutionDetector replaces this in M4).
    private let answeredDiscount = 0.4
    private let staleFollowUpConfidence = 0.9
    private static let staleFollowUpPhrases = [
        "following up",
        "follow up on",
        "follow-up",
        "followup",
        "bumping this",
        "bump this",
        "checking in on this",
        "checking back on this",
        "circling back",
        "any update here",
        "any updates here"
    ]

    func classifyThread(
        rootText: String,
        replies: [Message],
        rootUserID: String?,
        sensitivity: ChannelSensitivity
    ) -> Classification {
        let rootVerdict = ruleEngine.classify(text: rootText)
        if rootVerdict.shouldDismiss {
            return route(rootVerdict, replies: [], rootUserID: rootUserID, sensitivity: sensitivity)
        }
        if hasStaleFollowUpReply(replies) {
            let verdict = RuleVerdict(messageClass: .blocker, confidence: staleFollowUpConfidence)
            return route(verdict, replies: [], rootUserID: rootUserID, sensitivity: sensitivity)
        }
        return route(rootVerdict, replies: replies, rootUserID: rootUserID, sensitivity: sensitivity)
    }

    /// Route a verdict (from rules OR the LLM) into an item state by confidence,
    /// applying the thread-context discount and per-channel sensitivity.
    func route(
        _ verdict: RuleVerdict,
        replies: [Message],
        rootUserID: String?,
        sensitivity: ChannelSensitivity
    ) -> Classification {
        if verdict.shouldDismiss {
            return Classification(type: nil, state: nil, confidence: verdict.confidence, shouldDismiss: true)
        }
        guard let type = signalType(for: verdict.messageClass) else {
            return .none
        }

        var confidence = verdict.confidence

        // Thread context (§7.2): a reply from someone other than the asker suggests
        // the loop may already be closing — discount so we lean toward precision.
        if hasReplyFromOther(replies, asker: rootUserID) {
            confidence *= answeredDiscount
        }

        let t = thresholds.adjusted(for: sensitivity)
        if confidence >= t.surface {
            return Classification(type: type, state: .surfaced, confidence: confidence)
        }
        if confidence >= t.review {
            return Classification(type: type, state: .review, confidence: confidence)
        }
        // Below the review bar: never auto-surface uncertain items (§7.3).
        return Classification(type: nil, state: nil, confidence: confidence)
    }

    private func signalType(for messageClass: MessageClass) -> ItemType? {
        switch messageClass {
        case .openQuestion:                 return .missedFollowup
        case .decisionPending, .blocker:    return .stale
        case .contextOnly:                  return nil
        }
    }

    private func hasReplyFromOther(_ replies: [Message], asker: String?) -> Bool {
        replies.contains { reply in
            guard let user = reply.userID else { return false }
            return user != asker
        }
    }

    private func hasStaleFollowUpReply(_ replies: [Message]) -> Bool {
        replies.contains { reply in
            let text = SlackTextSanitizer.stripFencedBlocks(reply.text).lowercased()
            guard !text.isEmpty else { return false }
            return Self.staleFollowUpPhrases.contains { text.contains($0) }
        }
    }
}
