import XCTest
@testable import KairoBody

final class WakePhraseTests: XCTestCase {
    func testWakeVariantsArmAndExtractTheCommand() {
        var capture = WakePhraseCapture()
        capture.accept("Hey Kairo, what time is it?", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertEqual(capture.command, "what time is it?")

        capture.reset()
        capture.accept("Cairo pause the podcast", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertEqual(capture.command, "pause the podcast")

        capture.reset()
        capture.accept("Kairo.", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertEqual(capture.command, "") // awake, but no command yet

        capture.reset()
        capture.accept("kairo kairo kairo", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertEqual(capture.command, "kairo kairo")
    }

    func testIrrelevantTranscriptNeverArmsCapture() {
        var capture = WakePhraseCapture()
        capture.accept("turn on the lights", at: 0)
        capture.accept("cairophilius was a caryatid", at: 1)
        XCTAssertFalse(capture.isAwake)
        XCTAssertNil(capture.completedCommand(at: 30))
    }

    func testContinuationAppendsToAnAwakeCommand() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo remind me", at: 0)
        capture.acceptContinuation("to close the shop", prefix: capture.command, at: 2)
        XCTAssertEqual(capture.command, "remind me to close the shop")
    }

    func testCommandCompletesAfterSilenceAndNotBefore() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo status", at: 0)
        XCTAssertNil(capture.completedCommand(at: 3))       // under four seconds
        XCTAssertEqual(capture.completedCommand(at: 4.1), "status")
        XCTAssertFalse(capture.isAwake)

        // Voice activity extends the window; recognition drift alone does not.
        capture.accept("Kairo check the door", at: 10)
        capture.noteVoiceActivity(at: 13)
        XCTAssertNil(capture.completedCommand(at: 13.5))
        XCTAssertEqual(capture.completedCommand(at: 17.1), "check the door")

        // A bare wake word times out instead of hanging the appliance.
        capture.accept("Kairo", at: 20)
        XCTAssertNil(capture.completedCommand(at: 26))
        XCTAssertNil(capture.completedCommand(at: 27.1))   // seven seconds: armed window lapses
        XCTAssertFalse(capture.isAwake)
    }

    func testWakeCandidateIndexUsesTheLatestBoundary() {
        let words = ["can", "you", "hey", "kairo", "open", "it", "kairo", "close", "it"]
        let starts: [TimeInterval] = [0, 0.4, 5.0, 5.4, 5.8, 6.2, 11.0, 11.4, 11.8]
        let ends: [TimeInterval] = starts.map { $0 + 0.3 }
        XCTAssertEqual(WakePhraseCapture.wakeCandidateIndex(words: words, starts: starts, ends: ends), 6)
        let none = WakePhraseCapture.wakeCandidateIndex(words: ["hello", "there"],
            starts: [0, 0.5], ends: [0.3, 0.8])
        XCTAssertNil(none)
    }

    func testWakeWordIndexFindsNearestOccurrence() {
        let words = ["okay", "kairo", "and", "kairo", "again"]
        let starts: [TimeInterval] = [0, 1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(WakePhraseCapture.wakeWordIndex(words: words, starts: starts, near: 2.8), 3)
        XCTAssertEqual(WakePhraseCapture.wakeWordIndex(words: words, starts: starts), 1)
        XCTAssertNil(WakePhraseCapture.wakeWordIndex(words: words, starts: starts, from: 4))
    }

    func testCommandsAreBounded() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo " + String(repeating: "word ", count: 2_000), at: 0)
        XCTAssertTrue(capture.command.count <= 4_000)
    }

    func testSpeechActivityGateSeparatesSpeechFromSteadyNoise() {
        var gate = SpeechActivityGate()
        // Steady ambient noise trains the floor; it never triggers.
        for index in 0..<40 { gate.observe(level: 0.01, at: TimeInterval(index) * 0.1) }
        XCTAssertFalse(gate.observe(level: 0.011, at: 4.1))
        // A sustained jump past the floor is speech on the second sample.
        XCTAssertFalse(gate.observe(level: 0.09, at: 5.0))
        XCTAssertTrue(gate.observe(level: 0.08, at: 5.1))
        // A single spike followed by noise is not.
        XCTAssertFalse(gate.observe(level: 0.30, at: 7.0))
        XCTAssertFalse(gate.observe(level: 0.01, at: 7.1))
    }
}

final class DimmingContactTests: XCTestCase {
    func testKeepsAwakeOnlyForGenuineActivity() {
        // A heartbeat (nothing happening anywhere) must not hold the display.
        XCTAssertFalse(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "idle", dotActivityFresh: true, kairoBusy: false))
        XCTAssertFalse(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "listening", dotActivityFresh: true))
        // The Dot physically playing, replaying, thinking or hearing speech keeps it.
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "speaking", dotActivityFresh: true))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "speech_detected", dotActivityFresh: true))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "replaying", dotActivityFresh: true))
        // Stale phase metadata about a busy-looking Dot does not.
        XCTAssertFalse(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: "speaking", dotActivityFresh: false))
        // Kairo working on any surface keeps the body's display alive.
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: nil, dotActivityFresh: false, kairoBusy: true))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: true, localSpeaking: false,
            capturing: false, dotPhase: nil, dotActivityFresh: false))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: true,
            capturing: false, dotPhase: nil, dotActivityFresh: false))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: true, dotPhase: nil, dotActivityFresh: false))
    }

    func testStageProgressionAndMovementReset() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
        XCTAssertEqual(policy.observe(at: base, movement: true), .awake)
        XCTAssertEqual(policy.observe(at: base.addingTimeInterval(30), movement: false), .awake)
        XCTAssertEqual(policy.observe(at: base.addingTimeInterval(61), movement: false), .screensaver)
        XCTAssertEqual(policy.observe(at: base.addingTimeInterval(1_799), movement: false), .dark)
        XCTAssertEqual(policy.observe(at: base.addingTimeInterval(1_801), movement: true), .awake)
        XCTAssertEqual(policy.observe(at: base.addingTimeInterval(1_862), movement: false), .screensaver)
    }

    func testFrameAnalyzerIgnoresNoiseAndCatchesPresence() {
        var analyzer = FrameMotionAnalyzer()
        let still = [UInt8](repeating: 100, count: 144)
        XCTAssertFalse(analyzer.observe(still))   // no reference frame yet
        XCTAssertFalse(analyzer.observe(still))   // identical
        // A global 10-level brightness shift is under the 24-level per-pixel
        // threshold: exposure drift is not presence.
        XCTAssertFalse(analyzer.observe([UInt8](repeating: 110, count: 144)))
    }

    func testFrameAnalyzerThresholdMathematics() {
        var analyzer = FrameMotionAnalyzer()
        let base = [UInt8](repeating: 100, count: 144)
        XCTAssertFalse(analyzer.observe(base))
        var below = base
        for index in 0..<14 { below[index] = 250 }
        // 14 of 144 hard changes: just under 10 percent.
        XCTAssertFalse(analyzer.observe(below))
        var fifteen = base
        for index in 0..<15 { fifteen[index] = 250 }
        // Against the rolling reference (which already moved 14 pixels) only
        // one pixel differs now: still below threshold.
        XCTAssertFalse(analyzer.observe(fifteen))
        // From the same fresh base, 15 of 144 crosses 10 percent.
        var fresh = FrameMotionAnalyzer()
        XCTAssertFalse(fresh.observe(base))
        XCTAssertTrue(fresh.observe(fifteen))
    }

    func testContactIntentClassification() {
        XCTAssertEqual(ContactIntent.classify(durationMs: 120, pathLength: 0, cancelled: false), .tap)
        XCTAssertEqual(ContactIntent.classify(durationMs: 1_400, pathLength: 0.005, cancelled: false), .sustainedContact)
        XCTAssertEqual(ContactIntent.classify(durationMs: 200, pathLength: 0.02, cancelled: false), .drag)
        XCTAssertEqual(ContactIntent.classify(durationMs: 1_400, pathLength: 0.02, cancelled: true), .cancelled)
        XCTAssertTrue(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: false, conversationBusy: false))
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: false, cancelled: false, conversationBusy: false))
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: true, conversationBusy: false))
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: false, conversationBusy: true))
    }
}
