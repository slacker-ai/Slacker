import Foundation
import GRDB

/// Closes loops that have already been handled (§6b-R / §7.4). This is the top
/// false-positive lever: an answered question must auto-close before it nags the user.
/// Re-checks the WHOLE thread, not just the original message.
struct ResolutionDetector {
    let database: AppDatabase
    var now: () -> Date = { Date() }
    private let ruleEngine = RuleEngine()

    /// Words/phrases that explicitly state completion.
    private static let resolvedWords = [
        "done", "resolved", "shipped", "fixed", "merged", "completed", "ship it",
        "sorted", "all set", "taken care of", "closing this",
    ]
    private static let coordinationAskPhrases = [
        "ping", "page", "notify", "forward", "send to", "loop in", "looping in",
        "hand off", "handoff", "escalate"
    ]
    private static let coordinationResolvedPhrases = [
        "paging now", "paged", "pinged", "notified", "sent", "forwarded",
        "looping them in", "looped them in", "adding the dashboard link",
        "on it"
    ]
    private static let speculativeResolutionPhrases = [
        "can be done", "could be done", "should be done", "would be done",
        "will be done", "may be done", "might be done", "to be done",
        "can be completed", "could be completed", "should be completed",
        "would be completed", "will be completed", "may be completed",
        "might be completed", "to be completed"
    ]

    /// States still in play that resolution may close.
    private static let openStates: [ItemState] = [.open, .surfaced, .review]

    func resolveChangedRoots(_ rootsByChannel: [String: Set<String>]) async throws {
        var items: [Item] = []
        for channelID in rootsByChannel.keys.sorted() {
            guard let roots = rootsByChannel[channelID], !roots.isEmpty else { continue }
            let channelItems = try await database.dbWriter.read { db in
                try Item
                    .filter(Column("channelID") == channelID)
                    .filter(roots.contains(Column("rootMessageTS")))
                    .filter(ResolutionDetector.openStates.map(\.rawValue).contains(Column("state")))
                    .fetchAll(db)
            }
            items.append(contentsOf: channelItems)
        }

        for item in items {
            let root = try await database.dbWriter.read { db in
                try Message.fetchOne(db, key: Message.makeID(channelID: item.channelID, ts: item.rootMessageTS))
            }
            guard let root else { continue }

            let replies = try await database.dbWriter.read { db in
                try Message
                    .filter(Column("channelID") == item.channelID && Column("threadTS") == item.rootMessageTS)
                    .filter(Column("ts") != item.rootMessageTS)
                    .fetchAll(db)
            }

            guard let reason = resolution(for: item, root: root, replies: replies) else { continue }

            try await database.dbWriter.write { db in
                var updated = item
                updated.state = .resolved
                updated.resolutionReason = reason
                updated.lastEvaluatedAt = now()
                try updated.update(db)
            }
        }
    }

