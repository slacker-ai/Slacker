import Foundation
import GRDB

/// Read/write façade over the learned-pattern tables (§7.5, self-evolution), so detection
/// and the Settings UI never embed SQL. Automatic evolution and manual edits both write
/// approved, versioned rows; proposal states remain only for database compatibility.
struct PatternStore {
    let database: AppDatabase
    var now: () -> Date = { Date() }

    struct EvolutionCoverageContext {
        let globalGuidance: String
        let channelGuidance: String
        let existingPatterns: [LearnedPattern]

        var activeGuidance: String {
            [globalGuidance, channelGuidance]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        /// New builds do not create pending guidance; retained for source compatibility.
        var pendingGuidance: [LearnedGuidance] { [] }
    }

    struct GuidanceState: Equatable {
        let globalText: String
        let globalVersion: Int
        let channelText: String
        let channelVersion: Int

        var effectiveText: String {
            [globalText, channelText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        var learnedCharacterCount: Int {
            globalText.count + channelText.count
        }
    }

    // MARK: - Detection reads (approved only)

    /// Approved learned phrases for a channel: its own rows ∪ global rows, as an
    /// injectable `LearnedPhraseBank`.
    func activePhraseBank(forChannelID channelID: String) async throws -> LearnedPhraseBank {
        let patterns = try await database.dbWriter.read { db in
            try LearnedPattern
                .filter(Column("status") == PatternStatus.approved.rawValue)
                .filter(Column("channelID") == channelID || Column("channelID") == nil)
                .fetchAll(db)
        }
        return LearnedPhraseBank(patterns: patterns)
    }

    /// The global AI guidance document. Stored as the newest approved global
    /// `LearnedGuidance` row so edits are versioned without destructive updates.
    func activeGuidanceDocument() async throws -> String {
        try await database.dbWriter.read { db in
            try Self.newestApproved(db, channelID: nil)?.text ?? ""
        }
    }

    /// The editable guidance document for one exact scope. Unlike `activeGuidance`, this
    /// does not prepend global guidance to channel guidance.
    func activeGuidanceDocument(forChannelID channelID: String?) async throws -> String {
        try await database.dbWriter.read { db in
            try Self.newestApproved(db, channelID: channelID)?.text ?? ""
        }
    }

    /// Approved guidance for a channel: global guidance followed by that channel's
    /// guidance. Other channels' guidance is intentionally excluded.
    func activeGuidance(forChannelID channelID: String) async throws -> String {
        try await database.dbWriter.read { db in
            try Self.currentActiveGuidanceTexts(db, channelID: channelID)
                .joined(separator: "\n")
        }
    }

    private static func newestApproved(_ db: Database, channelID: String?) throws -> LearnedGuidance? {
        let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
        return try LearnedGuidance
            .filter(Column("status") == PatternStatus.approved.rawValue)
            .filter(scope)
            .order(Column("version").desc)
            .fetchOne(db)
    }

    private static func currentActiveGuidanceTexts(
        _ db: Database,
        channelID: String?
    ) throws -> [String] {
        var texts = [try newestApproved(db, channelID: nil)?.text]
        if let channelID {
            texts.append(try newestApproved(db, channelID: channelID)?.text)
        }
        return texts
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Compatibility coverage for proposal rows created by older app versions.
    private static func proposalCoverageTexts(
        _ db: Database,
        channelID: String?
    ) throws -> [String] {
        let pending = try LearnedGuidance
            .filter(Column("status") == PatternStatus.proposed.rawValue)
            .fetchAll(db)
            .map(\.text)
        return try currentActiveGuidanceTexts(db, channelID: channelID) + pending
    }

    /// Everything the evolution model must check before writing another automatic update.
    func evolutionCoverageContext(forChannelID channelID: String) async throws -> EvolutionCoverageContext {
        try await database.dbWriter.read { db in
            let globalGuidance = try Self.newestApproved(db, channelID: nil)?.text ?? ""
            let channelGuidance = try Self.newestApproved(db, channelID: channelID)?.text ?? ""

            let existingPatterns = try LearnedPattern
                .filter(Column("status") == PatternStatus.approved.rawValue)
                .filter(Column("channelID") == channelID || Column("channelID") == nil)
                .order(Column("createdAt").desc)
                .limit(30)
                .fetchAll(db)

            return EvolutionCoverageContext(
                globalGuidance: globalGuidance,
                channelGuidance: channelGuidance,
                existingPatterns: existingPatterns
            )
        }
    }

    func guidanceState(forChannelID channelID: String) async throws -> GuidanceState {
        try await database.dbWriter.read { db in
            let global = try Self.newestApproved(db, channelID: nil)
            let channel = try Self.newestApproved(db, channelID: channelID)
            return GuidanceState(
                globalText: global?.text ?? "",
                globalVersion: global?.version ?? 0,
                channelText: channel?.text ?? "",
                channelVersion: channel?.version ?? 0
            )
        }
    }

    // MARK: - Automatic evolution writes

    /// Activates validated phrases and guidance in one transaction. Duplicate phrases and
    /// semantically-covered guidance are ignored, so overlapping evolution calls are safe.
    func activateEvolution(
        patterns: [LearnedPattern],
        globalGuidance: String,
        channelGuidance: String,
        channelID: String
    ) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            var resetGlobal = false
            var resetChannel = false

            for var pattern in patterns {
                pattern.status = .approved
                pattern.decidedAt = timestamp
                do {
                    try pattern.insert(db)
                    resetChannel = true
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    continue
                }
            }

            if try Self.appendApprovedGuidance(globalGuidance, channelID: nil, at: timestamp, db: db) {
                resetGlobal = true
            }
            let activeGlobal = try Self.newestApproved(db, channelID: nil)?.text ?? ""
            if try Self.appendApprovedGuidance(
                channelGuidance,
                channelID: channelID,
                additionalCoverage: [activeGlobal],
                at: timestamp,
                db: db
            ) {
                resetChannel = true
            }

            if resetGlobal {
                try Self.resetDetectionCursor(db, channelID: nil)
            } else if resetChannel {
                try Self.resetDetectionCursor(db, channelID: channelID)
            }
        }
    }

