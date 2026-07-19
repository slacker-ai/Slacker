import XCTest
@testable import Slacker

final class ClassifierTests: XCTestCase {
    private let classifier = Classifier()

    private func reply(_ user: String, ts: String, text: String = "a reply") -> Message {
        Message(channelID: "C1", ts: ts, threadTS: "100.0", userID: user,
                text: text, reactionsJSON: nil, ingestedAt: Date())
    }

    func testHighConfidenceQuestionIsSurfacedAsMissedFollowup() {
        let c = classifier.classifyThread(
            rootText: "<@U2> can you confirm the rollout time?",
            replies: [], rootUserID: "U1", sensitivity: .normal
        )
        XCTAssertEqual(c.type, .missedFollowup)
        XCTAssertEqual(c.state, .surfaced)
    }

    func testBlockerIsStale() {
        let c = classifier.classifyThread(
            rootText: "blocked on the staging env", replies: [], rootUserID: "U1", sensitivity: .normal
        )
        XCTAssertEqual(c.type, .stale)
        XCTAssertEqual(c.state, .surfaced)
    }

    func testBareQuestionRoutesToReviewNotSurfaced() {
        let c = classifier.classifyThread(
            rootText: "is staging up?", replies: [], rootUserID: "U1", sensitivity: .normal
        )
        XCTAssertEqual(c.state, .review, "ambiguous items go to the review queue, never surfaced")
    }

    func testContextOnlyProducesNoItem() {
        let c = classifier.classifyThread(
            rootText: "deploy finished, all green", replies: [], rootUserID: "U1", sensitivity: .normal
        )
        XCTAssertNil(c.type)
        XCTAssertNil(c.state)
    }

    func testReplyFromAnotherUserDiscountsConfidence() {
        // A strong question that would normally surface...
        let unanswered = classifier.classifyThread(
            rootText: "<@U2> can you confirm the rollout time?",
            replies: [], rootUserID: "U1", sensitivity: .normal
        )
        // ...is discounted once someone other than the asker replies.
        let answered = classifier.classifyThread(
            rootText: "<@U2> can you confirm the rollout time?",
            replies: [reply("U2", ts: "101.0")], rootUserID: "U1", sensitivity: .normal
        )
        XCTAssertEqual(unanswered.state, .surfaced)
        XCTAssertNotEqual(answered.state, .surfaced, "an answered thread should not stay surfaced")
        XCTAssertLessThan(answered.confidence, unanswered.confidence)
    }

    func testFollowUpReplyMakesThreadStale() {
        let c = classifier.classifyThread(
            rootText: "<@U2> can you confirm the rollout time?",
            replies: [reply("U1", ts: "101.0", text: "following up on this")],
            rootUserID: "U1",
            sensitivity: .normal
        )

        XCTAssertEqual(c.type, .stale)
        XCTAssertEqual(c.state, .surfaced)
    }

    func testDismissPhraseWinsOverFollowUpReply() {
        let classifier = Classifier(
            ruleEngine: RuleEngine(
                learned: LearnedPhraseBank(phrasesByBucket: [.dismiss: ["automated status report"]])
            )
        )
        let c = classifier.classifyThread(
            rootText: "Automated status report: production is down",
            replies: [reply("U1", ts: "101.0", text: "following up on this")],
            rootUserID: "U1",
            sensitivity: .normal
        )

        XCTAssertNil(c.type)
        XCTAssertNil(c.state)
        XCTAssertTrue(c.shouldDismiss)
    }

    func testFollowUpReplyIgnoresFencedLogs() {
        let c = classifier.classifyThread(
            rootText: "<@U2> can you confirm the rollout time?",
            replies: [reply("U1", ts: "101.0", text: "```\nfollowing up on this\n```")],
            rootUserID: "U1",
            sensitivity: .normal
        )

        XCTAssertEqual(c.type, .missedFollowup)
        XCTAssertEqual(c.state, .surfaced)
    }

    func testDirectFollowUpHandoffRemainsMissedFollowup() {
        let c = classifier.classifyThread(
            rootText: "can you follow up with support?",
            replies: [],
            rootUserID: "U1",
            sensitivity: .normal
        )

        XCTAssertEqual(c.type, .missedFollowup)
        XCTAssertEqual(c.state, .surfaced)
    }

    func testHighSensitivityLowersSurfaceBar() {
        // A group ask without a "?" is confidence ~0.75: review at normal sensitivity...
        let text = "can someone take a look at the deploy"
        let normal = classifier.classifyThread(
            rootText: text, replies: [], rootUserID: "U1", sensitivity: .normal
        )
        // ...and surfaces at high sensitivity (lower thresholds).
        let high = classifier.classifyThread(
            rootText: text, replies: [], rootUserID: "U1", sensitivity: .high
        )
        XCTAssertEqual(normal.state, .review)
        XCTAssertEqual(high.state, .surfaced)
    }
}
