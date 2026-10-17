import XCTest
@testable import KairoBody

final class MotionDimmingTests: XCTestCase {
    func testPassiveDotListeningDoesNotResetIdleDeadline() {
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
        let start = Date(timeIntervalSince1970: 1_000)
        for second in 0...61 {
            let busy = MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
                capturing: false, dotPhase: "listening", dotActivityFresh: true)
            let stage = policy.observe(at: start.addingTimeInterval(Double(second)), movement: busy)
            if second == 61 { XCTAssertEqual(stage, .screensaver) }
        }
    }

    func testOnlyActualFreshDotResponseOrLocalInteractionKeepsAwake() {
        for phase in ["speech_detected", "thinking", "speaking", "replaying"] {
            XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
                capturing: false, dotPhase: phase, dotActivityFresh: true))
            XCTAssertFalse(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
                capturing: false, dotPhase: phase, dotActivityFresh: false))
        }
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: true, localSpeaking: false,
            capturing: false, dotPhase: nil, dotActivityFresh: false))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: true,
            capturing: false, dotPhase: nil, dotActivityFresh: false))
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: true, dotPhase: nil, dotActivityFresh: false))
    }

    func testKairoWorkingOnAnySurfaceKeepsTheDisplayAwake() {
        // The server's presentation says Kairo is working (or queued, or
        // waiting on the owner) after the iPad's own request has returned.
        XCTAssertTrue(MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
            capturing: false, dotPhase: nil, dotActivityFresh: false, kairoBusy: true))
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
        let start = Date(timeIntervalSince1970: 1_000)
        for second in 0...120 {
            let busy = MotionDimmingPolicy.keepsAwake(localSending: false, localSpeaking: false,
                capturing: false, dotPhase: nil, dotActivityFresh: false, kairoBusy: true)
            XCTAssertEqual(policy.observe(at: start.addingTimeInterval(Double(second)), movement: busy), .awake)
        }
    }

    func testMotionShowsSaverThenDimsAfterThirtyMinutesAndWakes() {
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.observe(at: start, movement: false), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(59), movement: false), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(61), movement: false), .screensaver)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_799), movement: false), .screensaver)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_800), movement: false), .dark)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_801), movement: true), .awake)
    }

    func testHourChoiceExtendsDarkDeadline() {
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 3_600)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(policy.observe(at: start, movement: false), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_800), movement: false), .screensaver)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(3_600), movement: false), .dark)
    }

    func testResponseActivityPreventsSaverAndRestartsIdleTimerAfterReply() {
        var policy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(policy.observe(at: start, movement: false), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_790), movement: true), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_900), movement: true), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_959), movement: false), .awake)
        XCTAssertEqual(policy.observe(at: start.addingTimeInterval(1_961), movement: false), .screensaver)
    }

    func testSceneChangeRequiresSubstantialPixelDifference() {
        var detector = FrameMotionAnalyzer()
        let dark = [UInt8](repeating: 50, count: 100)
        XCTAssertFalse(detector.observe(dark))
        XCTAssertFalse(detector.observe([UInt8](repeating: 58, count: 100)))
        var changed = dark
        for index in 0..<15 { changed[index] = 180 }
        XCTAssertTrue(detector.observe(changed))
    }
}
