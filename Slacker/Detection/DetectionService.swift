import Foundation
import GRDB

/// Runs detection over the local mirror and maintains `item` rows (§7).
/// UI-free and deterministic (injectable clock + id) for unit testing.
struct DetectionService {
    let database: AppDatabase
    var classifier = Classifier()
    /// Optional LLM disambiguation for rule-ambiguous candidates (§7.1). When nil,
    /// detection runs rules-only (M3 behavior).
    var llmClassifier: LLMClassifier?
    /// Optional per-channel calibration (§7.5). When nil, base thresholds are used.
    var calibration: CalibrationService?
    /// Optional learned-pattern store (§7.5, self-evolution). When nil (or no approved
    /// rows), detection uses pure base rules/prompt.
    var patternStore: PatternStore?
    var isSelfEvolutionEnabled: () async -> Bool = { true }
    var now: () -> Date = { Date() }
    var makeID: () -> String = { UUID().uuidString }

    /// User-owned states detection must never overwrite. `snoozed` is legacy local data.
    private static let terminalStates: Set<ItemState> = [.dismissed, .snoozed]

    func detectWatchedChannels() async throws {
        let channels = try await database.dbWriter.read { db in
            try Channel.filter(Column("isWatched") == true).fetchAll(db)
        }
        for channel in channels {
            try await detectChannel(channel)
        }
    }

    func detectChannel(_ channel: Channel) async throws {
        let (messages, itemsByRootTS, authUserID) = try await database.dbWriter.read { db in
            let messages = try Message
                .filter(Column("channelID") == channel.id)
                .order(Column("ts"))
                .fetchAll(db)
            let items = try Item
                .filter(Column("channelID") == channel.id)
                .fetchAll(db)
            let workspace = try Workspace.fetchOne(db, key: channel.workspaceID)
            return (messages, Dictionary(uniqueKeysWithValues: items.map { ($0.rootMessageTS, $0) }), workspace?.authUserID ?? "")
        }
        let activeRootTS = Set(itemsByRootTS.values
            .filter { $0.state == .open || $0.state == .surfaced || $0.state == .review }
            .map(\.rootMessageTS))
        let newMentionMessages = messages.filter {
            isAfterDetectionCursor($0.ts, channel: channel) && mentionsConnectedUser($0, authUserID: authUserID)
        }
        let mentionedRootTS = Set(newMentionMessages.map { $0.threadTS ?? $0.ts })

        // Per-channel calibrated thresholds (§7.5), falling back to base.
        var channelClassifier = classifier
        if let calibration {
            channelClassifier.thresholds = try await calibration.thresholds(
                forChannelID: channel.id, base: classifier.thresholds
            )
        }

        // Inject approved learned phrases + LLM guidance (§7.5, self-evolution). Only
        // approved rows are loaded, so unapproved proposals never affect detection.
        var channelLLM = llmClassifier
        if let patternStore, await isSelfEvolutionEnabled() {
            let learned = try await patternStore.activePhraseBank(forChannelID: channel.id)
            if !learned.isEmpty {
                channelClassifier.ruleEngine = RuleEngine(learned: learned)
            }
            let guidance = try await patternStore.activeGuidance(forChannelID: channel.id)
            if !guidance.isEmpty {
                channelLLM?.guidance = guidance
            }
        }

        // Top-level candidates: new standalone messages/thread roots plus active item
        // roots. The cursor avoids archive churn, while active roots are rechecked so new
        // reply context can promote or retag an existing item.
        let roots = messages.filter { message in
            let isRoot = message.threadTS == nil || message.threadTS == message.ts
            guard isRoot else { return false }
            if activeRootTS.contains(message.ts) {
                return true
            }
            if mentionedRootTS.contains(message.ts) {
                return true
            }
            return isAfterDetectionCursor(message.ts, channel: channel)
        }

        var surfaced = 0, review = 0, notSurfaced = 0
        for root in roots {
            let replies = messages.filter { $0.threadTS == root.ts && $0.ts != root.ts }
            let existing = itemsByRootTS[root.ts]
            let hasMention = mentionsConnectedUser(in: [root] + replies, authUserID: authUserID)
            let classification: Classification
            if hasMention && existing == nil {
                classification = Classification(type: .mention, state: .surfaced, confidence: 1.0)
                Log.info("Mention classifier[#\(channel.name) ts=\(root.ts)]: routed=surfaced.")
            } else {
                classification = await classify(
                    root: root, replies: replies, channel: channel,
                    classifier: channelClassifier, llmClassifier: channelLLM
                )
            }
            switch classification.state {
            case .surfaced, .review:
                if let resolutionReason = resolvedThreadReason(existing: existing, root: root, replies: replies, classification: classification) {
                    try await resolveOrSkipItem(existing: existing, reason: resolutionReason)
                    notSurfaced += 1
                    continue
                }
                if classification.state == .surfaced {
                    surfaced += 1
                } else {
                    review += 1
                }
            default: notSurfaced += 1
            }
            try await upsertItem(root: root, channel: channel, classification: classification)
        }
        let mentionRevived = try await reviveMentionedTerminalItems(
            channel: channel,
            messages: messages,
            authUserID: authUserID
        )
        let reopened = try await reopenResolvedItems(
            channel: channel,
            messages: messages,
            classifier: channelClassifier,
            llmClassifier: channelLLM
        )
        let cursorCandidates = roots
            .filter { isAfterDetectionCursor($0.ts, channel: channel) }
            .map(\.ts) + newMentionMessages.map(\.ts)
        if let newestDetectedTS = cursorCandidates.max() {
            _ = try await database.dbWriter.write { db in
                try Channel
                    .filter(key: channel.id)
                    .updateAll(db, Column("lastDetectedTS").set(to: newestDetectedTS))
            }
        }
        Log.info("Detection[#\(channel.name)]: \(roots.count) candidate(s) → \(surfaced) surfaced, \(review) review, \(notSurfaced) not actionable, \(reopened) reopened, \(mentionRevived) mention-revived.")
    }

