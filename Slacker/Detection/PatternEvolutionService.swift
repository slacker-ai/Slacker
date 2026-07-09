import Foundation
import GRDB

/// The self-evolving loop (§7.5). Learns this workspace's own language from triage and
/// PROPOSES updates to both detection surfaces: rule-engine phrases ("regex") and the LLM
/// "skill" guidance. Proposals land as `proposed` and never affect detection until a human
/// approves them in Settings — so precision can never silently regress.
///
/// Learning is **per-triage**: every triage verdict (resolve / dismiss / review) immediately
/// fires one proposal anchored on the just-triaged thread, so the system learns within a
/// single click instead of waiting for a batched gate. A single example can't over-fit
/// because the prompt anchors it against recent contrasting labels, and the human-approval
/// gate (plus the offline precision delta shown in Settings) is the precision backstop.
///
/// LLM-optional and failure-isolated: with no LLM configured, or on any LLM/parse failure,
/// the call no-ops and writes nothing.
struct PatternEvolutionService {
    let database: AppDatabase
    let llm: LLMClient?
    let store: PatternStore
    var now: () -> Date = { Date() }
    var makeID: () -> String = { UUID().uuidString }

    /// Cap proposals per triage to bound blast radius (one click shouldn't flood review).
    private let maxProposedPhrasesPerTriage = 1
    /// Recent labels pulled for contrastive context (keeps the prompt small / cheap).
    private let recentLabelLimit = 60
    /// Contrastive examples shown per side (matters / ignore) in the prompt.
    private let contextExamplesPerSide = 12

    private let system = """
    You tune a Slack triage classifier to ONE company's language. A manager just triaged \
    a message. Verdict meanings:
    - matters: this needed attention; the classifier SHOULD catch messages like it.
    - ignore: this did NOT need attention; the classifier should NOT surface messages like it.

    Given the TRIAGED thread (root message plus replies, when present, including compact \
    metadata such as emoji reactions) and recent contrasting examples, propose the \
    SMALLEST change that would make the classifier handle messages like the triaged one \
    correctly:
    - For a "matters" verdict: propose a short trigger PHRASE in one bucket \
    (ask|blocker|problem|help|decision|deadline). Phrases must be lowercase, multi-word \
    (2+ words), and specific (avoid generic words that would over-match), and must NOT match \
    any message listed under IGNORE.
    - If the source is mark_resolved, the manager is teaching what counts as DONE, not \
    what should be newly surfaced. Use replies, emoji reactions, and thread context; \
    prefer GUIDANCE about resolution patterns such as "paging now" or a team-specific \
    done reaction resolving a request to ping/page someone. \
    Do NOT propose detection trigger phrases from the original ask in this case.
    - For an "ignore" verdict: use the full root/reply thread context and prefer a short \
    GUIDANCE note (1-2 sentences) describing what NOT to surface here. Only propose a \
    phrase if you are certain it raises precision.
    Never single out individuals' performance. If no safe, high-precision change exists, \
    return empty arrays.

    Respond with ONLY a JSON object, no prose, no code fences:
    {"phrases":[{"bucket":"ask|blocker|problem|help|decision|deadline","phrase":"...","rationale":"..."}],"guidance":"..."}
    """

    /// Per-triage learning entry point (§7.5). Proposes a phrase and/or guidance tweak from
    /// the one just-triaged message. Safe to fire-and-forget: never throws, never blocks the
    /// triage UI's own writes.
    func evolveFromTriage(
        channelID: String,
        messageTS: String,
        verdict: UserVerdict,
        source: LabelSource? = nil
    ) async {
        guard let llm else {
            Log.info("Per-click evolution skipped: no LLM configured (set a provider + key in Settings).")
            return
        }
        do {
            try await proposeFromTriage(channelID: channelID, messageTS: messageTS, verdict: verdict, source: source, llm: llm)
        } catch {
            Log.error("Per-click evolution[\(channelID)] failed: \(error)")
        }
    }

