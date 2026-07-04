import Foundation
import GRDB

/// The labeling flywheel (§6b-D / §7.5). Every triage writes a `TriageLabel`; over
/// time the accumulated labels per channel shift detection thresholds toward this
/// manager's definition of attention.
struct CalibrationService {
    let database: AppDatabase
    var now: () -> Date = { Date() }
    var makeID: () -> String = { UUID().uuidString }

    /// Minimum labels in a channel before calibration deviates from defaults.
    private let minSamples = 5
    /// Maximum threshold shift in either direction.
    private let maxShift = 0.2

    /// Record a triage decision as a labeled example.
    func record(
        verdict: UserVerdict,
        source: LabelSource,
        channelID: String,
        messageTS: String,
        itemID: String?
    ) async throws {
        let label = TriageLabel(
            id: makeID(),
            itemID: itemID,
            messageTS: messageTS,
            channelID: channelID,
            userVerdict: verdict,
            source: source,
            createdAt: now()
        )
        try await database.dbWriter.write { db in
            try label.insert(db)
        }
    }

    /// Calibrated base thresholds for a channel, derived from its label history.
    /// More "ignore" labels → raise thresholds (surface less); more "matters" → lower.
    /// Sensitivity is applied separately by the classifier.
    func thresholds(forChannelID channelID: String, base: DetectionThresholds) async throws -> DetectionThresholds {
        let labels = try await database.dbWriter.read { db in
            try TriageLabel.filter(Column("channelID") == channelID).fetchAll(db)
        }
        guard labels.count >= minSamples else { return base }

        let ignoreCount = labels.filter { $0.userVerdict == .ignore }.count
        let ignoreRate = Double(ignoreCount) / Double(labels.count)

        // ignoreRate 0.5 → no shift; 1.0 → +maxShift (stricter); 0.0 → -maxShift (looser).
        let shift = (ignoreRate - 0.5) * 2 * maxShift
        return DetectionThresholds(
            surface: clamp(base.surface + shift),
            review: clamp(base.review + shift)
        )
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0.05), 0.99) }
}