    /// Rules first; only ambiguous (review-band) candidates are escalated to the LLM
    /// (§7.1) — so the LLM is never called on messages the rules resolve confidently.
    private func classify(
        root: Message,
        replies: [Message],
        channel: Channel,
        classifier: Classifier,
        llmClassifier: LLMClassifier?
    ) async -> Classification {
        let ruleResult = classifier.classifyThread(
            rootText: root.text, replies: replies, rootUserID: root.userID, sensitivity: channel.sensitivity
        )
        Log.info(
            "Regex/rules classifier[#\(channel.name) ts=\(root.ts)]: signal=\(ruleResult.type?.rawValue ?? "none"), confidence=\(ruleResult.confidence), routed=\(ruleResult.state?.rawValue ?? "none")."
        )

        guard ruleResult.state == .review, let llmClassifier else {
            if ruleResult.state == .review {
                Log.info("LLM classifier skipped[#\(channel.name) ts=\(root.ts)]: no LLM configured; leaving regex/rules review verdict.")
            }
            return ruleResult
        }

        // Escalate to the LLM. A parse/call failure leaves the item as "uncertain"
        // (the rules' review result), never crashing or auto-surfacing.
        let context = threadContext(root: root, replies: replies)
        Log.info("LLM classifier used[#\(channel.name) ts=\(root.ts)]: escalating regex/rules review verdict.")
        let verdict: RuleVerdict
        do {
            verdict = try await llmClassifier.classify(
                rootText: SlackTextSanitizer.stripFencedBlocks(root.text),
                threadContext: context
            )
        } catch LLMClassifier.ClassificationFailure.parseFailed {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: parse failed; keeping regex/rules review verdict.")
            return ruleResult
        } catch LLMClassifier.ClassificationFailure.callFailed(let message) {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: call failed (\(message)); keeping regex/rules review verdict.")
            return ruleResult
        } catch {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: failed (\(error)); keeping regex/rules review verdict.")
            return ruleResult
        }
        let routed = classifier.route(verdict, replies: replies, rootUserID: root.userID, sensitivity: channel.sensitivity)
        Log.info(
            "LLM classifier[#\(channel.name) ts=\(root.ts)]: class=\(verdict.messageClass.rawValue), confidence=\(verdict.confidence), routed=\(routed.state?.rawValue ?? "none")."
        )
        return routed
    }

    private func resolvedThreadReason(
        existing: Item?,
        root: Message,
        replies: [Message],
        classification: Classification
    ) -> ResolutionReason? {
        guard classification.state == .surfaced || classification.state == .review else { return nil }
        guard existing?.state != .dismissed && existing?.state != .snoozed else { return nil }

        let item = existing ?? Item(
            id: "candidate",
            channelID: root.channelID,
            rootMessageTS: root.ts,
            threadTS: root.threadTS,
            type: classification.type ?? .stale,
            state: classification.state ?? .review,
            confidence: classification.confidence,
            createdAt: now(),
            lastEvaluatedAt: now(),
            snoozedUntil: nil,
            resolutionReason: nil
        )
        return ResolutionDetector(database: database, now: now).resolution(for: item, root: root, replies: replies)
    }

