import Foundation
import GRDB

/// Runs detection over the local mirror and maintains `item` rows (§7).
/// UI-free and deterministic (injectable clock + id) for unit testing.
struct DetectionService {
    let database: AppDatabase
    var classifier = Classifier()
    /// Optional LLM disambiguation and approved-guidance precision checks (§7.1).
    /// When nil, detection runs rules-only (M3 behavior).
    var llmClassifier: LLMClassifier?
    /// Optional per-channel calibration (§7.5). When nil, base thresholds are used.
    var calibration: CalibrationService?
    /// Optional learned-pattern store (§7.5, self-evolution). When nil (or no approved
    /// rows), detection uses pure base rules/prompt.
    var patternStore: PatternStore?
    var isSelfEvolutionEnabled: () async -> Bool = { true }
    var now: () -> Date = { Date() }
    var makeID: () -> String = { UUID().uuidString }

    /// States ordinary root reclassification must never overwrite. Terminal items are
    /// reconsidered only by the explicit new-activity reopen path below.
    private static let terminalStates: Set<ItemState> = [.dismissed, .snoozed]

    func detectWatchedChannels(
        forcedRootTSByChannel: [String: Set<String>] = [:]
    ) async throws {
        let channels = try await database.dbWriter.read { db in
            try Channel.filter(Column("isWatched") == true).fetchAll(db)
        }
        for channel in channels {
            try await detectChannel(
                channel,
                forcedRootTS: forcedRootTSByChannel[channel.id] ?? []
            )
        }
    }

    /// Event and lifecycle fast path: evaluate only roots named by the changed batch.
    /// Edited roots may remove an existing item when the edited source is no longer
    /// actionable; ordinary replies/reactions must never implicitly dismiss an item.
    func detectChangedRoots(
        _ rootTSByChannel: [String: Set<String>],
        editedRootTSByChannel: [String: Set<String>] = [:]
    ) async throws {
        let channelIDs = Set(rootTSByChannel.compactMap { channelID, roots in
            roots.isEmpty ? nil : channelID
        })
        guard !channelIDs.isEmpty else { return }

        let channels = try await database.dbWriter.read { db in
            try Channel
                .filter(Column("isWatched") == true)
                .filter(channelIDs.contains(Column("id")))
                .fetchAll(db)
        }
        for channel in channels {
            guard let roots = rootTSByChannel[channel.id], !roots.isEmpty else { continue }
            try await detectChannel(
                channel,
                forcedRootTS: roots,
                removableRootTS: editedRootTSByChannel[channel.id] ?? [],
                onlyRootTS: roots
            )
        }
    }

