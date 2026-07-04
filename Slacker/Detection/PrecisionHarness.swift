import Foundation

/// Offline precision/agreement harness (§7.6). Run the rules pipeline against a set
/// of human-labeled messages to measure the real precision ceiling BEFORE trusting
/// detection. Rules-only (no LLM) so the result is deterministic and free.
struct PrecisionHarness {
    /// One labeled sample: the message text and whether ≥1 human marked it "needs attention".
    struct Sample: Equatable {
        let text: String
        let isAttention: Bool
        /// Optional per-annotator verdicts, for inter-rater agreement.
        let annotatorVerdicts: [Bool]

        init(text: String, isAttention: Bool, annotatorVerdicts: [Bool] = []) {
            self.text = text
            self.isAttention = isAttention
            self.annotatorVerdicts = annotatorVerdicts
        }
    }

    struct Metrics: Equatable {
        let total: Int
        let truePositives: Int
        let falsePositives: Int
        let falseNegatives: Int
        /// Of items the pipeline surfaced, the fraction humans agreed were attention-worthy.
        let precision: Double
        let recall: Double
        let falsePositiveRate: Double
        /// Mean pairwise agreement across annotators (the real precision ceiling), or nil.
        let interRaterAgreement: Double?
    }

    var classifier = Classifier()

    /// Build a harness whose rules include a candidate learned phrase bank (§7.5) — used
    /// to preview the precision impact of approving a proposal before it goes live.
    init(classifier: Classifier = Classifier()) {
        self.classifier = classifier
    }

    init(learned: LearnedPhraseBank) {
        var candidate = Classifier()
        candidate.ruleEngine = RuleEngine(learned: learned)
        self.classifier = candidate
    }

    /// A sample is "surfaced" by the pipeline if rules route it to the surfaced state.
    func surfaces(_ text: String) -> Bool {
        classifier.classifyThread(rootText: text, replies: [], rootUserID: nil, sensitivity: .normal)
            .state == .surfaced
    }

    func evaluate(_ samples: [Sample]) -> Metrics {
        var tp = 0, fp = 0, fn = 0
        for sample in samples {
            let surfaced = surfaces(sample.text)
            switch (surfaced, sample.isAttention) {
            case (true, true): tp += 1
            case (true, false): fp += 1
            case (false, true): fn += 1
            case (false, false): break
            }
        }
        let surfacedCount = tp + fp
        let attentionCount = tp + fn
        return Metrics(
            total: samples.count,
            truePositives: tp,
            falsePositives: fp,
            falseNegatives: fn,
            precision: surfacedCount == 0 ? 1 : Double(tp) / Double(surfacedCount),
            recall: attentionCount == 0 ? 1 : Double(tp) / Double(attentionCount),
            falsePositiveRate: surfacedCount == 0 ? 0 : Double(fp) / Double(surfacedCount),
            interRaterAgreement: Self.interRaterAgreement(samples)
        )
    }

    /// Mean pairwise percent agreement across annotators over all samples.
    static func interRaterAgreement(_ samples: [Sample]) -> Double? {
        let withVerdicts = samples.filter { $0.annotatorVerdicts.count >= 2 }
        guard !withVerdicts.isEmpty else { return nil }

        var agreementSum = 0.0
        for sample in withVerdicts {
            let v = sample.annotatorVerdicts
            var agree = 0, pairs = 0
            for i in 0..<v.count {
                for j in (i + 1)..<v.count {
                    pairs += 1
                    if v[i] == v[j] { agree += 1 }
                }
            }
            agreementSum += pairs == 0 ? 0 : Double(agree) / Double(pairs)
        }
        return agreementSum / Double(withVerdicts.count)
    }
}