    private func proposeFromTriage(
        channelID: String,
        messageTS: String,
        verdict: UserVerdict,
        source: LabelSource?,
        llm: LLMClient
    ) async throws {
        // The just-triaged thread. Pruned/empty root → nothing to learn from.
        guard let triagedThread = try await threadText(channelID: channelID, rootTS: messageTS) else { return }

        let context = try await recentContext(channelID: channelID, excludingTS: messageTS)
        let userPrompt = buildPrompt(triaged: triagedThread, verdict: verdict, source: source,
                                     matters: context.matters, ignore: context.ignore)

        // LLM/parse failure → write nothing, no state to retry (the next triage tries again).
        Log.info("LLM pattern evolution used[\(channelID) ts=\(messageTS) verdict=\(verdict.rawValue)]: proposing regex/guidance updates.")
        let raw: String
        do {
            raw = try await llm.complete(LLMRequest(system: system, user: userPrompt, maxTokens: 400))
        } catch {
            Log.info("LLM pattern evolution[\(channelID) ts=\(messageTS)]: call failed (\(error)); no proposal written.")
            return
        }
        guard let proposal = Self.parse(raw) else {
            Log.info("LLM pattern evolution[\(channelID) ts=\(messageTS)]: parse failed; no proposal written.")
            return
        }

        let patterns = verdict == .ignore || source == .markResolved
            ? []
            : validatedPatterns(from: proposal.phrases, channelID: channelID)
        let guidance = try await validatedGuidance(proposal.guidance, channelID: channelID)

        if !patterns.isEmpty || guidance != nil {
            try await store.insertProposals(patterns, guidance: guidance)
            Log.info("Per-click evolution[\(channelID)]: \(patterns.count) phrase proposal(s)\(guidance == nil ? "" : " + guidance").")
        }
    }

    // MARK: - Helpers

    private struct Example { let text: String; let verdict: UserVerdict }
    private struct Context { let matters: [String]; let ignore: [String] }

    private func threadText(channelID: String, rootTS: String) async throws -> String? {
        try await database.dbWriter.read { db in
            let key = Message.makeID(channelID: channelID, ts: rootTS)
            guard let root = try Message.fetchOne(db, key: key) else { return nil }
            let replies = try Message
                .filter(Column("channelID") == channelID && Column("threadTS") == rootTS)
                .filter(Column("ts") != rootTS)
                .order(Column("ts"))
                .fetchAll(db)
            let messages = ([root] + replies).compactMap(renderMessage)
            guard !messages.isEmpty else { return nil }
            return messages.joined(separator: "\n")
        }
    }

    /// Recent labeled messages in this channel (excluding the triaged one), split by verdict
    /// and capped per side, to anchor the proposal against real contrasting examples.
    private func recentContext(channelID: String, excludingTS: String) async throws -> Context {
        let labels = try await database.dbWriter.read { db in
            try TriageLabel
                .filter(Column("channelID") == channelID)
                .order(Column("createdAt").desc)
                .limit(recentLabelLimit)
                .fetchAll(db)
        }
        let examples = try await examplesWithText(
            labels.filter { $0.messageTS != excludingTS }, channelID: channelID
        )
        let matters = examples.filter { $0.verdict == .matters }.map(\.text).prefix(contextExamplesPerSide)
        let ignore = examples.filter { $0.verdict == .ignore }.map(\.text).prefix(contextExamplesPerSide)
        return Context(matters: Array(matters), ignore: Array(ignore))
    }

    private func examplesWithText(_ labels: [TriageLabel], channelID: String) async throws -> [Example] {
        try await database.dbWriter.read { db in
            labels.compactMap { label in
                let key = Message.makeID(channelID: channelID, ts: label.messageTS)
                guard let message = try? Message.fetchOne(db, key: key) else { return nil }
                guard let rendered = renderMessage(message) else { return nil }
                return Example(text: rendered, verdict: label.userVerdict)
            }
        }
    }

    private func renderMessage(_ message: Message) -> String? {
        let text = SlackTextSanitizer.stripFencedBlocks(message.text)
        let metadata = messageMetadata(message)
        guard !text.isEmpty || !metadata.isEmpty else { return nil }

        var line = "[\(message.userID ?? "unknown")]"
        if !text.isEmpty {
            line += " \(text)"
        }
        if !metadata.isEmpty {
            line += " {\(metadata.joined(separator: "; "))}"
        }
        return line
    }