    /// Replaces both learned documents only if neither changed while condensation was in
    /// flight. Returning false tells the caller to keep the newer manual/automatic edits.
    func replaceGuidanceDocuments(
        globalText: String,
        channelText: String,
        channelID: String,
        expected: GuidanceState
    ) async throws -> Bool {
        let timestamp = now()
        return try await database.dbWriter.write { db in
            let currentGlobal = try Self.newestApproved(db, channelID: nil)
            let currentChannel = try Self.newestApproved(db, channelID: channelID)
            guard (currentGlobal?.version ?? 0) == expected.globalVersion,
                  (currentChannel?.version ?? 0) == expected.channelVersion else {
                return false
            }

            let nextGlobal = globalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextChannel = channelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if nextGlobal != (currentGlobal?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                try Self.insertApprovedGuidance(nextGlobal, channelID: nil, at: timestamp, db: db)
            }
            if nextChannel != (currentChannel?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                try Self.insertApprovedGuidance(nextChannel, channelID: channelID, at: timestamp, db: db)
            }
            try Self.resetDetectionCursor(db, channelID: nil)
            return true
        }
    }

    private static func appendApprovedGuidance(
        _ addition: String,
        channelID: String?,
        additionalCoverage: [String] = [],
        at timestamp: Date,
        db: Database
    ) throws -> Bool {
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return false }
        let current = try newestApproved(db, channelID: channelID)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !containsSimilarGuidance(addition, in: [current] + additionalCoverage) else { return false }
        let next = current.isEmpty ? "- \(addition)" : "\(current)\n\n- \(addition)"
        try insertApprovedGuidance(next, channelID: channelID, at: timestamp, db: db)
        return true
    }

    private static func insertApprovedGuidance(
        _ text: String,
        channelID: String?,
        at timestamp: Date,
        db: Database
    ) throws {
        try LearnedGuidance(
            id: UUID().uuidString,
            channelID: channelID,
            text: text,
            status: .approved,
            version: try nextGuidanceVersion(db, channelID: channelID),
            createdAt: timestamp,
            decidedAt: timestamp
        ).insert(db)
    }

    // MARK: - Evolution writes (proposals)