    private func resolveOrSkipItem(existing: Item?, reason: ResolutionReason) async throws {
        guard let existing, existing.state == .open || existing.state == .surfaced || existing.state == .review else {
            return
        }
        try await database.dbWriter.write { db in
            guard var fresh = try Item.fetchOne(db, key: existing.id),
                  fresh.state == .open || fresh.state == .surfaced || fresh.state == .review else { return }
            fresh.state = .resolved
            fresh.resolutionReason = reason
            fresh.lastEvaluatedAt = now()
            try fresh.update(db)
        }
    }

    private func threadContext(root: Message, replies: [Message]) -> String {
        ([root] + replies)
            .compactMap { message in
                let text = SlackTextSanitizer.stripFencedBlocks(message.text)
                guard !text.isEmpty else { return nil }
                return "[\(message.userID ?? "unknown")] \(text)"
            }
            .joined(separator: "\n")
    }

    private func upsertItem(root: Message, channel: Channel, classification: Classification) async throws {
        try await database.dbWriter.write { db in
            let existing = try Item
                .filter(Column("channelID") == channel.id && Column("rootMessageTS") == root.ts)
                .fetchOne(db)

            // Respect user/terminal states — detection never resurrects dismissed work
            // or legacy snoozed rows. Resolved items can reopen only through
            // `reopenResolvedItems`, which requires a new actionable reply after resolution.
            if let existing, DetectionService.terminalStates.contains(existing.state) {
                return
            }
            if let existing, existing.state == .resolved {
                return
            }

            guard let type = classification.type, let state = classification.state else {
                // No item warranted this pass; leave any existing non-terminal item as-is.
                return
            }

            if var existing {
                if type == .mention && (existing.state == .open || existing.state == .surfaced || existing.state == .review) {
                    return
                }
                // Never auto-demote a surfaced item back to review: a surfaced item may
                // have been user-promoted ("This matters"), and surfaced items should only
                // leave Needs attention via resolution or an explicit user action. Detection
                // may still PROMOTE review → surfaced and refresh type/confidence.
                let nextState: ItemState = (existing.state == .surfaced && state == .review) ? .surfaced : state
                existing.type = type
                existing.state = nextState
                existing.confidence = classification.confidence
                existing.lastEvaluatedAt = now()
                try existing.update(db)
            } else {
                let item = Item(
                    id: makeID(),
                    channelID: channel.id,
                    rootMessageTS: root.ts,
                    threadTS: root.threadTS,
                    type: type,
                    state: state,
                    confidence: classification.confidence,
                    createdAt: now(),
                    lastEvaluatedAt: now(),
                    snoozedUntil: nil,
                    resolutionReason: nil
                )
                try item.insert(db)
            }
        }
    }

    private func reviveMentionedTerminalItems(
        channel: Channel,
        messages: [Message],
        authUserID: String
    ) async throws -> Int {
        guard !authUserID.isEmpty else { return 0 }
        let terminalItems = try await database.dbWriter.read { db in
            try Item
                .filter(Column("channelID") == channel.id)
                .filter(Column("state") == ItemState.dismissed.rawValue
                        || Column("state") == ItemState.resolved.rawValue)
                .fetchAll(db)
        }

        var revived = 0
        for item in terminalItems {
            let newMention = messages
                .filter { message in
                    (message.ts == item.rootMessageTS || message.threadTS == item.rootMessageTS)
                        && isSlackTS(message.ts, after: item.lastEvaluatedAt)
                        && mentionsConnectedUser(message, authUserID: authUserID)
                }
                .sorted { $0.ts < $1.ts }
                .first
            guard let newMention else { continue }

            try await database.dbWriter.write { db in
                guard var fresh = try Item.fetchOne(db, key: item.id),
                      fresh.state == .dismissed || fresh.state == .resolved else { return }
                fresh.type = .mention
                fresh.state = .surfaced
                fresh.confidence = 1.0
                fresh.lastEvaluatedAt = now()
                fresh.resolutionReason = nil
                fresh.threadSummary = nil
                fresh.summarizedReplyCount = nil
                try fresh.update(db)
            }
            revived += 1
            Log.info("Mention revived item \(item.id)[#\(channel.name) ts=\(newMention.ts)].")
        }
        return revived
    }

