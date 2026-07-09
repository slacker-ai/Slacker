import XCTest
import GRDB
@testable import Slacker

/// Stub LLM for evolution tests: returns a fixed string, can throw, and counts calls.
final class EvolutionStubLLM: LLMClient, @unchecked Sendable {
    var response: String
    var shouldThrow: Bool
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var lastRequest: LLMRequest?

    init(response: String = "", shouldThrow: Bool = false) {
        self.response = response
        self.shouldThrow = shouldThrow
    }

    func complete(_ request: LLMRequest) async throws -> String {
        lock.lock()
        callCount += 1
        lastRequest = request
        lock.unlock()
        if shouldThrow { throw LLMError.emptyResponse }
        return response
    }
}

// MARK: - Proposal parsing

final class PatternEvolutionParseTests: XCTestCase {
    func testParsesStrictJSON() {
        let raw = #"{"phrases":[{"bucket":"blocker","phrase":"red alert on","rationale":"jargon"}],"guidance":"Be strict."}"#
        let proposal = PatternEvolutionService.parse(raw)
        XCTAssertEqual(proposal?.phrases.count, 1)
        XCTAssertEqual(proposal?.phrases.first?.bucket, "blocker")
        XCTAssertEqual(proposal?.phrases.first?.phrase, "red alert on")
        XCTAssertEqual(proposal?.guidance, "Be strict.")
    }

    func testParsesJSONWrappedInCodeFences() {
        let raw = "```json\n{\"phrases\":[],\"guidance\":\"hi\"}\n```"
        XCTAssertEqual(PatternEvolutionService.parse(raw)?.guidance, "hi")
    }

    func testParsesJSONWithSurroundingProse() {
        let raw = "Here you go: {\"phrases\":[],\"guidance\":\"ok\"} done"
        XCTAssertEqual(PatternEvolutionService.parse(raw)?.guidance, "ok")
    }

    func testMissingFieldsTolerated() {
        // Absent phrases/guidance default to empty rather than failing.
        let proposal = PatternEvolutionService.parse(#"{"guidance":"only guidance"}"#)
        XCTAssertEqual(proposal?.phrases.count, 0)
        XCTAssertEqual(proposal?.guidance, "only guidance")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(PatternEvolutionService.parse("not json at all"))
    }
}

// MARK: - Store idempotency

final class PatternStoreTests: XCTestCase {
    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        return db
    }

