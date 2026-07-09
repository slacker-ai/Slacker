import Foundation
import GRDB

/// Read/write façade over the learned-pattern tables (§7.5, self-evolution), so detection
/// and the Settings UI never embed SQL. Detection reads only the `approved` set;
/// proposals are inert until a human approves them.
struct PatternStore {
    let database: AppDatabase
    var now: () -> Date = { Date() }

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

    /// The single active AI guidance document. Stored as the newest approved global
    /// `LearnedGuidance` row so edits are versioned without a destructive migration.
    func activeGuidanceDocument() async throws -> String {
        try await database.dbWriter.read { db in
            try Self.newestApproved(db, channelID: nil)?.text ?? ""
        }
    }

    /// Approved guidance for a channel. The active global document is the main source;
    /// legacy approved channel-scoped guidance is appended for compatibility with older DBs.
    func activeGuidance(forChannelID channelID: String) async throws -> String {
        let (document, channelScoped) = try await database.dbWriter.read { db -> (String, LearnedGuidance?) in
            let document = try Self.newestApproved(db, channelID: nil)?.text ?? ""
            let c = try Self.newestApproved(db, channelID: channelID)
            return (document, c)
        }
        return [document, channelScoped?.text]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private static func newestApproved(_ db: Database, channelID: String?) throws -> LearnedGuidance? {
        let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
        return try LearnedGuidance
            .filter(Column("status") == PatternStatus.approved.rawValue)
            .filter(scope)
            .order(Column("version").desc)
            .fetchOne(db)
    }

    // MARK: - Evolution writes (proposals)

    /// Persist mined proposals. Phrase inserts are idempotent — a duplicate (scope+bucket+
    /// phrase) is silently skipped via the unique index. Guidance is saved as a new
    /// proposed row with an incremented version for its scope.
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
                try guidance.insert(db)
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

    /// True when a proposed guidance block is a duplicate or near-duplicate of existing
    /// guidance in the same scope. Used to keep the approval queue from filling with
    /// tiny rewordings.
    func hasSimilarGuidance(_ text: String, channelID: String?) async throws -> Bool {
        let normalized = Self.normalizedGuidance(text)
        guard !normalized.isEmpty else { return true }

        return try await database.dbWriter.read { db in
            let scope = channelID.map { Column("channelID") == $0 } ?? (Column("channelID") == nil)
            let existing = try LearnedGuidance
                .filter(scope)
                .fetchAll(db)
                .map(\.text)
            return existing.contains { Self.guidanceSimilarity(normalized, Self.normalizedGuidance($0)) >= 0.86 }
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

    func approveGuidance(_ id: String) async throws {
        let timestamp = now()
        try await database.dbWriter.write { db in
            guard let guidance = try LearnedGuidance.fetchOne(db, key: id),
                  guidance.status == .proposed else { return }
            let current = try Self.newestApproved(db, channelID: nil)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let proposal = guidance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextText: String
            if current.isEmpty {
                nextText = proposal
            } else if proposal.isEmpty || current.contains(proposal) {
                nextText = current
            } else {
                nextText = "\(current)\n\n- \(proposal)"
            }
            try LearnedGuidance(
                id: UUID().uuidString,
                channelID: nil,
                text: nextText,
                status: .approved,
                version: try Self.nextGuidanceVersion(db, channelID: nil),
                createdAt: timestamp,
                decidedAt: timestamp
            ).insert(db)
            _ = try LearnedGuidance
                .filter(key: id)
                .updateAll(db, Column("status").set(to: PatternStatus.retired.rawValue),
                           Column("decidedAt").set(to: timestamp))
            try Self.resetDetectionCursor(db, channelID: nil)
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
        let timestamp = now()
        try await database.dbWriter.write { db in
            let nextText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = try Self.newestApproved(db, channelID: nil)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard nextText != current else { return }
            try LearnedGuidance(
                id: UUID().uuidString,
                channelID: nil,
                text: nextText,
                status: .approved,
                version: try Self.nextGuidanceVersion(db, channelID: nil),
                createdAt: timestamp,
                decidedAt: timestamp
            ).insert(db)
            try Self.resetDetectionCursor(db, channelID: nil)
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

    private static func guidanceSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs ? 1 : 0 }
        if lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs) { return 1 }

        let lhsTokens = guidanceTokens(lhs)
        let rhsTokens = guidanceTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }

        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return Double(intersection) / Double(union)
    }

    private static func guidanceTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = ["a", "an", "the", "to", "of", "and", "or"]
        return Set(text.split(separator: " ").compactMap { raw in
            var token = String(raw)
            if token.count > 4, token.hasSuffix("s") {
                token.removeLast()
            }
            return stopWords.contains(token) ? nil : token
        })
    }
}