    func detectChannel(
        _ channel: Channel,
        forcedRootTS: Set<String> = [],
        removableRootTS: Set<String>? = nil,
        onlyRootTS: Set<String>? = nil
    ) async throws {
        let (storedMessages, itemsByRootTS, authUserID) = try await database.dbWriter.read { db in
            var messageRequest = Message
                .filter(Column("channelID") == channel.id)
            var itemRequest = Item
                .filter(Column("channelID") == channel.id)
            if let onlyRootTS {
                messageRequest = messageRequest.filter(
                    onlyRootTS.contains(Column("ts"))
                    || onlyRootTS.contains(Column("threadTS"))
                )
                itemRequest = itemRequest.filter(onlyRootTS.contains(Column("rootMessageTS")))
            }
            let messages = try messageRequest.order(Column("ts")).fetchAll(db)
            let items = try itemRequest.fetchAll(db)
            let workspace = try Workspace.fetchOne(db, key: channel.workspaceID)
            return (messages, Dictionary(uniqueKeysWithValues: items.map { ($0.rootMessageTS, $0) }), workspace?.authUserID ?? "")
        }
        let membershipNotifications = storedMessages.filter {
            SlackSystemMessageFilter.isMembershipNotification(subtype: nil, text: $0.text)
        }
        if !membershipNotifications.isEmpty {
            try await removeMembershipNotifications(
                membershipNotifications,
                channelID: channel.id
            )
            Log.info("Detection[#\(channel.name)]: removed \(membershipNotifications.count) legacy Slack membership notification(s).")
        }
        let messages = storedMessages.filter {
            !SlackSystemMessageFilter.isMembershipNotification(subtype: nil, text: $0.text)
        }
        let removableRootTS = removableRootTS ?? forcedRootTS
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
            if let state = itemsByRootTS[message.ts]?.state,
               state == .resolved || state == .dismissed || state == .snoozed {
                // Terminal roots are handled by the scoped mention/reopen checks below.
                // Reclassifying their original message wastes an LLM call and cannot
                // legally overwrite the user-owned state anyway.
                return false
            }
            if activeRootTS.contains(message.ts) {
                return true
            }
            if mentionedRootTS.contains(message.ts) {
                return true
            }
            if forcedRootTS.contains(message.ts) {
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
            // Resolution is a state transition on an existing item, not a side effect of
            // the root's latest classification. A reopened thread often scores below the
            // review threshold because it already has replies; a newly-added ✅ must still
            // close it.
            if let resolutionReason = resolvedThreadReason(
                existing: existing,
                root: root,
                replies: replies,
                classification: classification
            ) {
                try await resolveOrSkipItem(existing: existing, reason: resolutionReason)
                notSurfaced += 1
                continue
            }
            switch classification.state {
            case .surfaced, .review:
                if classification.state == .surfaced {
                    surfaced += 1
                } else {
                    review += 1
                }
            default: notSurfaced += 1
            }
            try await upsertItem(
                root: root,
                channel: channel,
                classification: classification,
                removeIfNotActionable: removableRootTS.contains(root.ts)
            )
        }
        let mentionRevived = try await reviveMentionedTerminalItems(
            channel: channel,
            messages: messages,
            authUserID: authUserID,
            rootTSFilter: onlyRootTS
        )
        let reopened = try await reopenTerminalItems(
            channel: channel,
            messages: messages,
            classifier: channelClassifier,
            llmClassifier: channelLLM,
            rootTSFilter: onlyRootTS
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

    /// Rules first. Ambiguous candidates go to the LLM, and approved guidance gets a
    /// chance to veto otherwise-confident rule hits. Without guidance, confident rule
    /// results never incur an LLM call.
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
            "Rules classifier[#\(channel.name) ts=\(root.ts)]: signal=\(ruleResult.type?.rawValue ?? "none"), confidence=\(ruleResult.confidence), routed=\(ruleResult.state?.rawValue ?? "none")."
        )

        guard let llmClassifier,
              ruleResult.state == .review || (ruleResult.state == .surfaced && llmClassifier.hasGuidance) else {
            if ruleResult.state == .review {
                Log.info("LLM classifier skipped[#\(channel.name) ts=\(root.ts)]: no LLM configured; leaving rules review verdict.")
            }
            return ruleResult
        }

        // Escalate ambiguous rules, or let approved guidance review a confident rule hit.
        // A parse/call failure always preserves the rule result.
        let context = threadContext(root: root, replies: replies)
        let reason = ruleResult.state == .surfaced ? "applying approved guidance to rules surfaced verdict" : "escalating rules review verdict"
        Log.info("LLM classifier used[#\(channel.name) ts=\(root.ts)]: \(reason).")
        let verdict: RuleVerdict
        do {
            verdict = try await llmClassifier.classify(
                rootText: SlackTextSanitizer.stripFencedBlocks(root.text),
                threadContext: context
            )
        } catch LLMClassifier.ClassificationFailure.parseFailed {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: parse failed; keeping rules verdict.")
            return ruleResult
        } catch LLMClassifier.ClassificationFailure.callFailed(let message) {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: call failed (\(message)); keeping rules verdict.")
            return ruleResult
        } catch {
            Log.info("LLM classifier[#\(channel.name) ts=\(root.ts)]: failed (\(error)); keeping rules verdict.")
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
        let isActionableCandidate = classification.state == .surfaced || classification.state == .review
        let isActiveItem = existing?.state == .open
            || existing?.state == .surfaced
            || existing?.state == .review
        guard isActionableCandidate || isActiveItem else { return nil }
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

    private func upsertItem(
        root: Message,
        channel: Channel,
        classification: Classification,
        removeIfNotActionable: Bool = false
    ) async throws {
        try await database.dbWriter.write { db in
            let existing = try Item
                .filter(Column("channelID") == channel.id && Column("rootMessageTS") == root.ts)
                .fetchOne(db)

            // Ordinary root reclassification never resurrects terminal work. Resolved or
            // dismissed items can return only through `reopenTerminalItems`, which requires
            // activity observed after the user's last decision. Legacy snoozes stay inert.
            if let existing, DetectionService.terminalStates.contains(existing.state) {
                return
            }
            if let existing, existing.state == .resolved {
                return
            }

            guard let type = classification.type, let state = classification.state else {
                // Routine passes never auto-demote an item. A direct Slack edit is
                // different: if the source thread is no longer actionable, remove the
                // stale local item so the dashboard mirrors Slack.
                if removeIfNotActionable, let existing,
                   !DetectionService.terminalStates.contains(existing.state) {
                    _ = try Item.deleteOne(db, key: existing.id)
                }
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
        authUserID: String,
        rootTSFilter: Set<String>? = nil
    ) async throws -> Int {
        guard !authUserID.isEmpty else { return 0 }
        let terminalItems = try await database.dbWriter.read { db in
            var request = Item
                .filter(Column("channelID") == channel.id)
                .filter(Column("state") == ItemState.dismissed.rawValue
                        || Column("state") == ItemState.resolved.rawValue)
            if let rootTSFilter {
                request = request.filter(rootTSFilter.contains(Column("rootMessageTS")))
            }
            return try request.fetchAll(db)
        }

        var revived = 0
        for item in terminalItems {
            let newMention = messages
                .filter { message in
                    (message.ts == item.rootMessageTS || message.threadTS == item.rootMessageTS)
                        && activityDate(for: message) > item.lastEvaluatedAt
                        && mentionsConnectedUser(message, authUserID: authUserID)
                }
                .sorted { activityDate(for: $0) < activityDate(for: $1) }
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

    private func reopenTerminalItems(
        channel: Channel,
        messages: [Message],
        classifier: Classifier,
        llmClassifier: LLMClassifier?,
        rootTSFilter: Set<String>? = nil
    ) async throws -> Int {
        let terminalItems = try await database.dbWriter.read { db in
            var request = Item
                .filter(Column("channelID") == channel.id)
                .filter(Column("state") == ItemState.resolved.rawValue
                        || Column("state") == ItemState.dismissed.rawValue)
            if let rootTSFilter {
                request = request.filter(rootTSFilter.contains(Column("rootMessageTS")))
            }
            return try request.fetchAll(db)
        }

        var reopened = 0
        for item in terminalItems {
            let threadMessages = messages.filter {
                $0.ts == item.rootMessageTS || $0.threadTS == item.rootMessageTS
            }

            let explicitlyReopened = threadMessages.contains { message in
                if let observedAt = message.openReactionObservedAt,
                   observedAt > item.lastEvaluatedAt {
                    return true
                }
                let text = SlackTextSanitizer.stripFencedBlocks(message.text)
                if activityDate(for: message) > item.lastEvaluatedAt,
                   EmojiSignalDetector.hasOpenTextEmoji(text) {
                    return true
                }
                return item.state == .resolved
                    && item.resolutionReason == .reacted
                    && message.resolvedReactionRemovedAt.map { $0 > item.lastEvaluatedAt } == true
            }
            if explicitlyReopened {
                if try await reopen(
                    item: item,
                    type: item.type,
                    state: .surfaced,
                    confidence: 1.0
                ) {
                    reopened += 1
                    Log.info("Reopened item \(item.id) from an explicit reaction change[#\(channel.name)].")
                }
                continue
            }

            let activityAfterClosure = threadMessages
                .filter { activityDate(for: $0) > item.lastEvaluatedAt }
                .sorted { activityDate(for: $0) < activityDate(for: $1) }

            guard !activityAfterClosure.isEmpty else { continue }

            for message in activityAfterClosure {
                let classification = await classifyReopeningReply(
                    message: message,
                    channel: channel,
                    classifier: classifier,
                    llmClassifier: llmClassifier
                )
                guard let type = classification.type, let state = classification.state else { continue }

                if try await reopen(
                    item: item,
                    type: type,
                    state: state,
                    confidence: classification.confidence
                ) {
                    reopened += 1
                    Log.info("Reopened item \(item.id) from new or edited activity[#\(channel.name) ts=\(message.ts)]: signal=\(type.rawValue), confidence=\(classification.confidence), routed=\(state.rawValue).")
                    break
                }
            }
        }
        return reopened
    }

    private func classifyReopeningReply(
        message: Message,
        channel: Channel,
        classifier: Classifier,
        llmClassifier: LLMClassifier?
    ) async -> Classification {
        let regexVerdict = ReopenSignalDetector().classify(text: message.text)
        let phraseVerdict = classifier.ruleEngine.classify(text: message.text)
        let verdict = regexVerdict.confidence >= phraseVerdict.confidence
            ? regexVerdict
            : phraseVerdict
        let ruleResult = classifier.route(
            verdict,
            replies: [],
            rootUserID: message.userID,
            sensitivity: channel.sensitivity
        )
        Log.info(
            "Regex reopen classifier[#\(channel.name) ts=\(message.ts)]: signal=\(ruleResult.type?.rawValue ?? "none"), confidence=\(ruleResult.confidence), routed=\(ruleResult.state?.rawValue ?? "none")."
        )

        guard let llmClassifier,
              ruleResult.state == .review || (ruleResult.state == .surfaced && llmClassifier.hasGuidance) else {
            return ruleResult
        }

        let reason = ruleResult.state == .surfaced ? "applying approved guidance to regex reopen verdict" : "escalating regex reopen review verdict"
        Log.info("LLM reopen classifier used[#\(channel.name) ts=\(message.ts)]: \(reason).")
        do {
            let text = SlackTextSanitizer.stripFencedBlocks(message.text)
            let verdict = try await llmClassifier.classify(rootText: text, threadContext: "[\(message.userID ?? "unknown")] \(text)")
            let routed = classifier.route(verdict, replies: [], rootUserID: message.userID, sensitivity: channel.sensitivity)
            Log.info("LLM reopen classifier[#\(channel.name) ts=\(message.ts)]: class=\(verdict.messageClass.rawValue), confidence=\(verdict.confidence), routed=\(routed.state?.rawValue ?? "none").")
            return routed
        } catch {
            Log.info("LLM reopen classifier[#\(channel.name) ts=\(message.ts)]: failed (\(error)); keeping regex reopen verdict.")
            return ruleResult
        }
    }

    private func reopen(
        item: Item,
        type: ItemType,
        state: ItemState,
        confidence: Double
    ) async throws -> Bool {
        try await database.dbWriter.write { db in
            guard var fresh = try Item.fetchOne(db, key: item.id),
                  fresh.state == .resolved || fresh.state == .dismissed else { return false }
            fresh.type = type
            fresh.state = state
            fresh.confidence = confidence
            fresh.lastEvaluatedAt = now()
            fresh.resolutionReason = nil
            fresh.threadSummary = nil
            fresh.summarizedReplyCount = nil
            try fresh.update(db)
            return true
        }
    }

    private func activityDate(for message: Message) -> Date {
        [message.firstObservedAt, message.contentEditedAt]
            .compactMap { $0 }
            .max()
            ?? Date(timeIntervalSince1970: message.timestamp)
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

    private func removeMembershipNotifications(
        _ messages: [Message],
        channelID: String
    ) async throws {
        let messageTSs = Set(messages.map(\.ts))
        let rootTSs = Set(messages.compactMap { message -> String? in
            guard message.threadTS == nil || message.threadTS == message.ts else { return nil }
            return message.ts
        })
        guard !messageTSs.isEmpty else { return }

        try await database.dbWriter.write { db in
            var messageRequest = Message
                .filter(Column("channelID") == channelID)
                .filter(messageTSs.contains(Column("ts")))
            if !rootTSs.isEmpty {
                messageRequest = Message
                    .filter(Column("channelID") == channelID)
                    .filter(messageTSs.contains(Column("ts")) || rootTSs.contains(Column("threadTS")))
                _ = try Item
                    .filter(Column("channelID") == channelID)
                    .filter(rootTSs.contains(Column("rootMessageTS")))
                    .deleteAll(db)
                _ = try TriageLabel
                    .filter(Column("channelID") == channelID)
                    .filter(rootTSs.contains(Column("messageTS")))
                    .deleteAll(db)
            }
            _ = try messageRequest.deleteAll(db)
        }
    }
}
