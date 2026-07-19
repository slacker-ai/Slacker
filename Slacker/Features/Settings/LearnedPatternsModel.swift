import Foundation
import Observation
import GRDB

/// Backs the learned prompt editor. Historical proposal properties remain available for
/// compatibility, but new automatic evolution writes only approved rows.
@MainActor
@Observable
final class LearnedPatternsModel {
    private let database: AppDatabase
    private let store: PatternStore
    static let globalChannelSelection = "__global__"

    var proposedPatterns: [LearnedPattern] = []
    var approvedPatterns: [LearnedPattern] = []
    var proposedGuidance: [LearnedGuidance] = []
    var activeChannelGuidance: [LearnedGuidance] = []
    var guidanceChannelSelections: [String: String] = [:]
    var activeGuidanceDraft: String = ""
    var activeGuidanceSaveStatus: String = "Saved"
    var selectedGuidanceChannelID: String = ""
    var channelGuidanceDraft: String = ""
    var channelGuidanceSaveStatus: String = "Saved"
    var manualPhraseDraft: String = ""
    var manualPhraseBucket: RuleBucket = .ask
    var manualPhraseChannelSelection: String = LearnedPatternsModel.globalChannelSelection
    var manualPhraseSaveStatus: String = ""
    /// channelID → display name (for grouping). Global rows use a synthetic label.
    var channelNames: [String: String] = [:]
    var channels: [Channel] = []
    /// patternID → offline precision impact of approving it.
    var deltas: [String: PrecisionDelta] = [:]
    @ObservationIgnored private var lastSavedActiveGuidance: String = ""
    @ObservationIgnored private var guidanceSaveGeneration = 0
    @ObservationIgnored private var activeGuidanceSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedChannelGuidance: String = ""
    @ObservationIgnored private var channelGuidanceSaveGeneration = 0
    @ObservationIgnored private var channelGuidanceSaveTask: Task<Void, Never>?

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
            || !proposedGuidance.isEmpty || !activeChannelGuidance.isEmpty
            || !activeGuidanceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveLearnedGuidance: String {
        [activeGuidanceDraft, channelGuidanceDraft]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var effectiveClassifierPrompt: String {
        LLMClassifier.effectiveSystemPrompt(guidance: effectiveLearnedGuidance)
    }

    var effectiveResolutionPrompt: String {
        ItemThreadSummaryService.effectiveSystemPrompt(guidance: effectiveLearnedGuidance)
    }

    var effectiveLearnedCharacterCount: Int {
        activeGuidanceDraft.count + channelGuidanceDraft.count
    }

    var pendingProposalCount: Int {
        proposedPatterns.count + proposedGuidance.count
    }

    var safeProposedPhraseCount: Int {
        proposedPatterns.filter { deltas[$0.id]?.regresses == false }.count
    }

    var safePhraseBulkStatus: String {
        guard !proposedPatterns.isEmpty else { return "No phrase proposals pending." }
        if safeProposedPhraseCount > 0 {
            return "\(safeProposedPhraseCount) phrase proposal(s) have a non-regressing precision estimate."
        }
        if proposedPatterns.allSatisfy({ deltas[$0.id] == nil }) {
            return "Bulk approval needs labeled examples first. Review individual phrase cards if one is clearly correct."
        }
        return "Current phrase proposals may reduce precision. Review them individually."
    }

    var canSaveManualPhrase: Bool {
        RuleEngine.isAdmissibleLearnedPhrase(normalizedManualPhrase, for: manualPhraseBucket)
    }

    var manualPhraseValidationMessage: String? {
        let phrase = normalizedManualPhrase
        guard !phrase.isEmpty else { return nil }
        guard phrase.count >= 6, phrase.contains(" ") else {
            return "Use a specific multi-word phrase."
        }
        guard RuleEngine.isAdmissibleLearnedPhrase(phrase, for: manualPhraseBucket) else {
            return "That phrase is already covered by built-in rules."
        }
        return nil
    }

    private var normalizedManualPhrase: String {
        manualPhraseDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func displayName(forChannelID channelID: String?) -> String {
        guard let channelID else { return "All channels (global)" }
        return channelNames[channelID].map { "#\($0)" } ?? channelID
    }

    func load() async {
        let hasUnsavedGlobalEdit = normalizedGuidance(activeGuidanceDraft)
            != normalizedGuidance(lastSavedActiveGuidance)
        let hasUnsavedChannelEdit = normalizedGuidance(channelGuidanceDraft)
            != normalizedGuidance(lastSavedChannelGuidance)

        // Older builds allowed semantically-equivalent guidance cards to accumulate.
        // Clean them before computing the pending count so the UI never shows duplicates.
        try? await store.retireRedundantGuidanceProposals()

        let patterns = (try? await database.dbWriter.read { db in
            try LearnedPattern.order(Column("createdAt").desc).fetchAll(db)
        }) ?? []
        let guidance = (try? await database.dbWriter.read { db in
            try LearnedGuidance.order(Column("version").desc).fetchAll(db)
        }) ?? []
        let channels = (try? await database.dbWriter.read { db in
            try Channel.fetchAll(db)
        }) ?? []

        self.channels = channels
        if selectedGuidanceChannelID.isEmpty
            || !channels.contains(where: { $0.id == selectedGuidanceChannelID }) {
            selectedGuidanceChannelID = channels.first?.id ?? ""
        }
        if manualPhraseChannelSelection != Self.globalChannelSelection,
           !channels.contains(where: { $0.id == manualPhraseChannelSelection }) {
            manualPhraseChannelSelection = Self.globalChannelSelection
        }
        channelNames = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        proposedPatterns = patterns.filter { $0.status == .proposed }
        approvedPatterns = patterns.filter { $0.status == .approved }
        proposedGuidance = guidance.filter { $0.status == .proposed }
        var seenChannelIDs = Set<String>()
        activeChannelGuidance = guidance.filter { item in
            guard item.status == .approved, let channelID = item.channelID else { return false }
            return seenChannelIDs.insert(channelID).inserted
        }

        let proposalIDs = Set(proposedGuidance.map(\.id))
        var selections = guidanceChannelSelections.filter { proposalIDs.contains($0.key) }
        for proposal in proposedGuidance where selections[proposal.id] == nil {
            selections[proposal.id] = proposal.channelID ?? Self.globalChannelSelection
        }
        guidanceChannelSelections = selections

        let document = (try? await store.activeGuidanceDocument()) ?? ""
        if !hasUnsavedGlobalEdit {
            activeGuidanceDraft = document
            lastSavedActiveGuidance = document
            activeGuidanceSaveStatus = "Saved"
        }

        let channelDocument = selectedGuidanceChannelID.isEmpty
            ? ""
            : ((try? await store.activeGuidanceDocument(forChannelID: selectedGuidanceChannelID)) ?? "")
        if !hasUnsavedChannelEdit {
            channelGuidanceDraft = channelDocument
            lastSavedChannelGuidance = channelDocument
            channelGuidanceSaveStatus = "Saved"
        }

        await computeDeltas()
    }

    // MARK: - Actions

    func approve(_ pattern: LearnedPattern) async { await act { try await store.approvePattern(pattern.id) } }
    func reject(_ pattern: LearnedPattern) async { await act { try await store.rejectPattern(pattern.id) } }
    func retire(_ pattern: LearnedPattern) async { await act { try await store.retirePattern(pattern.id) } }

    func guidanceChannelSelection(for guidance: LearnedGuidance) -> String {
        guidanceChannelSelections[guidance.id]
            ?? guidance.channelID
            ?? Self.globalChannelSelection
    }

    func setGuidanceChannelSelection(_ selection: String, for guidance: LearnedGuidance) {
        guard selection == Self.globalChannelSelection
                || channels.contains(where: { $0.id == selection }) else { return }
        guidanceChannelSelections[guidance.id] = selection
    }

    func approve(_ guidance: LearnedGuidance) async {
        let selection = guidanceChannelSelection(for: guidance)
        let channelID = selection == Self.globalChannelSelection ? nil : selection
        await act { try await store.approveGuidance(guidance.id, channelID: channelID) }
    }
    func reject(_ guidance: LearnedGuidance) async { await act { try await store.rejectGuidance(guidance.id) } }
    func retire(_ guidance: LearnedGuidance) async { await act { try await store.retireGuidance(guidance.id) } }

    func approveSafePhrases() async {
        let safeIDs = proposedPatterns
            .filter { deltas[$0.id]?.regresses == false }
            .map(\.id)
        guard !safeIDs.isEmpty else { return }
        await act {
            for id in safeIDs {
                try await store.approvePattern(id)
            }
        }
    }

    func rejectAllProposals() async {
        await act { try await store.rejectAllProposals() }
    }

    func saveManualPhrase() async {
        let phrase = normalizedManualPhrase
        guard RuleEngine.isAdmissibleLearnedPhrase(phrase) else {
            manualPhraseSaveStatus = manualPhraseValidationMessage ?? "Enter a phrase first."
            return
        }

        let channelID = manualPhraseChannelSelection == Self.globalChannelSelection ? nil : manualPhraseChannelSelection
        await act {
            try await store.saveManualPattern(channelID: channelID, bucket: manualPhraseBucket, phrase: phrase)
        }
        manualPhraseDraft = ""
        manualPhraseSaveStatus = "Saved"
    }

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

    func selectGuidanceChannel(_ channelID: String) async {
        guard channels.contains(where: { $0.id == channelID }) else { return }

        // Collapsing and reopening the same row must not reload over an edit that is
        // still inside the autosave debounce window.
        guard channelID != selectedGuidanceChannelID else { return }

        // A channel switch is an explicit boundary: persist the current draft now
        // instead of cancelling its debounced save and silently losing the edit.
        if !selectedGuidanceChannelID.isEmpty,
           normalizedGuidance(channelGuidanceDraft) != normalizedGuidance(lastSavedChannelGuidance) {
            channelGuidanceSaveTask?.cancel()
            channelGuidanceSaveGeneration += 1
            do {
                try await store.saveGuidanceDocument(
                    channelGuidanceDraft,
                    channelID: selectedGuidanceChannelID
                )
                lastSavedChannelGuidance = channelGuidanceDraft
                channelGuidanceSaveStatus = "Saved"
            } catch {
                channelGuidanceSaveStatus = "Save failed"
                return
            }
        }

        channelGuidanceSaveTask?.cancel()
        channelGuidanceSaveGeneration += 1
        selectedGuidanceChannelID = channelID
        let document = (try? await store.activeGuidanceDocument(forChannelID: channelID)) ?? ""
        channelGuidanceDraft = document
        lastSavedChannelGuidance = document
        channelGuidanceSaveStatus = "Saved"
    }

    func channelGuidanceDidChange() {
        channelGuidanceSaveGeneration += 1
        channelGuidanceSaveTask?.cancel()

        let text = channelGuidanceDraft
        guard normalizedGuidance(text) != normalizedGuidance(lastSavedChannelGuidance) else {
            channelGuidanceSaveStatus = "Saved"
            return
        }
        guard !selectedGuidanceChannelID.isEmpty else { return }

        channelGuidanceSaveStatus = "Saving..."
        let generation = channelGuidanceSaveGeneration
        let channelID = selectedGuidanceChannelID
        channelGuidanceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.saveChannelGuidanceIfCurrent(
                text,
                channelID: channelID,
                generation: generation
            )
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

    private func saveChannelGuidanceIfCurrent(
        _ text: String,
        channelID: String,
        generation: Int
    ) async {
        guard generation == channelGuidanceSaveGeneration,
              channelID == selectedGuidanceChannelID else { return }
        do {
            try await store.saveGuidanceDocument(text, channelID: channelID)
            guard generation == channelGuidanceSaveGeneration,
                  channelID == selectedGuidanceChannelID else { return }
            lastSavedChannelGuidance = text
            channelGuidanceSaveStatus = "Saved"
        } catch {
            guard generation == channelGuidanceSaveGeneration,
                  channelID == selectedGuidanceChannelID else { return }
            channelGuidanceSaveStatus = "Save failed"
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