    private func reopenResolvedItems(
        channel: Channel,
        messages: [Message],
        classifier: Classifier,
        llmClassifier: LLMClassifier?
    ) async throws -> Int {
        let resolvedItems = try await database.dbWriter.read { db in
            try Item
                .filter(Column("channelID") == channel.id)
                .filter(Column("state") == ItemState.resolved.rawValue)
                .fetchAll(db)
        }

        var reopened = 0
        for item in resolvedItems {
            let repliesAfterResolution = messages
                .filter { $0.threadTS == item.rootMessageTS && $0.ts != item.rootMessageTS }
                .filter { isSlackTS($0.ts, after: item.lastEvaluatedAt) }
                .sorted { $0.ts < $1.ts }

            guard !repliesAfterResolution.isEmpty else { continue }

            for reply in repliesAfterResolution {
                let classification = await classifyReopeningReply(
                    reply: reply,
                    channel: channel,
                    classifier: classifier,
                    llmClassifier: llmClassifier
                )
                guard let type = classification.type, let state = classification.state else { continue }

                try await database.dbWriter.write { db in
                    guard var fresh = try Item.fetchOne(db, key: item.id),
                          fresh.state == .resolved else { return }
                    fresh.type = type
                    fresh.state = state
                    fresh.confidence = classification.confidence
                    fresh.lastEvaluatedAt = now()
                    fresh.resolutionReason = nil
                    fresh.threadSummary = nil
                    fresh.summarizedReplyCount = nil
                    try fresh.update(db)
                }
                reopened += 1
                Log.info("Reopened item \(item.id) from new reply[#\(channel.name) ts=\(reply.ts)]: signal=\(type.rawValue), confidence=\(classification.confidence), routed=\(state.rawValue).")
                break
            }
        }
        return reopened
    }

    private func classifyReopeningReply(
        reply: Message,
        channel: Channel,
        classifier: Classifier,
        llmClassifier: LLMClassifier?
    ) async -> Classification {
        let ruleResult = classifier.route(
            classifier.ruleEngine.classify(text: reply.text),
            replies: [],
            rootUserID: reply.userID,
            sensitivity: channel.sensitivity
        )
        Log.info(
            "Regex/rules reopen classifier[#\(channel.name) ts=\(reply.ts)]: signal=\(ruleResult.type?.rawValue ?? "none"), confidence=\(ruleResult.confidence), routed=\(ruleResult.state?.rawValue ?? "none")."
        )

        guard ruleResult.state == .review, let llmClassifier else { return ruleResult }

        Log.info("LLM reopen classifier used[#\(channel.name) ts=\(reply.ts)]: escalating regex/rules review verdict.")
        do {
            let text = SlackTextSanitizer.stripFencedBlocks(reply.text)
            let verdict = try await llmClassifier.classify(rootText: text, threadContext: "[\(reply.userID ?? "unknown")] \(text)")
            let routed = classifier.route(verdict, replies: [], rootUserID: reply.userID, sensitivity: channel.sensitivity)
            Log.info("LLM reopen classifier[#\(channel.name) ts=\(reply.ts)]: class=\(verdict.messageClass.rawValue), confidence=\(verdict.confidence), routed=\(routed.state?.rawValue ?? "none").")
            return routed
        } catch {
            Log.info("LLM reopen classifier[#\(channel.name) ts=\(reply.ts)]: failed (\(error)); keeping regex/rules review verdict.")
            return ruleResult
        }
    }

    private func isSlackTS(_ ts: String, after date: Date) -> Bool {
        guard let value = Double(ts) else { return false }
        return value > date.timeIntervalSince1970
    }

    private func isAfterDetectionCursor(_ ts: String, channel: Channel) -> Bool {
        guard let lastDetectedTS = channel.lastDetectedTS, !lastDetectedTS.isEmpty else {
            return true
        }
        return ts > lastDetectedTS
    }

    private func mentionsConnectedUser(in messages: [Message], authUserID: String) -> Bool {
        messages.contains { mentionsConnectedUser($0, authUserID: authUserID) }
    }

    private func mentionsConnectedUser(_ message: Message, authUserID: String) -> Bool {
        guard !authUserID.isEmpty else { return false }
        let text = SlackTextSanitizer.stripFencedBlocks(message.text)
        return text.contains("<@\(authUserID)>") || text.contains("<@\(authUserID)|")
    }
}