    /// Persist mined proposals. Phrase inserts are idempotent — a duplicate (scope+bucket+
    /// phrase) is silently skipped via the unique index. Guidance is checked again inside
    /// the write transaction so concurrent, semantically-equivalent proposals do not race
    /// past the evolution service's preflight check.
    func insertProposals(_ patterns: [LearnedPattern], guidance: LearnedGuidance?) async throws {
        try await database.dbWriter.write { db in
            for pattern in patterns {
                do {
                    try pattern.insert(db)
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    continue   // already proposed/decided for this scope+bucket+phrase
                }
            }
            if let guidance {
                let existingTexts = try Self.proposalCoverageTexts(
                    db,
                    channelID: guidance.channelID
                )
                if !Self.containsSimilarGuidance(guidance.text, in: existingTexts) {
                    try guidance.insert(db)
                }
            }
        }
    }

    /// Next guidance version for a scope (channel or global). 1 when none exist.
    func nextGuidanceVersion(forChannelID channelID: String?) async throws -> Int {
        try await database.dbWriter.read { db in
            try Self.nextGuidanceVersion(db, channelID: channelID)
        }
    }

    private static func nextGuidanceVersion(_ db: Database, channelID: String?) throws -> Int {
        let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
        let max = try LearnedGuidance.filter(scope).select(max(Column("version")), as: Int.self).fetchOne(db)
        return (max ?? 0) + 1
    }

    /// Newest guidance text for a scope regardless of status — used to skip re-proposing
    /// an identical block on the next run.
    func latestGuidanceText(forChannelID channelID: String?) async throws -> String? {
        try await database.dbWriter.read { db in
            let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
            return try LearnedGuidance
                .filter(scope)
                .order(Column("version").desc)
                .fetchOne(db)?
                .text
        }
    }

    /// True when a proposed guidance block is already in the current effective prompt or
    /// duplicates a pending card. Historical/rejected/retired guidance is not coverage.
    func hasSimilarGuidance(_ text: String, channelID: String?) async throws -> Bool {
        return try await database.dbWriter.read { db in
            let existingTexts = try Self.proposalCoverageTexts(db, channelID: channelID)
            return Self.guidanceIsCovered(text, by: existingTexts)
        }
    }

    /// Deterministic backstop for the model's coverage check. This catches direct and
    /// near-direct restatements even if the model ignores the no-duplicate instruction.
    static func guidanceIsCovered(_ text: String, by referenceTexts: [String]) -> Bool {
        containsSimilarGuidance(text, in: referenceTexts)
    }

    /// Retire redundant pending guidance left by older builds. The newest uncovered
    /// proposal wins; only current active guidance and another pending proposal count as
    /// coverage. Historical or rejected rules must not silently suppress new learning.
    func retireRedundantGuidanceProposals() async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            let proposals = try LearnedGuidance
                .filter(Column("status") == PatternStatus.proposed.rawValue)
                .order(Column("createdAt").desc, Column("version").desc)
                .fetchAll(db)
            var keptProposalTexts: [String] = []