    /// Decide whether an item is resolved, and why (heuristics only). A *bare* reply no
    /// longer closes anything — that's left to the LLM solution-judge (`ItemThreadSummaryService`),
    /// so "looking into it" doesn't prematurely close an open question. Pure for unit testing.
    func resolution(for item: Item, root: Message, replies: [Message]) -> ResolutionReason? {
        var latestOpenTS: Double?
        var latestResolved: (ts: Double, reason: ResolutionReason)?

        for message in ([root] + replies).sorted(by: { $0.ts < $1.ts }) {
            let activityTS = activityTimestamp(for: message)
            let reactions = decodeReactions(message.reactionsJSON) ?? []
            let text = SlackTextSanitizer.stripFencedBlocks(message.text)
            let hasActionableOpenText = isActionableOpenText(text)
            var latestOpenOnMessage: Double?

            if EmojiSignalDetector.hasOpenReaction(reactions) {
                let observedTS = message.openReactionObservedAt?.timeIntervalSince1970
                    ?? activityTS
                latestOpenTS = max(latestOpenTS ?? observedTS, observedTS)
                latestOpenOnMessage = observedTS
            }
            if EmojiSignalDetector.hasOpenTextEmoji(text) || hasActionableOpenText {
                latestOpenTS = max(latestOpenTS ?? activityTS, activityTS)
                latestOpenOnMessage = max(latestOpenOnMessage ?? activityTS, activityTS)
            }

            // Open and resolved reactions can coexist on one Slack message. Record both
            // with their observation times so a newly-added ✅ beats an older 👀, while a
            // later 👀 can reopen an older completion signal.
            if EmojiSignalDetector.hasResolvedReaction(reactions) {
                let observedTS = message.resolvedReactionObservedAt?.timeIntervalSince1970
                    ?? activityTS
                recordResolved(
                    ts: observedTS,
                    reason: .reacted,
                    latest: &latestResolved
                )
            }
            if EmojiSignalDetector.hasResolvedTextEmoji(text) {
                recordResolved(
                    ts: activityTS,
                    reason: .reacted,
                    latest: &latestResolved
                )
            }

            // Actionable language has precedence over completion words in the same text
            // (for example, "not fixed, still failing"). An explicit reaction above is
            // still allowed to carry a later observation time.
            if hasActionableOpenText {
                continue
            }
            // "not fixed yet 👀" is an open signal, not a completion statement. If the
            // message was edited after an older open reaction, however, the newer text is
            // allowed to state completion.
            if let latestOpenOnMessage, latestOpenOnMessage >= activityTS {
                continue
            }

            if containsResolvedWord(text) {
                recordResolved(
                    ts: activityTS,
                    reason: .stated,
                    latest: &latestResolved
                )
            } else if message.ts != root.ts,
                      isCoordinationAsk(root.text),
                      containsCoordinationResolution(text) {
                recordResolved(
                    ts: activityTS,
                    reason: .stated,
                    latest: &latestResolved
                )
            }
        }

        guard let latestResolved else { return nil }
        if let latestOpenTS, latestOpenTS > latestResolved.ts {
            return nil
        }
        return latestResolved.reason
    }

    private func activityTimestamp(for message: Message) -> Double {
        [
            message.timestamp,
            message.firstObservedAt?.timeIntervalSince1970,
            message.contentEditedAt?.timeIntervalSince1970,
        ]
        .compactMap { $0 }
        .max() ?? message.timestamp
    }

    private func recordResolved(
        ts: Double,
        reason: ResolutionReason,
        latest: inout (ts: Double, reason: ResolutionReason)?
    ) {
        if latest == nil || ts >= latest!.ts {
            latest = (ts, reason)
        }
    }

    private func isActionableOpenText(_ text: String) -> Bool {
        // A newer actionable reply ("still failing", "blocked again", "can someone look?")
        // must beat an older close signal, or reopened items immediately disappear.
        ruleEngine.classify(text: text).messageClass != .contextOnly
    }

    private func containsResolvedWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ResolutionDetector.speculativeResolutionPhrases.contains(where: { lower.contains($0) }) {
            return false
        }
        let paddedText = " \(normalizePhrase(lower)) "
        return ResolutionDetector.resolvedWords.contains { phrase in
            paddedText.contains(" \(normalizePhrase(phrase)) ")
        }
    }

    private func isCoordinationAsk(_ text: String) -> Bool {
        let lower = SlackTextSanitizer.stripFencedBlocks(text).lowercased()
        return ResolutionDetector.coordinationAskPhrases.contains { lower.contains($0) }
    }

    private func containsCoordinationResolution(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ResolutionDetector.coordinationResolvedPhrases.contains { lower.contains($0) }
    }

    private func normalizePhrase(_ text: String) -> String {
        let chars = text.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(chars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func decodeReactions(_ json: String?) -> [SlackReaction]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SlackReaction].self, from: data)
    }
}
