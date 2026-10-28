import XCTest
@testable import KairoBody

final class TorusStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func signal(valence: Any = 0.7, arousal: Any = 0.8,
                        confidence: Any = 1.0, age: Double = 0) -> TorusSignal? {
        TorusSignal(object: ["available": true, "source": "canonical_affect",
            "source_revision": 23,
            "observed_at": BodyJSON.iso8601.string(from: now.addingTimeInterval(-age)),
            "valence": valence, "valence_confidence": confidence,
            "arousal": arousal, "arousal_confidence": confidence,
            "energy": ["available": false, "reason": "uncalibrated"]], now: now)
    }

    func testNumericStateChangesMotionAndFallbackColorWithoutMoodBuckets() {
        let low = TorusAppearance.resolve(signal: signal(valence: -0.7, arousal: 0.1), expression: nil, now: now)
        let high = TorusAppearance.resolve(signal: signal(), expression: nil, now: now)
        XCTAssertGreaterThan(high.arousal, low.arousal)
        XCTAssertNotEqual(low.primary, high.primary)
        XCTAssertEqual(low.energy, 0.5, "Uncalibrated capacity is neutral, not inferred fatigue")
        let close = TorusAppearance.resolve(signal: signal(valence: 0.69), expression: nil, now: now)
        XCTAssertNotEqual(close.primary, high.primary)
        XCTAssertLessThan(abs(close.primary.x - high.primary.x), 0.02)
    }

    func testExplicitKairoColorsWinWhileRealArousalStillMoves() {
        let colors = ExpressionPalette.forState("reflective").rgb
        let low = TorusAppearance.resolve(signal: signal(arousal: 0.1), expression: "reflective", now: now)
        let high = TorusAppearance.resolve(signal: signal(), expression: "reflective", now: now)
        XCTAssertEqual(high.primary, colors.primary)
        XCTAssertEqual(high.accent, colors.accent)
        XCTAssertNotEqual(low.arousal, high.arousal)
    }

    func testStaleMissingAndZeroConfidenceReturnNeutralWithoutErasingChosenColors() {
        let neutral = TorusAppearance.resolve(signal: nil, expression: nil, now: now)
        XCTAssertEqual(TorusAppearance.resolve(signal: signal(confidence: 0), expression: nil, now: now), neutral)
        XCTAssertNil(signal(age: 31))
        XCTAssertNil(signal(age: -6))
        XCTAssertEqual(TorusAppearance.resolve(signal: signal(), expression: nil,
            now: now.addingTimeInterval(31)), neutral)
        XCTAssertEqual(TorusAppearance.resolve(signal: nil, expression: "joyful", now: now).primary,
                       ExpressionPalette.forState("joyful").rgb.primary)
    }

    func testInvalidNumbersCannotDriveTheShader() {
        for invalid in [true, "0.8", Double.nan, Double.infinity, 2.0] as [Any] {
            XCTAssertNil(signal(arousal: invalid))
            XCTAssertNil(signal(confidence: invalid))
        }
    }

    func testAmbientInterpolationIsFrameRateIndependentAndPhaseContinuous() {
        let target = TorusAppearance.resolve(signal: signal(), expression: nil, now: now)
        var thirty = TorusDynamics()
        var sixty = TorusDynamics()
        for _ in 0..<30 { thirty.advance(toward: target, seconds: 1.0 / 30, reducedMotion: false) }
        for _ in 0..<60 { sixty.advance(toward: target, seconds: 1.0 / 60, reducedMotion: false) }
        XCTAssertEqual(thirty.current.arousal, sixty.current.arousal, accuracy: 0.0001)
        XCTAssertEqual(thirty.current.primary.x, sixty.current.primary.x, accuracy: 0.0001)
        let phase = thirty.flowPhase
        thirty.advance(toward: .neutral, seconds: 0, reducedMotion: false)
        XCTAssertEqual(thirty.flowPhase, phase)
        thirty.advance(toward: .neutral, seconds: 1, reducedMotion: true)
        XCTAssertEqual(thirty.flowPhase, phase, "Reduce Motion freezes integrated motion")
        XCTAssertGreaterThan(thirty.current.arousal, 0.3)
        XCTAssertLessThan(thirty.current.arousal, target.arousal)
    }
}