    private func messageMetadata(_ message: Message) -> [String] {
        guard let json = message.reactionsJSON,
              let data = json.data(using: .utf8),
              let reactions = try? JSONDecoder().decode([SlackReaction].self, from: data),
              !reactions.isEmpty else {
            return []
        }

        let reactionsText = reactions.map { reaction in
            var parts = [":\(reaction.name):", "x\(reaction.count)"]
            if EmojiSignalDetector.hasResolvedReaction([reaction]) {
                parts.append("resolved_signal")
            }
            if EmojiSignalDetector.hasOpenReaction([reaction]) {
                parts.append("open_signal")
            }
            return parts.joined(separator: " ")
        }.joined(separator: ", ")

        return ["reactions: \(reactionsText)"]
    }

    private func buildPrompt(triaged: String, verdict: UserVerdict, source: LabelSource?, matters: [String], ignore: [String]) -> String {
        func block(_ title: String, _ items: [String]) -> String {
            guard !items.isEmpty else { return "\(title): (none)" }
            return "\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        return """
        TRIAGED THREAD (verdict: \(verdict.rawValue), source: \(source?.rawValue ?? "unknown")):
        \(triaged)

        \(block("MATTERS (recently labeled needs-attention)", matters))

        \(block("IGNORE (recently labeled not-actionable)", ignore))
        """
    }

    /// Validate, de-dupe and cap LLM-proposed phrases. Admissibility (multi-word, long
    /// enough, not already a base phrase) is enforced by `RuleEngine`. Supporting count is
    /// 1 — these are single-example proposals; the Settings precision delta is the gate.
    private func validatedPatterns(from proposed: [Proposal.Phrase], channelID: String) -> [LearnedPattern] {
        var seen = Set<String>()
        var result: [LearnedPattern] = []
        for item in proposed {
            guard let bucket = RuleBucket(rawValue: item.bucket) else { continue }
            let phrase = item.phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard RuleEngine.isAdmissibleLearnedPhrase(phrase) else { continue }
            let dedupeKey = "\(bucket.rawValue):\(phrase)"
            guard seen.insert(dedupeKey).inserted else { continue }
            result.append(LearnedPattern(
                id: makeID(),
                channelID: channelID,
                bucket: bucket,
                phrase: phrase,
                status: .proposed,
                source: .llm,
                rationale: item.rationale,
                supportingLabelCount: 1,
                createdAt: now()
            ))
            if result.count >= maxProposedPhrasesPerTriage { break }
        }
        return result
    }

    /// Build a proposed guidance row, unless the text is empty or unchanged from the
    /// most recent guidance for this channel.
    private func validatedGuidance(_ text: String, channelID: String) async throws -> LearnedGuidance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if try await store.hasSimilarGuidance(trimmed, channelID: channelID) {
            return nil
        }
        let version = try await store.nextGuidanceVersion(forChannelID: channelID)
        return LearnedGuidance(
            id: makeID(), channelID: channelID, text: trimmed,
            status: .proposed, version: version, createdAt: now()
        )
    }

    // MARK: - Defensive JSON parsing (mirrors LLMClassifier.parse)

    struct Proposal: Equatable {
        struct Phrase: Equatable { let bucket: String; let phrase: String; let rationale: String? }
        let phrases: [Phrase]
        let guidance: String
    }

    static func parse(_ raw: String) -> Proposal? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let phrases = (payload.phrases ?? []).map {
            Proposal.Phrase(bucket: $0.bucket, phrase: $0.phrase, rationale: $0.rationale)
        }
        return Proposal(phrases: phrases, guidance: payload.guidance ?? "")
    }

    private static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(raw[start...end])
    }

    private struct Payload: Decodable {
        struct Phrase: Decodable { let bucket: String; let phrase: String; let rationale: String? }
        let phrases: [Phrase]?
        let guidance: String?
    }
}