    func testDuplicateProposalsInsertedOnce() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)
        func pattern() -> LearnedPattern {
            LearnedPattern(id: UUID().uuidString, channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 3,
                           createdAt: Date(timeIntervalSince1970: 1))
        }
        try await store.insertProposals([pattern()], guidance: nil)
        try await store.insertProposals([pattern()], guidance: nil)  // same scope+bucket+phrase

        let count = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(count, 1)
    }

    func testActivePhraseBankReadsApprovedAndGlobal() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)
        try await store.insertProposals([
            LearnedPattern(id: "p1", channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .approved, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
            LearnedPattern(id: "p2", channelID: nil, bucket: .help, phrase: "spin up a",
                           status: .approved, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
            LearnedPattern(id: "p3", channelID: "C1", bucket: .ask, phrase: "ping me when",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
        ], guidance: nil)

        let bank = try await store.activePhraseBank(forChannelID: "C1")
        XCTAssertEqual(bank.phrases(for: .blocker), ["red alert on"])  // channel-scoped, approved
        XCTAssertEqual(bank.phrases(for: .help), ["spin up a"])         // global, approved
        XCTAssertTrue(bank.phrases(for: .ask).isEmpty)                  // proposed → excluded
    }

    func testApproveGuidanceAppendsToSingleActiveDocument() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)
        try await store.saveActiveGuidanceDocument("# Slacker guidance\n\n- Existing rule.")
        try await store.insertProposals([], guidance: LearnedGuidance(
            id: "g1",
            channelID: "C1",
            text: "Treat 'paging now' as resolved for ping/page asks.",
            status: .proposed,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        try await store.approveGuidance("g1")

        let document = try await store.activeGuidanceDocument()
        XCTAssertTrue(document.contains("Existing rule."))
        XCTAssertTrue(document.contains("Treat 'paging now' as resolved"))
        let proposedCount = try await db.dbWriter.read {
            try LearnedGuidance.filter(Column("status") == PatternStatus.proposed.rawValue).fetchCount($0)
        }
        XCTAssertEqual(proposedCount, 0)
    }

    func testSaveActiveGuidanceDocumentVersionsEditableText() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)

        try await store.saveActiveGuidanceDocument("# Rules\n\n- First.")
        try await store.saveActiveGuidanceDocument("# Rules\n\n- Edited.")

        let document = try await store.activeGuidanceDocument()
        XCTAssertEqual(document, "# Rules\n\n- Edited.")
        let approvedCount = try await db.dbWriter.read {
            try LearnedGuidance.filter(Column("status") == PatternStatus.approved.rawValue).fetchCount($0)
        }
        XCTAssertEqual(approvedCount, 2, "Manual edits are versioned, not destructive.")
    }

    func testSaveActiveGuidanceDocumentSkipsUnchangedText() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)

        try await store.saveActiveGuidanceDocument("# Rules\n\n- Same.")
        try await store.saveActiveGuidanceDocument("  # Rules\n\n- Same.  ")

        let approvedCount = try await db.dbWriter.read {
            try LearnedGuidance.filter(Column("status") == PatternStatus.approved.rawValue).fetchCount($0)
        }
        XCTAssertEqual(approvedCount, 1, "Auto-save must not create duplicate versions for unchanged text.")
    }

    func testManualApprovedPhraseFeedsActivePhraseBankImmediately() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)

        try await store.saveManualPattern(channelID: "C1", bucket: .blocker, phrase: "red alert on")

        let bank = try await store.activePhraseBank(forChannelID: "C1")
        XCTAssertEqual(bank.phrases(for: .blocker), ["red alert on"])
        let stored = try await db.dbWriter.read { try LearnedPattern.fetchOne($0) }
        XCTAssertEqual(stored?.status, .approved)
        XCTAssertEqual(stored?.source, .manual)
    }

    func testRejectAllProposalsLeavesApprovedRowsActive() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)
        try await store.insertProposals([
            LearnedPattern(id: "proposed", channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
            LearnedPattern(id: "approved", channelID: "C1", bucket: .help, phrase: "spin up a",
                           status: .approved, source: .manual, rationale: nil, supportingLabelCount: 0,
                           createdAt: Date(timeIntervalSince1970: 1), decidedAt: Date(timeIntervalSince1970: 1)),
        ], guidance: LearnedGuidance(id: "guidance", channelID: "C1", text: "Ignore deploy FYIs.",
                                     status: .proposed, version: 1, createdAt: Date(timeIntervalSince1970: 1)))

        try await store.rejectAllProposals()

        let statuses = try await db.dbWriter.read { db in
            try LearnedPattern.fetchAll(db).reduce(into: [String: PatternStatus]()) { $0[$1.id] = $1.status }
        }
        XCTAssertEqual(statuses["proposed"], .rejected)
        XCTAssertEqual(statuses["approved"], .approved)
        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchOne($0, key: "guidance") }
        XCTAssertEqual(guidance?.status, .rejected)
    }

    func testSimilarGuidanceIsDetected() async throws {
        let db = try makeDB()
        let store = PatternStore(database: db)
        try await store.insertProposals([], guidance: LearnedGuidance(
            id: "g1",
            channelID: "C1",
            text: "When a thread says false alarm, do not surface the original request.",
            status: .proposed,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let similar = try await store.hasSimilarGuidance(
            "When the thread says false alarm do not surface original requests",
            channelID: "C1"
        )
        XCTAssertTrue(similar)
    }
}

@MainActor
final class LearnedPatternsModelTests: XCTestCase {
    private func seedChannel(_ db: AppDatabase) throws {
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
    }

    func testActiveGuidanceAutoSavesDraft() async throws {
        let db = try AppDatabase.makeInMemory()
        let model = LearnedPatternsModel(database: db)
        await model.load()

        model.activeGuidanceDraft = "# Rules\n\n- Auto-save edits."
        model.activeGuidanceDidChange()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let document = try await PatternStore(database: db).activeGuidanceDocument()
        XCTAssertEqual(document, "# Rules\n\n- Auto-save edits.")
        XCTAssertEqual(model.activeGuidanceSaveStatus, "Saved")
    }

    func testPendingEvolutionCountFeedsModel() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try await PatternStore(database: db).insertProposals([
            LearnedPattern(id: "p1", channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1))
        ], guidance: LearnedGuidance(id: "g1", channelID: "C1", text: "Treat paging now as resolved.",
                                     status: .proposed, version: 1, createdAt: Date(timeIntervalSince1970: 1)))

        let model = LearnedPatternsModel(database: db)
        await model.load()

        XCTAssertEqual(model.pendingProposalCount, 2)
    }

    func testApprovingAndRejectingFromEvolutionModelReloadsStatus() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try await PatternStore(database: db).insertProposals([
            LearnedPattern(id: "p1", channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
            LearnedPattern(id: "p2", channelID: "C1", bucket: .help, phrase: "spin up a",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
        ], guidance: nil)

        let model = LearnedPatternsModel(database: db)
        await model.load()
        await model.approve(try XCTUnwrap(model.proposedPatterns.first { $0.id == "p1" }))
        await model.reject(try XCTUnwrap(model.proposedPatterns.first { $0.id == "p2" }))

        XCTAssertEqual(model.pendingProposalCount, 0)
        XCTAssertEqual(model.approvedPatterns.map(\.id), ["p1"])
        let rejected = try await db.dbWriter.read { try LearnedPattern.fetchOne($0, key: "p2") }
        XCTAssertEqual(rejected?.status, .rejected)
    }

    func testModelBulkRejectAffectsOnlyProposedRows() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        try await PatternStore(database: db).insertProposals([
            LearnedPattern(id: "proposed", channelID: "C1", bucket: .blocker, phrase: "red alert on",
                           status: .proposed, source: .llm, rationale: nil, supportingLabelCount: 1,
                           createdAt: Date(timeIntervalSince1970: 1)),
            LearnedPattern(id: "approved", channelID: "C1", bucket: .help, phrase: "spin up a",
                           status: .approved, source: .manual, rationale: nil, supportingLabelCount: 0,
                           createdAt: Date(timeIntervalSince1970: 1), decidedAt: Date(timeIntervalSince1970: 1)),
        ], guidance: nil)

        let model = LearnedPatternsModel(database: db)
        await model.load()
        await model.rejectAllProposals()

        XCTAssertEqual(model.pendingProposalCount, 0)
        let approved = try await db.dbWriter.read { try LearnedPattern.fetchOne($0, key: "approved") }
        XCTAssertEqual(approved?.status, .approved)
    }

    func testManualPhraseSaveCreatesApprovedPattern() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedChannel(db)
        let model = LearnedPatternsModel(database: db)
        await model.load()

        model.manualPhraseBucket = .blocker
        model.manualPhraseChannelSelection = "C1"
        model.manualPhraseDraft = "red alert on"
        await model.saveManualPhrase()

        XCTAssertEqual(model.manualPhraseSaveStatus, "Saved")
        XCTAssertEqual(model.approvedPatterns.first?.phrase, "red alert on")
        let bank = try await PatternStore(database: db).activePhraseBank(forChannelID: "C1")
        XCTAssertEqual(bank.phrases(for: .blocker), ["red alert on"])
    }

    func testInvalidManualPhraseShowsSaveError() async throws {
        let db = try AppDatabase.makeInMemory()
        let model = LearnedPatternsModel(database: db)
        await model.load()

        model.manualPhraseDraft = "oops"
        await model.saveManualPhrase()

        XCTAssertEqual(model.manualPhraseSaveStatus, "Use a specific multi-word phrase.")
        let count = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Evolution service (per-triage learning, validation, integration)

final class PatternEvolutionServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        return db
    }

    /// Insert a backing message so the triaged ts resolves to text.
    private func seedMessage(_ db: AppDatabase, ts: String, text: String, reactionsJSON: String? = nil) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: ts, userID: "U1",
                        text: text, reactionsJSON: reactionsJSON,
                        ingestedAt: Date(timeIntervalSince1970: 1)).insert(dbc)
        }
    }

    private func seedReply(_ db: AppDatabase, ts: String, rootTS: String, text: String, reactionsJSON: String? = nil) throws {
        try db.dbWriter.write { dbc in
            try Message(channelID: "C1", ts: ts, threadTS: rootTS, userID: "U2",
                        text: text, reactionsJSON: reactionsJSON,
                        ingestedAt: Date(timeIntervalSince1970: 1)).insert(dbc)
        }
    }

    private func service(_ db: AppDatabase, llm: LLMClient?) -> PatternEvolutionService {
        var svc = PatternEvolutionService(database: db, llm: llm, store: PatternStore(database: db))
        svc.now = { self.fixedNow }
        return svc
    }

    func testNoLLMSkipsEntirely() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "the payments deploy is blocked")
        await service(db, llm: nil).evolveFromTriage(channelID: "C1", messageTS: "1", verdict: .matters)
        let count = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testMissingMessageProposesNothing() async throws {
        let db = try makeDB()  // no backing message for ts "404"
        let stub = EvolutionStubLLM(response: #"{"phrases":[{"bucket":"blocker","phrase":"red alert on","rationale":"x"}],"guidance":""}"#)
        await service(db, llm: stub).evolveFromTriage(channelID: "C1", messageTS: "404", verdict: .matters)
        XCTAssertEqual(stub.callCount, 0, "A pruned/missing message must not call the LLM.")
        let count = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testProposesValidatesAndCapsPerTriage() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "red alert on the payments deploy")

        // 5 admissible + 2 inadmissible (single token / base phrase) -> expect cap at 1, none invalid.
        let valid = (0..<5).map { #"{"bucket":"blocker","phrase":"alert phrase \#($0) here","rationale":"x"}"# }
        let invalid = [#"{"bucket":"blocker","phrase":"fix","rationale":"x"}"#,
                       #"{"bucket":"ask","phrase":"can you","rationale":"x"}"#]
        let json = #"{"phrases":[\#((valid + invalid).joined(separator: ","))],"guidance":"Apply team jargon."}"#
        let stub = EvolutionStubLLM(response: json)

        await service(db, llm: stub).evolveFromTriage(channelID: "C1", messageTS: "1", verdict: .matters)
        XCTAssertEqual(stub.callCount, 1)

        let proposed = try await db.dbWriter.read {
            try LearnedPattern.filter(Column("status") == "proposed").fetchAll($0)
        }
        XCTAssertEqual(proposed.count, 1, "Proposals must be capped per triage.")
        for p in proposed {
            XCTAssertTrue(RuleEngine.isAdmissibleLearnedPhrase(p.phrase), "Invalid phrase leaked: \(p.phrase)")
            XCTAssertEqual(p.supportingLabelCount, 1, "Single-example proposals report a count of 1.")
        }
        // Guidance proposed too.
        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchAll($0) }
        XCTAssertEqual(guidance.count, 1)
        XCTAssertEqual(guidance.first?.status, .proposed)
    }

    func testIgnoreVerdictProposesGuidanceOnly() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "lunch is in the kitchen")
        let stub = EvolutionStubLLM(response: #"{"phrases":[{"bucket":"ask","phrase":"lunch is in","rationale":"bad idea"}],"guidance":"Social/logistics chatter is not actionable."}"#)

        await service(db, llm: stub).evolveFromTriage(channelID: "C1", messageTS: "1", verdict: .ignore)

        let patterns = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(patterns, 0)
        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchAll($0) }
        XCTAssertEqual(guidance.count, 1)
        XCTAssertEqual(guidance.first?.status, .proposed)
    }

    func testNearDuplicateGuidanceIsNotReproposed() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "false alarm, vendor status page blip")
        try await PatternStore(database: db).insertProposals([], guidance: LearnedGuidance(
            id: "g1",
            channelID: "C1",
            text: "When a thread says false alarm, do not surface the original request.",
            status: .proposed,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let stub = EvolutionStubLLM(response: #"{"phrases":[],"guidance":"When the thread says false alarm do not surface original requests."}"#)

        await service(db, llm: stub).evolveFromTriage(
            channelID: "C1",
            messageTS: "1",
            verdict: .ignore,
            source: .dismissal
        )

        let guidanceCount = try await db.dbWriter.read { try LearnedGuidance.fetchCount($0) }
        XCTAssertEqual(guidanceCount, 1)
    }

    func testResolvedTriageUsesThreadContextAndDoesNotProposeRootTriggerPhrase() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "@Daanish Hindustani can you ping the oncall about the payments timeouts?")
        try seedReply(db, ts: "2", rootTS: "1", text: "paging now, adding the dashboard link here")
        let stub = EvolutionStubLLM(response: #"{"phrases":[{"bucket":"help","phrase":"ping the oncall","rationale":"root ask"}],"guidance":"For ping/page requests, replies like paging now or adding the dashboard link mean the coordination ask is resolved."}"#)

        await service(db, llm: stub).evolveFromTriage(
            channelID: "C1",
            messageTS: "1",
            verdict: .matters,
            source: .markResolved
        )

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(stub.lastRequest?.user.contains("TRIAGED THREAD") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("ping the oncall") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("paging now, adding the dashboard link here") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("source: mark_resolved") == true)

        let patterns = try await db.dbWriter.read { try LearnedPattern.fetchAll($0) }
        XCTAssertTrue(patterns.isEmpty, "Resolve-click evolution must not learn the original ask as a new trigger phrase.")
        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchAll($0) }
        XCTAssertEqual(guidance.count, 1)
        XCTAssertTrue(guidance.first?.text.contains("paging now") == true)
    }

    func testResolvedTriageIncludesReactionMetadataForGuidance() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "@Daanish Hindustani can you confirm the access issue?")
        try seedReply(db, ts: "2", rootTS: "1", text: "confirmed",
                      reactionsJSON: #"[{"name":"white_check_mark","count":1},{"name":"eyes","count":1}]"#)
        let stub = EvolutionStubLLM(response: #"{"phrases":[],"guidance":"A white_check_mark reaction on a confirmation reply means the access ask is resolved; eyes alone means in progress."}"#)

        await service(db, llm: stub).evolveFromTriage(
            channelID: "C1",
            messageTS: "1",
            verdict: .matters,
            source: .markResolved
        )

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(stub.lastRequest?.system.contains("emoji reactions") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains(":white_check_mark: x1 resolved_signal") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains(":eyes: x1 open_signal") == true)

        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchAll($0) }
        XCTAssertEqual(guidance.count, 1)
        XCTAssertTrue(guidance.first?.text.contains("white_check_mark") == true)
    }

    func testEvolutionPromptStripsFencedLogsButKeepsMetadata() async throws {
        let db = try makeDB()
        try seedMessage(
            db,
            ts: "1",
            text: "can someone check the deploy?\n```production is down\nfailed to boot\n```",
            reactionsJSON: #"[{"name":"eyes","count":1}]"#
        )
        let stub = EvolutionStubLLM(response: #"{"phrases":[],"guidance":"Eyes means in-progress, not resolved."}"#)

        await service(db, llm: stub).evolveFromTriage(
            channelID: "C1",
            messageTS: "1",
            verdict: .ignore,
            source: .dismissal
        )

        XCTAssertTrue(stub.lastRequest?.user.contains("can someone check the deploy?") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains(":eyes: x1 open_signal") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("production is down") == true)
        XCTAssertFalse(stub.lastRequest?.user.contains("failed to boot") == true)
    }

    func testDismissTriageUsesRootAndRepliesForGuidance() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "can someone look at the payments dashboard?")
        try seedReply(db, ts: "2", rootTS: "1", text: "false alarm, this was a vendor status-page blip")
        let stub = EvolutionStubLLM(response: #"{"phrases":[],"guidance":"When the thread clarifies a request was a false alarm or vendor status-page blip, do not surface similar items."}"#)

        await service(db, llm: stub).evolveFromTriage(
            channelID: "C1",
            messageTS: "1",
            verdict: .ignore,
            source: .dismissal
        )

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(stub.lastRequest?.user.contains("TRIAGED THREAD") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("can someone look at the payments dashboard?") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("false alarm, this was a vendor status-page blip") == true)
        XCTAssertTrue(stub.lastRequest?.user.contains("source: dismissal") == true)

        let guidance = try await db.dbWriter.read { try LearnedGuidance.fetchAll($0) }
        XCTAssertEqual(guidance.count, 1)
        XCTAssertTrue(guidance.first?.text.contains("false alarm") == true)
    }

    func testLLMFailureWritesNothingAndDoesNotCrash() async throws {
        let db = try makeDB()
        try seedMessage(db, ts: "1", text: "the payments deploy is blocked")
        let stub = EvolutionStubLLM(shouldThrow: true)
        await service(db, llm: stub).evolveFromTriage(channelID: "C1", messageTS: "1", verdict: .matters)

        let count = try await db.dbWriter.read { try LearnedPattern.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testApprovedProposalSurfacesInDetection() async throws {
        let db = try makeDB()
        // A root message the base rules treat as context-only — also the one being triaged.
        try seedMessage(db, ts: "100", text: "red alert on the payments deploy")

        let store = PatternStore(database: db)
        let stub = EvolutionStubLLM(
            response: #"{"phrases":[{"bucket":"blocker","phrase":"red alert on","rationale":"jargon"}],"guidance":"Treat red alert as urgent."}"#
        )
        await service(db, llm: stub).evolveFromTriage(channelID: "C1", messageTS: "100", verdict: .matters)

        let detection = DetectionService(database: db, patternStore: store)

        // Before approval: proposal is inert → no surfaced item.
        try await detection.detectWatchedChannels()
        let before = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100" && Column("state") == "surfaced").fetchCount($0)
        }
        XCTAssertEqual(before, 0)

        // Approve the mined phrase, then re-run detection.
        let proposed = try await db.dbWriter.read {
            try LearnedPattern.filter(Column("status") == "proposed").fetchOne($0)
        }
        try await store.approvePattern(try XCTUnwrap(proposed).id)
        try await detection.detectWatchedChannels()

        let after = try await db.dbWriter.read {
            try Item.filter(Column("rootMessageTS") == "100" && Column("state") == "surfaced").fetchCount($0)
        }
        XCTAssertEqual(after, 1, "Approved learned phrase should surface the matching message.")
    }
}
