import Foundation

/// Classifies a message with the LLM for ambiguity or an approved-guidance precision
/// check, returning an intermediate class + confidence (§7.1). Strict-JSON contract;
/// defensive parsing; a parse failure never crashes detection.
struct LLMClassifier {
    let client: LLMClient
    /// Learned, company-specific guidance appended to the stable base prompt (§7.5,
    /// self-evolution). Empty = base prompt only. The base prompt's JSON contract is
    /// fixed in code; only this approved overlay is learned.
    var guidance: String = ""

    var hasGuidance: Bool {
        !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kept reusable so the evolution loop can compare a proposed guidance change with
    /// the exact classifier contract that is already in force.
    static let baseSystem = """
    You label a single Slack message for a local-first Slack catch-up app. Use the \
    thread context only to decide whether the message still represents an open loop. \
    Choose exactly one class:

    - openQuestion: an unanswered question, request, handoff, or coordination ask \
      directed at a person, on-call, or the group. Examples: review/approve/send/share, \
      ping/page/loop in someone, confirm a status, add a link, get eyes on something, \
      follow up with another owner.
    - decisionPending: the team needs to choose, approve, reject, ship, hold, merge, \
      roll forward, roll back, pick an option, or make a go/no-go call.
    - blocker: someone cannot proceed, is waiting on a dependency/access/review, or \
      reports an active production/build/test/deploy problem such as timeouts, elevated \
      errors, outage, degraded service, failed CI, or a stuck pipeline.
    - contextOnly: FYI/status/chatter, praise, thanks, already completed work, messages \
      that the thread context shows are answered/resolved, or vague discussion with no \
      owner/action needed.
    - Slack system join/leave notifications are membership events, not actionable \
      messages. Always classify them as contextOnly.

    Resolution/context rules:
    - If the thread already contains a concrete answer, completion, approval, handoff, \
      or fix, classify the original message as contextOnly.
    - A reply like "on it", "paging now", "sent", or "looping them in" resolves a \
      coordination ask whose only requested action was to notify/page/handoff.
    - The same "on it" or "looking into it" does not resolve a request to investigate \
      or fix a technical problem unless there is a concrete outcome.

    Confidence guidance:
    - 0.85-1.0: explicit owner/action/decision/blocker with clear wording.
    - 0.60-0.84: likely actionable but missing an owner, deadline, or complete context.
    - below 0.60: weak or ambiguous; prefer contextOnly unless there is a real open loop.

    Respond with ONLY a JSON object, no prose, no code fences:
    {"class":"openQuestion|decisionPending|blocker|contextOnly","confidence":0.0-1.0}
    """

    /// Base prompt plus the learned guidance block, when present.
    static func effectiveSystemPrompt(guidance: String) -> String {
        let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseSystem }
        return baseSystem + "\n\nApproved company-specific guidance (apply within the contract above; when it says to ignore or suppress a matching message, classify it as contextOnly):\n" + trimmed
    }

    /// Base prompt plus the learned guidance block, when present.
    private var system: String {
        Self.effectiveSystemPrompt(guidance: guidance)
    }

    enum ClassificationFailure: Error, Equatable {
        case callFailed(String)
        case parseFailed
    }

    /// Returns the LLM verdict. Throws with a redaction-safe reason when the provider
    /// call fails or the output cannot be parsed.
    func classify(rootText: String, threadContext: String) async throws -> RuleVerdict {
        let user = """
        Thread context:
        \(threadContext)

        Message to classify:
        \(rootText)
        """
        let raw: String
        do {
            raw = try await client.complete(LLMRequest(system: system, user: user))
        } catch {
            throw ClassificationFailure.callFailed(String(describing: error))
        }
        guard let verdict = Self.parse(raw) else {
            throw ClassificationFailure.parseFailed
        }
        return verdict
    }

    /// Parse a strict-JSON verdict, tolerating code fences and surrounding prose.
    static func parse(_ raw: String) -> RuleVerdict? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let messageClass = MessageClass(rawValue: payload.`class`) else {
            return nil
        }
        let clamped = min(max(payload.confidence, 0), 1)
        return RuleVerdict(messageClass: messageClass, confidence: clamped)
    }

    /// Extract the first balanced-looking JSON object substring (`{ ... }`).
    private static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(raw[start...end])
    }

    private struct Payload: Decodable {
        let `class`: String
        let confidence: Double
    }
}
