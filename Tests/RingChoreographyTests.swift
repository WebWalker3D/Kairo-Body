import XCTest
@testable import KairoBody

/// The ring's expressiveness contract: every composed phase must reach the
/// renderer as an animated verb, and every committed mood must reach it with
/// its own motion mode. The 2.0 rewrite shipped a ring that only breathed -
/// the Dot body was more expressive than the iPad - and these tests are the
/// reason that cannot quietly happen again.
final class RingChoreographyTests: XCTestCase {
    func testEveryPhaseBecomesAVerbTheRendererCanAnimate() {
        XCTAssertEqual(RingMirror.activity(for: .speaking), .speaking)
        XCTAssertEqual(RingMirror.activity(for: .thinking), .thinking)
        XCTAssertEqual(RingMirror.activity(for: .waiting), .listening)   // attentive posture
        XCTAssertEqual(RingMirror.activity(for: .listening), .listening)
        XCTAssertEqual(RingMirror.activity(for: .idle), .idle)
        XCTAssertEqual(RingMirror.activity(for: .reflecting), .idle)
        XCTAssertEqual(RingMirror.activity(for: .disconnected), .idle)
    }

    func testEveryMoodCarriesItsMotionMode() {
        XCTAssertEqual(ExpressionPalette.forState("calm").motionMode, .breathe)
        XCTAssertEqual(ExpressionPalette.forState("reflective").motionMode, .breathe)
        XCTAssertEqual(ExpressionPalette.forState("curious").motionMode, .orbit)
        XCTAssertEqual(ExpressionPalette.forState("focused").motionMode, .pulse)
        XCTAssertEqual(ExpressionPalette.forState("concerned").motionMode, .pulse)
        XCTAssertEqual(ExpressionPalette.forState("resolute").motionMode, .pulse)
        XCTAssertEqual(ExpressionPalette.forState("joyful").motionMode, .spark)
        XCTAssertEqual(ExpressionPalette.forState("playful").motionMode, .spark)
        XCTAssertEqual(ExpressionPalette.forState("unknown-mood").motionMode, .breathe)
    }

    func testShaderVocabularyMatchesTheRendererEnumCodes() {
        // KairoRing.metal decodes these exact numbers; changing a code
        // without editing the shader silently mislabels every motion.
        XCTAssertEqual(RingActivity.idle.rawValue, 0)
        XCTAssertEqual(RingActivity.listening.rawValue, 1)
        XCTAssertEqual(RingActivity.speaking.rawValue, 2)
        XCTAssertEqual(RingActivity.thinking.rawValue, 3)
        XCTAssertEqual(RingMotion.breathe.rawValue, 0)
        XCTAssertEqual(RingMotion.orbit.rawValue, 1)
        XCTAssertEqual(RingMotion.pulse.rawValue, 2)
        XCTAssertEqual(RingMotion.spark.rawValue, 3)
    }
}
