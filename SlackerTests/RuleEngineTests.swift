import XCTest
@testable import Slacker

final class RuleEngineTests: XCTestCase {
    private let engine = RuleEngine()

    func testDirectedQuestionIsHighConfidenceOpenQuestion() {
        let v = engine.classify(text: "<@U123> can you review this PR?")
        XCTAssertEqual(v.messageClass, .openQuestion)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.8)
    }

    func testGroupAskIsOpenQuestion() {
        let v = engine.classify(text: "can someone take a look at the deploy?")
        XCTAssertEqual(v.messageClass, .openQuestion)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.8)
    }

    func testCoordinationAskPhrasesAreOpenQuestions() {
        XCTAssertEqual(
            engine.classify(text: "@Daanish Hindustani can you ping the oncall about the payments timeouts?").messageClass,
            .openQuestion
        )
        XCTAssertEqual(engine.classify(text: "please page the on-call and add the dashboard link").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "loop in payments on this incident").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "can we get eyes on this rollback?").messageClass, .openQuestion)
    }

    func testReviewApprovalAndShareAsksAreOpenQuestions() {
        XCTAssertEqual(engine.classify(text: "please review this migration plan").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "need someone to approve this before release").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "could I get the dashboard link?").messageClass, .openQuestion)
    }

    func testBareQuestionIsMediumConfidence() {
        let v = engine.classify(text: "is the build green?")
        XCTAssertEqual(v.messageClass, .openQuestion)
        XCTAssertLessThan(v.confidence, 0.8)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.5)
    }

    func testBlockerLanguageIsBlocker() {
        XCTAssertEqual(engine.classify(text: "I'm blocked on the API key").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "waiting on design before I can ship").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "held up by the security review").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "can't deploy until approvals are in").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "Hi current metroDR we have loaned for performance tests will go away as it's blocking release work.").messageClass, .blocker)
    }

    func testDecisionLanguageIsDecisionPending() {
        XCTAssertEqual(engine.classify(text: "should we go with option A or B").messageClass, .decisionPending)
        XCTAssertEqual(engine.classify(text: "wdyt about moving the date").messageClass, .decisionPending)
        XCTAssertEqual(engine.classify(text: "ship or hold for the payments fix?").messageClass, .decisionPending)
        XCTAssertEqual(engine.classify(text: "roll forward or rollback?").messageClass, .decisionPending)
    }

    func testPlainStatementIsContextOnly() {
        let v = engine.classify(text: "shipped the release notes, thanks everyone")
        XCTAssertEqual(v.messageClass, .contextOnly)
    }

    func testEmptyTextIsContextOnly() {
        XCTAssertEqual(engine.classify(text: "   ").messageClass, .contextOnly)
    }

    func testFencedLogsAreIgnoredForClassification() {
        XCTAssertEqual(
            engine.classify(text: "FYI from the deploy:\n```production is down\ncan someone help?\n```").messageClass,
            .contextOnly
        )
        XCTAssertEqual(
            engine.classify(text: "<@U123> can you check this?\n```production is down```").messageClass,
            .openQuestion
        )
        XCTAssertEqual(
            engine.classify(text: "FYI only\n```unterminated failed build can someone help?").messageClass,
            .contextOnly
        )
    }

    func testDirectedDeadlineWithoutQuestionIsOpenQuestion() {
        let v = engine.classify(text: "<@U9> please send the numbers by EOD")
        XCTAssertEqual(v.messageClass, .openQuestion)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.7)
    }

    func testBlockerTakesPrecedenceOverQuestion() {
        // Contains both blocker language and a question mark.
        let v = engine.classify(text: "blocked on review — can someone help?")
        XCTAssertEqual(v.messageClass, .blocker)
    }

    // MARK: - Implicit blockers / problem reports / help requests

    func testTryingToButFailingIsBlocker() {
        // The real-world example that was being missed.
        let v = engine.classify(
            text: "Im trying to run the pipeline but the build is failing: https://github.ibm.com/ProjectAbell/FOO/pull/1234"
        )
        XCTAssertEqual(v.messageClass, .blocker)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.8)
    }

    func testBuildFailingIsBlocker() {
        XCTAssertEqual(engine.classify(text: "the build is failing on main").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "tests are failing after the merge").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "deploy won't build").messageClass, .blocker)
    }

    func testIncidentAndTimeoutLanguageIsBlocker() {
        XCTAssertEqual(engine.classify(text: "payments timeouts are spiking again").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "checkout has elevated errors after deploy").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "alerts firing for API latency").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "production is down for EU users").messageClass, .blocker)
    }

    func testProductionImpactLanguageIsBlocker() {
        XCTAssertEqual(engine.classify(text: "the issue is affecting prod").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "looks like this config is leading to some prod issues").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "this is impacting production").messageClass, .blocker)
    }

    func testNotWorkingIsBlocker() {
        XCTAssertEqual(engine.classify(text: "the login flow is not working").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "having trouble with the migration").messageClass, .blocker)
    }

    func testFacingIssueWithPRIsBlocker() {
        XCTAssertEqual(engine.classify(text: "Facing issue with PR:").messageClass, .blocker)
        XCTAssertEqual(engine.classify(text: "facing issues with the deploy").messageClass, .blocker)
    }

    func testHelpRequestIsOpenQuestion() {
        XCTAssertEqual(engine.classify(text: "any idea why CI is red").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "how do I reset the staging db").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "need help with the deploy script").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "please help - maybe this test can be done before release").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "who owns the payments dashboard?").messageClass, .openQuestion)
        XCTAssertEqual(engine.classify(text: "anyone available to pair on this?").messageClass, .openQuestion)
    }

    func testNeutralStatementsStayContextOnly() {
        // Guard against over-matching: these must NOT become blockers.
        XCTAssertEqual(engine.classify(text: "the link is broken, here's the new one").messageClass, .contextOnly)
        XCTAssertEqual(engine.classify(text: "trying to keep the meeting short today").messageClass, .contextOnly)
    }

    // MARK: - Learned-phrase injection (§7.5, self-evolution)

    func testEmptyLearnedBankMatchesBaseBehavior() {
        // Regression guard: an engine with an empty learned bank must behave identically.
        let injected = RuleEngine(learned: .empty)
        let cases = [
            "<@U123> can you review this PR?",
            "I'm blocked on the API key",
            "should we go with option A or B",
            "shipped the release notes, thanks everyone",
        ]
        for text in cases {
            XCTAssertEqual(injected.classify(text: text), engine.classify(text: text))
        }
    }

    func testLearnedPhraseExtendsABucket() {
        // A company that says "red alert on" to mean a blocker — unknown to the base.
        XCTAssertEqual(engine.classify(text: "red alert on the payments queue").messageClass, .contextOnly)
        let bank = LearnedPhraseBank(phrasesByBucket: [.blocker: ["red alert on"]])
        let learned = RuleEngine(learned: bank)
        XCTAssertEqual(learned.classify(text: "red alert on the payments queue").messageClass, .blocker)
    }

    func testTwoEnginesDoNotInterfere() {
        // Proves no shared static mutation: distinct banks → distinct results.
        let a = RuleEngine(learned: LearnedPhraseBank(phrasesByBucket: [.help: ["spin up a"]]))
        let b = RuleEngine(learned: .empty)
        XCTAssertEqual(a.classify(text: "spin up a sandbox for me").messageClass, .openQuestion)
        XCTAssertEqual(b.classify(text: "spin up a sandbox for me").messageClass, .contextOnly)
    }

    func testInadmissibleLearnedPhrasesAreRejected() {
        // Single-token and too-short phrases must not broaden the rules (precision).
        XCTAssertFalse(RuleEngine.isAdmissibleLearnedPhrase("fix"))
        XCTAssertFalse(RuleEngine.isAdmissibleLearnedPhrase("ok"))
        XCTAssertFalse(RuleEngine.isAdmissibleLearnedPhrase("can you")) // already a base phrase
        XCTAssertTrue(RuleEngine.isAdmissibleLearnedPhrase("red alert on"))

        // A single-token learned phrase is dropped at injection.
        let bank = LearnedPhraseBank(phrasesByBucket: [.blocker: ["broken"]])
        XCTAssertEqual(RuleEngine(learned: bank).classify(text: "the build is broken").messageClass, .contextOnly)
    }
}
