import Foundation
import Observation
import GRDB

/// Backs the Learned Patterns review screen (§7.5, self-evolution). Lists mined proposals
/// (rule phrases + LLM guidance) for human approval, with an offline precision delta so a
/// regressing phrase is visible before it goes live. Approved rows are what detection uses.
@MainActor
@Observable
final class LearnedPatternsModel {
    private let database: AppDatabase
    private let store: PatternStore

    var proposedPatterns: [LearnedPattern] = []
    var approvedPatterns: [LearnedPattern] = []
    var proposedGuidance: [LearnedGuidance] = []
    var activeGuidanceDraft: String = ""
    var activeGuidanceSaveStatus: String = "Saved"
    /// channelID → display name (for grouping). Global rows use a synthetic label.
    var channelNames: [String: String] = [:]
    /// patternID → offline precision impact of approving it.
    var deltas: [String: PrecisionDelta] = [:]
    @ObservationIgnored private var lastSavedActiveGuidance: String = ""
    @ObservationIgnored private var guidanceSaveGeneration = 0
    @ObservationIgnored private var activeGuidanceSaveTask: Task<Void, Never>?

    /// Offline precision/false-positive impact of adding one proposed phrase.
    struct PrecisionDelta: Equatable {
        let beforePrecision: Double
        let afterPrecision: Double
        let beforeFalsePositiveRate: Double
        let afterFalsePositiveRate: Double
        let sampleCount: Int

        /// True if approving would lower precision or raise the false-positive rate.
        var regresses: Bool {
            afterPrecision < beforePrecision - 0.0001
                || afterFalsePositiveRate > beforeFalsePositiveRate + 0.0001
        }
    }

    init(database: AppDatabase) {
        self.database = database
        self.store = PatternStore(database: database)
    }

    var hasAnything: Bool {
        !proposedPatterns.isEmpty || !approvedPatterns.isEmpty
            || !proposedGuidance.isEmpty || !activeGuidanceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var pendingProposalCount: Int {
        proposedPatterns.count + proposedGuidance.count
    }

    func displayName(forChannelID channelID: String?) -> String {
        guard let channelID else { return "All channels (global)" }
        return channelNames[channelID].map { "#\($0)" } ?? channelID
    }

    func load() async {
        let patterns = (try? await database.dbWriter.read { db in
            try LearnedPattern.order(Column("createdAt").desc).fetchAll(db)
        }) ?? []
        let guidance = (try? await database.dbWriter.read { db in
            try LearnedGuidance.order(Column("version").desc).fetchAll(db)
        }) ?? []
        let channels = (try? await database.dbWriter.read { db in
            try Channel.fetchAll(db)
        }) ?? []

        channelNames = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        proposedPatterns = patterns.filter { $0.status == .proposed }
        approvedPatterns = patterns.filter { $0.status == .approved }
        proposedGuidance = guidance.filter { $0.status == .proposed }
        let document = (try? await store.activeGuidanceDocument()) ?? ""
        activeGuidanceDraft = document
        lastSavedActiveGuidance = document
        activeGuidanceSaveStatus = "Saved"

        await computeDeltas()
    }

    // MARK: - Actions

    func approve(_ pattern: LearnedPattern) async { await act { try await store.approvePattern(pattern.id) } }
    func reject(_ pattern: LearnedPattern) async { await act { try await store.rejectPattern(pattern.id) } }
    func retire(_ pattern: LearnedPattern) async { await act { try await store.retirePattern(pattern.id) } }

    func approve(_ guidance: LearnedGuidance) async { await act { try await store.approveGuidance(guidance.id) } }
    func reject(_ guidance: LearnedGuidance) async { await act { try await store.rejectGuidance(guidance.id) } }

    func activeGuidanceDidChange() {
        guidanceSaveGeneration += 1
        activeGuidanceSaveTask?.cancel()

        let text = activeGuidanceDraft
        guard normalizedGuidance(text) != normalizedGuidance(lastSavedActiveGuidance) else {
            activeGuidanceSaveStatus = "Saved"
            return
        }

        activeGuidanceSaveStatus = "Saving..."
        let generation = guidanceSaveGeneration
        activeGuidanceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.saveActiveGuidanceIfCurrent(text, generation: generation)
        }
    }

    func retireAll() async { await act { try await store.retireAll() } }

    private func saveActiveGuidanceIfCurrent(_ text: String, generation: Int) async {
        guard generation == guidanceSaveGeneration else { return }
        do {
            try await store.saveActiveGuidanceDocument(text)
            guard generation == guidanceSaveGeneration else { return }
            lastSavedActiveGuidance = text
            activeGuidanceSaveStatus = "Saved"
        } catch {
            guard generation == guidanceSaveGeneration else { return }
            activeGuidanceSaveStatus = "Save failed"
        }
    }

    private func act(_ operation: () async throws -> Void) async {
        try? await operation()
        await load()
    }

    private func normalizedGuidance(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Precision deltas

    private func computeDeltas() async {
        var result: [String: PrecisionDelta] = [:]
        for pattern in proposedPatterns {
            if let delta = await delta(for: pattern) { result[pattern.id] = delta }
        }
        deltas = result
    }

    private func delta(for pattern: LearnedPattern) async -> PrecisionDelta? {
        let samples = await samples(forChannelID: pattern.channelID)
        guard !samples.isEmpty else { return nil }

        // Currently-approved phrases for this scope (channel rows ∪ global) = the baseline.
        let approvedForScope = approvedPatterns.filter {
            pattern.channelID == nil ? $0.channelID == nil
                : ($0.channelID == pattern.channelID || $0.channelID == nil)
        }
        let baselineBank = LearnedPhraseBank(patterns: approvedForScope)
        let candidateBank = LearnedPhraseBank(patterns: approvedForScope + [pattern])

        let before = PrecisionHarness(learned: baselineBank).evaluate(samples)
        let after = PrecisionHarness(learned: candidateBank).evaluate(samples)
        return PrecisionDelta(
            beforePrecision: before.precision,
            afterPrecision: after.precision,
            beforeFalsePositiveRate: before.falsePositiveRate,
            afterFalsePositiveRate: after.falsePositiveRate,
            sampleCount: samples.count
        )
    }

    /// Labeled samples for a scope: a channel's labels (or all channels for global),
    /// joined to message text. matters → attention-worthy.
    private func samples(forChannelID channelID: String?) async -> [PrecisionHarness.Sample] {
        (try? await database.dbWriter.read { db in
            let labels: [TriageLabel]
            if let channelID {
                labels = try TriageLabel.filter(Column("channelID") == channelID).fetchAll(db)
            } else {
                labels = try TriageLabel.fetchAll(db)
            }
            return labels.compactMap { label in
                let key = Message.makeID(channelID: label.channelID, ts: label.messageTS)
                guard let message = try? Message.fetchOne(db, key: key) else { return nil }
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return PrecisionHarness.Sample(text: text, isAttention: label.userVerdict == .matters)
            }
        }) ?? []
    }
}
