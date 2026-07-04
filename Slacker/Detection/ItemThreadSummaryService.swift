import Foundation
import GRDB

/// Analyzes the thread of each open item with a single LLM call that returns BOTH a
/// 1-2 sentence summary AND a resolution verdict (§ user requests: thread summaries +
/// aggressive auto-closing of resolved threads). One call per item per new batch of
/// replies — so judging "is this 10-message thread resolved?" costs nothing beyond the
/// summary we already generate. The cheap heuristic `ResolutionDetector` runs first;
/// this is the backstop for threads it can't read (long/implicit resolutions).
struct ItemThreadSummaryService {
    let database: AppDatabase
    let llm: LLMClient?
    var patternStore: PatternStore?
    var now: () -> Date = { Date() }
    private let ruleEngine = RuleEngine()

    /// Items worth analyzing — the ones still demanding attention.
    private static let openStates: [ItemState] = [.surfaced, .review, .open]
    /// Minimum replies before the LLM is allowed to auto-CLOSE. 1, so a single reply that
    /// actually solves an open question closes it — but a bare "looking into it" won't
    /// (the LLM returns resolved=false). The summary call already runs at ≥1 reply.
    private let resolveMinReplies = 1
    /// Confidence the LLM must report to auto-close — kept high to protect precision
    /// (a wrongly-closed item is an attention item the manager never sees).
    private let resolveMinConfidence = 0.80

    private let system = """
    You analyze a Slack thread for a busy manager. Respond with ONLY a JSON object, no \
    prose, no code fences:
    {"summary":"1-2 sentence recap of what's asked/blocked and the current state",
     "resolved":true|false,
     "confidence":0.0-1.0}
    "resolved" is true if the original question, blocker, or decision has clearly been \
    answered, fixed, decided, or otherwise closed in the thread, including concrete \
    outcome language like "green now", "cleared", "merged", "approved", or "all set". \
    If the original ask is only to notify, ping, page, forward, or hand off to someone \
    else, then a reply saying the person is doing that now ("on it", "paging now", \
    "sent", "looping them in") resolves that ask. If the original ask is to investigate \
    or fix a problem, "on it" or "looking into it" alone does not resolve it. \
    "confidence" is your confidence that the resolved value is correct. Be conservative \
    only when the thread is still waiting, investigating, assigned with no outcome, or unclear.
    """

    func analyzeOpenThreads() async throws {
        guard let llm else { return }

        let items = try await database.dbWriter.read { db in
            try Item.filter(ItemThreadSummaryService.openStates.map(\.rawValue).contains(Column("state"))).fetchAll(db)
        }

        for item in items {
            let replies = try await database.dbWriter.read { db in
                try Message
                    .filter(Column("channelID") == item.channelID && Column("threadTS") == item.rootMessageTS)
                    .filter(Column("ts") != item.rootMessageTS)
                    .order(Column("ts"))
                    .fetchAll(db)
            }
            // Only analyze threads that actually have discussion.
            guard !replies.isEmpty else { continue }
            // Skip if we already analyzed at this reply count.
            if item.summarizedReplyCount == replies.count, item.threadSummary != nil { continue }

            let root = try await database.dbWriter.read { db in
                try Message.fetchOne(db, key: Message.makeID(channelID: item.channelID, ts: item.rootMessageTS))
            }
            guard let root else { continue }

            let transcript: String = ([root] + replies)
                .compactMap { message in
                    let text = SlackTextSanitizer.stripFencedBlocks(message.text)
                    guard !text.isEmpty else { return nil }
                    return "[\(message.userID ?? "unknown")] \(text)"
                }
                .joined(separator: "\n")
            guard !transcript.isEmpty else { continue }

            let systemPrompt = try await systemPrompt(forChannelID: item.channelID)
            Log.info("LLM thread analyzer used[item=\(item.id) channel=\(item.channelID) rootTS=\(item.rootMessageTS)]: \(replies.count) repl\(replies.count == 1 ? "y" : "ies").")
            let raw: String
            do {
                raw = try await llm.complete(LLMRequest(system: systemPrompt, user: transcript))
            } catch {
                Log.info("LLM thread analyzer[item=\(item.id)]: call failed (\(error)); leaving item unchanged.")
                continue
            }
            guard let verdict = Self.parse(raw) else {
                Log.info("LLM thread analyzer[item=\(item.id)]: parse failed; leaving item unchanged.")
                continue  // a failure/parse error must not break the cycle
            }
            Log.info("LLM thread analyzer[item=\(item.id)]: resolved=\(verdict.resolved), confidence=\(verdict.confidence).")

            // Auto-close if the LLM is confidently sure, the thread has enough discussion,
            // and the item is still open (don't override user/terminal states).
            let shouldResolve = verdict.resolved
                && verdict.confidence >= resolveMinConfidence
                && replies.count >= resolveMinReplies
                && !latestMessageIsActionableOpen(root: root, replies: replies)

            try await database.dbWriter.write { db in
                guard var fresh = try Item.fetchOne(db, key: item.id) else { return }
                guard ItemThreadSummaryService.openStates.contains(fresh.state) else { return }
                fresh.threadSummary = verdict.summary
                fresh.summarizedReplyCount = replies.count
                fresh.lastEvaluatedAt = now()
                if shouldResolve {
                    fresh.state = .resolved
                    fresh.resolutionReason = .inferred
                }
                try fresh.update(db)
            }

            if shouldResolve {
                Log.info("Auto-closed item \(item.id) as resolved (LLM, \(replies.count) replies, conf \(verdict.confidence)).")
            }
        }
    }

    private func systemPrompt(forChannelID channelID: String) async throws -> String {
        guard let guidance = try await patternStore?.activeGuidance(forChannelID: channelID),
              !guidance.isEmpty else {
            return system
        }
        return """
        \(system)

        Approved workspace-specific guidance:
        \(guidance)
        """
    }

    private func latestMessageIsActionableOpen(root: Message, replies: [Message]) -> Bool {
        guard let latest = ([root] + replies).max(by: {
            (Double($0.ts) ?? 0) < (Double($1.ts) ?? 0)
        }) else { return false }
        return ruleEngine.classify(text: latest.text).messageClass != .contextOnly
    }

    struct ThreadVerdict: Equatable {
        let summary: String
        let resolved: Bool
        let confidence: Double
    }

    /// Parse the strict-JSON verdict, tolerating code fences / surrounding prose.
    static func parse(_ raw: String) -> ThreadVerdict? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let summary = payload.summary else {
            return nil
        }
        return ThreadVerdict(
            summary: summary,
            resolved: payload.resolved ?? false,
            confidence: min(max(payload.confidence ?? 0, 0), 1)
        )
    }

    private struct Payload: Decodable {
        let summary: String?
        let resolved: Bool?
        let confidence: Double?
    }
}
