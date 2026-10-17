import XCTest
@testable import KairoBody

final class WakePhraseTests: XCTestCase {
    func testIgnoresSpeechWithoutWakePhrase() {
        var capture = WakePhraseCapture()
        capture.accept("What time is it?", at: 0)
        XCTAssertFalse(capture.isAwake)
        XCTAssertNil(capture.completedCommand(at: 5))
    }

    func testWaitsThroughNaturalPauseAndSubmitsOneCompleteCommand() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo, what time", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertNil(capture.completedCommand(at: 1.8))
        capture.accept("Kairo, what time is it?", at: 2.0)
        XCTAssertNil(capture.completedCommand(at: 3.8))
        XCTAssertNil(capture.completedCommand(at: 5.0))
        XCTAssertEqual(capture.completedCommand(at: 6.1), "what time is it?")
        XCTAssertNil(capture.completedCommand(at: 6))
    }

    func testRecognizerFinalResultDoesNotCutOffANaturalPause() {
        var capture = WakePhraseCapture()
        capture.accept("Hey Cairo, describe what you see", at: 0, isFinal: true)
        XCTAssertNil(capture.completedCommand(at: 0))
        XCTAssertEqual(capture.completedCommand(at: 4.1), "describe what you see")
    }

    func testContinuationAfterRecognizerFinalExtendsTheSameRequest() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo, what time", at: 0, isFinal: true)
        capture.acceptContinuation("is it now?", prefix: "what time", at: 1.5)
        XCTAssertNil(capture.completedCommand(at: 3.0))
        XCTAssertEqual(capture.completedCommand(at: 5.6), "what time is it now?")
    }

    func testWakePhraseAfterAmbientSpeechStillStartsARequest() {
        var capture = WakePhraseCapture()
        let start = WakePhraseCapture.wakeCandidateIndex(
            words: ["background", "conversation", "Kairo", "what"],
            starts: [0, 0.4, 2.0, 2.4], ends: [0.3, 0.8, 2.3, 2.8])
        XCTAssertEqual(start, 2)
        capture.accept("Kairo, what do you see?", at: 0)
        XCTAssertTrue(capture.isAwake)
        XCTAssertEqual(capture.completedCommand(at: 4.1), "what do you see?")
    }

    func testPauseAfterKairoKeepsWakeWordInFirstPartial() {
        let start = WakePhraseCapture.wakeCandidateIndex(
            words: ["background", "Kairo", "what", "time"],
            starts: [0, 2.0, 3.1, 3.4], ends: [0.4, 2.3, 3.3, 3.7])
        XCTAssertEqual(start, 1)
    }

    func testWakeWordTracksTimingWhenPartialSegmentationChanges() {
        XCTAssertEqual(WakePhraseCapture.wakeWordIndex(
            words: ["background", "Kairo", "what"],
            starts: [0, 2, 2.4], near: 2), 1)
        XCTAssertEqual(WakePhraseCapture.wakeWordIndex(
            words: ["background", "more", "Kairo", "what"],
            starts: [0, 0.5, 2.05, 2.4], near: 2), 2)
        XCTAssertNil(WakePhraseCapture.wakeWordIndex(
            words: ["background", "Cairo", "what"],
            starts: [0, 10, 10.4], near: 2))
    }

    func testIncidentalCairoMentionDoesNotWake() {
        var capture = WakePhraseCapture()
        capture.accept("I visited Cairo last year", at: 0)
        XCTAssertFalse(capture.isAwake)
        XCTAssertNil(capture.completedCommand(at: 10))
    }

    func testWakeWordAloneExpiresWithoutSending() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo", at: 0)
        XCTAssertNil(capture.completedCommand(at: 8))
        XCTAssertFalse(capture.isAwake)
    }

    func testBackgroundSpeechCannotExtendCommandForever() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo, tell me the time", at: 0)
        capture.accept("Kairo, tell me the time and background noise", at: 23.8)
        XCTAssertEqual(capture.completedCommand(at: 24.1),
                       "tell me the time and background noise")
    }

    func testVoiceActivityKeepsRequestOpenWhenTranscriptStalls() {
        var capture = WakePhraseCapture()
        capture.accept("Kairo, how do you feel", at: 0)
        capture.noteVoiceActivity(at: 3.8)
        XCTAssertNil(capture.completedCommand(at: 4.2))
        capture.accept("Kairo, how do you feel right now?", at: 4.6)
        XCTAssertEqual(capture.completedCommand(at: 8.7), "how do you feel right now?")
    }

    func testBackgroundNoiseDoesNotKeepRequestOpen() {
        var detector = SpeechActivityGate()
        var capture = WakePhraseCapture()
        capture.accept("Kairo, what time is it?", at: 0)
        for step in 1...60 {
            if detector.observe(level: 0.018, at: Double(step) * 0.1) {
                capture.noteVoiceActivity(at: Double(step) * 0.1)
            }
        }
        XCTAssertEqual(capture.completedCommand(at: 6.1), "what time is it?")
    }

    func testSpeechAboveEstablishedNoiseFloorKeepsRequestOpen() {
        var detector = SpeechActivityGate()
        for step in 1...20 {
            XCTAssertFalse(detector.observe(level: 0.018, at: Double(step) * 0.1))
        }
        var capture = WakePhraseCapture()
        capture.accept("Kairo, describe", at: 2.0)
        XCTAssertFalse(detector.observe(level: 0.075, at: 5.6))
        XCTAssertTrue(detector.observe(level: 0.075, at: 5.7))
        capture.noteVoiceActivity(at: 5.7)
        XCTAssertNil(capture.completedCommand(at: 6.1))
        XCTAssertEqual(capture.completedCommand(at: 9.8), "describe")
    }
}