            for proposal in proposals {
                let activeTexts = try Self.currentActiveGuidanceTexts(
                    db,
                    channelID: proposal.channelID
                )
                let referenceTexts = activeTexts + keptProposalTexts
                if Self.containsSimilarGuidance(proposal.text, in: referenceTexts) {
                    _ = try LearnedGuidance
                        .filter(key: proposal.id)
                        .updateAll(db,
                                   Column("status").set(to: PatternStatus.retired.rawValue),
                                   Column("decidedAt").set(to: timestamp))
                } else {
                    keptProposalTexts.append(proposal.text)
                }
            }
        }
    }

    // MARK: - Triage / approval UI

    func approvePattern(_ id: String) async throws { try await setPatternStatus(id, .approved) }
    func rejectPattern(_ id: String) async throws { try await setPatternStatus(id, .rejected) }
    func retirePattern(_ id: String) async throws { try await setPatternStatus(id, .retired) }

    /// Save a hand-entered phrase directly as approved. If the same scoped phrase already
    /// exists in any lifecycle state, promote that row instead of inserting a duplicate.
    func saveManualPattern(channelID: String?, bucket: RuleBucket, phrase: String) async throws {
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard RuleEngine.isAdmissibleLearnedPhrase(normalized) else { return }

        let timestamp = now()
        try await database.dbWriter.write { db in
            let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
            if let existing = try LearnedPattern
                .filter(scope)
                .filter(Column("bucket") == bucket.rawValue)
                .filter(Column("phrase") == normalized)
                .fetchOne(db) {
                _ = try LearnedPattern
                    .filter(key: existing.id)
                    .updateAll(db,
                               Column("status").set(to: PatternStatus.approved.rawValue),
                               Column("source").set(to: PatternSource.manual.rawValue),
                               Column("rationale").set(to: nil),
                               Column("decidedAt").set(to: timestamp))
            } else {
                try LearnedPattern(
                    id: UUID().uuidString,
                    channelID: channelID,
                    bucket: bucket,
                    phrase: normalized,
                    status: .approved,
                    source: .manual,
                    rationale: nil,
                    supportingLabelCount: 0,
                    createdAt: timestamp,
                    decidedAt: timestamp
                ).insert(db)
            }
            try Self.resetDetectionCursor(db, channelID: channelID)
        }
    }

    /// Approve a proposal for the selected channel, or globally when `channelID` is nil.
    /// The proposal remembers where it originated; the new approved version owns the
    /// user-selected scope.
    func approveGuidance(_ id: String, channelID: String?) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            guard let guidance = try LearnedGuidance.fetchOne(db, key: id),
                  guidance.status == .proposed else { return }
            let current = try Self.newestApproved(db, channelID: channelID)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let proposal = guidance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextText: String
            if current.isEmpty {
                nextText = proposal
            } else if proposal.isEmpty || Self.containsSimilarGuidance(proposal, in: [current]) {
                nextText = current
            } else {
                nextText = "\(current)\n\n- \(proposal)"
            }
            if nextText != current {
                try LearnedGuidance(
                    id: UUID().uuidString,
                    channelID: channelID,
                    text: nextText,
                    status: .approved,
                    version: try Self.nextGuidanceVersion(db, channelID: channelID),
                    createdAt: timestamp,
                    decidedAt: timestamp
                ).insert(db)
            }
            _ = try LearnedGuidance
                .filter(key: id)
                .updateAll(db, Column("status").set(to: PatternStatus.retired.rawValue),
                           Column("decidedAt").set(to: timestamp))
            try Self.resetDetectionCursor(db, channelID: channelID)
        }
    }
    func rejectGuidance(_ id: String) async throws { try await setGuidanceStatus(id, .rejected) }
    func retireGuidance(_ id: String) async throws { try await setGuidanceStatus(id, .retired) }

    /// Reject every still-pending evolution proposal. Approved/manual rows remain active.
    func rejectAllProposals() async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            _ = try LearnedPattern
                .filter(Column("status") == PatternStatus.proposed.rawValue)
                .updateAll(db, Column("status").set(to: PatternStatus.rejected.rawValue),
                           Column("decidedAt").set(to: timestamp))
            _ = try LearnedGuidance
                .filter(Column("status") == PatternStatus.proposed.rawValue)
                .updateAll(db, Column("status").set(to: PatternStatus.rejected.rawValue),
                           Column("decidedAt").set(to: timestamp))
        }
    }

    func saveActiveGuidanceDocument(_ text: String) async throws {
        try await saveGuidanceDocument(text, channelID: nil)
    }

    func saveGuidanceDocument(_ text: String, channelID: String?) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            let nextText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = try Self.newestApproved(db, channelID: channelID)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard nextText != current else { return }
            try Self.insertApprovedGuidance(nextText, channelID: channelID, at: timestamp, db: db)
            try Self.resetDetectionCursor(db, channelID: channelID)
        }
    }

    /// Retire every learned pattern + guidance — restores pure base-rule behavior.
    func retireAll() async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            try LearnedPattern
                .filter(Column("status") == PatternStatus.approved.rawValue)
                .updateAll(db, Column("status").set(to: PatternStatus.retired.rawValue),
                           Column("decidedAt").set(to: timestamp))
            _ = try LearnedGuidance
                .filter(Column("status") == PatternStatus.approved.rawValue)
                .updateAll(db, Column("status").set(to: PatternStatus.retired.rawValue),
                           Column("decidedAt").set(to: timestamp))
            try Self.resetDetectionCursor(db, channelID: nil)
        }
    }

    private func setPatternStatus(_ id: String, _ status: PatternStatus) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            let pattern = try LearnedPattern.fetchOne(db, key: id)
            _ = try LearnedPattern
                .filter(key: id)
                .updateAll(db, Column("status").set(to: status.rawValue),
                           Column("decidedAt").set(to: timestamp))
            if status == .approved || status == .retired {
                try Self.resetDetectionCursor(db, channelID: pattern?.channelID)
            }
        }
    }

    private func setGuidanceStatus(_ id: String, _ status: PatternStatus) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            let guidance = try LearnedGuidance.fetchOne(db, key: id)
            _ = try LearnedGuidance
                .filter(key: id)
                .updateAll(db, Column("status").set(to: status.rawValue),
                           Column("decidedAt").set(to: timestamp))
            if status == .approved || status == .retired {
                try Self.resetDetectionCursor(db, channelID: guidance?.channelID)
            }
        }
    }

    private static func resetDetectionCursor(_ db: Database, channelID: String?) throws {
        if let channelID {
            try Channel
                .filter(key: channelID)
                .updateAll(db, Column("lastDetectedTS").set(to: nil))
        } else {
            try Channel.updateAll(db, Column("lastDetectedTS").set(to: nil))
        }
    }

    private static func normalizedGuidance(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let scalars = text.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : " "
        }
        return scalars.joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsSimilarGuidance(_ text: String, in existingTexts: [String]) -> Bool {
        let normalized = normalizedGuidance(text)
        guard !normalized.isEmpty else { return true }

        return existingTexts
            .flatMap(guidanceSegments)
            .contains {
                guidanceSimilarity(normalized, normalizedGuidance($0)) >= 0.60
            }
    }

    /// Active guidance is a Markdown-like document. Compare proposals with each rule line,
    /// not only with the whole cumulative document, whose unrelated rules dilute overlap.
    private static func guidanceSegments(_ text: String) -> [String] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? [text] : lines
    }

    private static func guidanceSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs ? 1 : 0 }
        if lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs) { return 1 }

        let lhsTokens = guidanceTokens(lhs)
        let rhsTokens = guidanceTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }

        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        let jaccard = Double(intersection) / Double(union)
        guard intersection >= 2 else { return jaccard }
        let overlap = Double(intersection) / Double(min(lhsTokens.count, rhsTokens.count))
        return max(jaccard, overlap)
    }

    private static func guidanceTokens(_ text: String) -> Set<String> {
        // Ignore classifier boilerplate and exception qualifiers. What remains is the
        // subject of the rule (for example, "meeting" + "record"), which is stable across
        // normal LLM rewordings without conflating unrelated guidance.
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "of", "and", "or", "for", "from", "in", "on", "at", "by",
            "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "not", "no",
            "surface", "surfaces", "surfaced", "surfacing", "treat", "treats", "treated", "treating",
            "classify", "classified", "message", "messages", "item", "items", "thread", "threads",
            "when", "where", "whether", "if", "unless", "with", "without", "include", "includes",
            "including", "such", "as", "like", "about", "simple", "casual", "lightweight", "generic",
            "broad", "low", "information", "informational", "question", "questions", "ask", "asks",
            "asking", "request", "requests", "requesting", "follow", "followup", "followups", "this",
            "that", "these", "those", "it", "they", "them", "anyone", "someone", "explicit", "direct",
            "specific", "concrete", "urgency", "urgent", "owner", "owners", "deadline", "deadlines",
            "blocker", "blockers", "action", "actions", "context", "attention", "worthy", "similar",
            "person", "people", "take", "taking", "today", "todays", "yesterday", "yesterdays", "s",
            "only", "here", "there", "still", "already", "named", "escalation", "says", "original"
        ]
        return Set(text.split(separator: " ").compactMap { raw in
            var token = String(raw)
            if token.count > 4, token.hasSuffix("ed") {
                token.removeLast(2)
            }
            if token.count > 4, token.hasSuffix("s") {
                token.removeLast()
            }
            return stopWords.contains(String(raw)) || stopWords.contains(token) ? nil : token
        })
    }
}
