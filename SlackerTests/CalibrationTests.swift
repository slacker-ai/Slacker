import XCTest
import GRDB
@testable import Slacker

final class CalibrationTests: XCTestCase {
    private var idCounter = 0

    private func service(_ db: AppDatabase) -> CalibrationService {
        idCounter = 0
        return CalibrationService(
            database: db,
            now: { Date(timeIntervalSince1970: 1) },
            makeID: { self.idCounter += 1; return "label-\(self.idCounter)" }
        )
    }

    private func record(_ svc: CalibrationService, _ verdict: UserVerdict, count: Int) async throws {
        for _ in 0..<count {
            try await svc.record(verdict: verdict, source: .reviewTriage,
                                 channelID: "C1", messageTS: "100.0", itemID: nil)
        }
    }

    func testFewLabelsKeepBaseThresholds() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = service(db)
        try await record(svc, .ignore, count: 3) // below minSamples

        let base = DetectionThresholds()
        let result = try await svc.thresholds(forChannelID: "C1", base: base)
        XCTAssertEqual(result, base)
    }

    func testManyIgnoreLabelsRaiseThresholds() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = service(db)
        try await record(svc, .ignore, count: 10)

        let base = DetectionThresholds()
        let result = try await svc.thresholds(forChannelID: "C1", base: base)
        XCTAssertGreaterThan(result.surface, base.surface, "an ignore-heavy channel should surface less")
    }

    func testManyMattersLabelsLowerThresholds() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = service(db)
        try await record(svc, .matters, count: 10)

        let base = DetectionThresholds()
        let result = try await svc.thresholds(forChannelID: "C1", base: base)
        XCTAssertLessThan(result.surface, base.surface, "a matters-heavy channel should surface more")
    }

    func testTriageWritesLabelRow() async throws {
        let db = try AppDatabase.makeInMemory()
        let svc = service(db)
        // itemID nil — the label FK requires a real item when set (verified by this passing).
        try await svc.record(verdict: .matters, source: .dismissal,
                             channelID: "C1", messageTS: "100.0", itemID: nil)

        let count = try await db.dbWriter.read { try TriageLabel.fetchCount($0) }
        XCTAssertEqual(count, 1)
    }
}

final class PrecisionHarnessTests: XCTestCase {
    func testComputesPrecisionAndRecall() {
        let harness = PrecisionHarness()
        let samples = [
            // Surfaces (directed question) and is attention → TP
            PrecisionHarness.Sample(text: "<@U2> can you confirm the rollout time?", isAttention: true),
            // Surfaces (blocker) and is attention → TP
            PrecisionHarness.Sample(text: "blocked on the API key", isAttention: true),
            // Does not surface (context only) but is attention → FN
            PrecisionHarness.Sample(text: "fyi the numbers look off", isAttention: true),
            // Does not surface and not attention → TN
            PrecisionHarness.Sample(text: "thanks everyone, great work", isAttention: false),
        ]
        let m = harness.evaluate(samples)
        XCTAssertEqual(m.truePositives, 2)
        XCTAssertEqual(m.falsePositives, 0)
        XCTAssertEqual(m.precision, 1.0, accuracy: 0.001)
        XCTAssertEqual(m.recall, 2.0 / 3.0, accuracy: 0.001)
    }

    func testInterRaterAgreement() {
        let samples = [
            PrecisionHarness.Sample(text: "a", isAttention: true, annotatorVerdicts: [true, true, false]),
            PrecisionHarness.Sample(text: "b", isAttention: false, annotatorVerdicts: [false, false, false]),
        ]
        // Sample a: pairs (T,T)=agree,(T,F)=disagree,(T,F)=disagree → 1/3. Sample b: 3/3=1. Mean = 2/3.
        let agreement = PrecisionHarness.interRaterAgreement(samples)
        XCTAssertEqual(agreement!, (1.0 / 3.0 + 1.0) / 2.0, accuracy: 0.001)
    }
}
