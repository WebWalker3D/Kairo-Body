import XCTest
@testable import KairoBody

/// The ring's expressiveness contract: every composed phase must reach the
/// renderer as an animated verb, and every committed mood must reach it with
/// its own motion mode. The 2.0 rewrite shipped a ring that only breathed -
/// the Dot body was more expressive than the iPad - and these tests are the
/// reason that cannot quietly happen again.
final class RingChoreographyTests: XCTestCase {
    func testGPUUniformsContainInlineEmitterValues() {
        // Metal reads seven float4 headers then twelve float4 emitters.
        // A Swift Array stores a reference, not its elements, in the struct.
        XCTAssertEqual(MemoryLayout<KairoRingUniformsStorage>.stride, 19 * 16)
        var uniforms = KairoRingUniformsStorage()
        var state = RingRenderState()
        state.emitterLevels = (0..<12).map { Float($0) / 12 }
        uniforms.apply(state, viewport: CGSize(width: 600, height: 600))
        withUnsafeBytes(of: uniforms) { bytes in
            guard bytes.count >= 19 * 16 else {
                XCTFail("GPU emitter data is missing from the uniform block")
                return
            }
            for index in 0..<12 {
                XCTAssertEqual(bytes.load(fromByteOffset: (7 + index) * 16, as: Float.self),
                               Float(index) / 12, accuracy: 0.0001)
            }
        }
    }

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
