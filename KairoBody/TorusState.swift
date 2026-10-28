import Foundation
import CoreFoundation

/// Numeric projection from the canonical affect reader, never a mood-label inference.
struct TorusSignal {
    let valence: Float
    let arousal: Float
    let valenceConfidence: Float
    let arousalConfidence: Float
    let observedAt: Date

    init?(object: [String: Any]?, now: Date = Date()) {
        guard let object, object["available"] as? Bool == true,
              object["source"] as? String == "canonical_affect",
              let revision = boundedInteger(object["source_revision"]), revision > 0,
              let observed = BodyJSON.date(object["observed_at"]),
              observed <= now.addingTimeInterval(5), now.timeIntervalSince(observed) < 30,
              let valence = Self.number(object["valence"], range: -1...1),
              let arousal = Self.number(object["arousal"], range: 0...1),
              let vc = Self.number(object["valence_confidence"], range: 0...1),
              let ac = Self.number(object["arousal_confidence"], range: 0...1) else { return nil }
        self.valence = valence; self.arousal = arousal
        valenceConfidence = vc; arousalConfidence = ac; observedAt = observed
    }

    func isFresh(at now: Date) -> Bool {
        observedAt <= now.addingTimeInterval(5) && now.timeIntervalSince(observedAt) < 30
    }

    private static func number(_ raw: Any?, range: ClosedRange<Double>) -> Float? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue) else { return nil }
        return Float(number.doubleValue)
    }
}

struct TorusAppearance: Equatable {
    var primary: SIMD3<Float>
    var accent: SIMD3<Float>
    var arousal: Float
    var energy: Float

    static let neutral = TorusAppearance(primary: SIMD3(0.372, 0.702, 1),
        accent: SIMD3(0.902, 0.973, 1), arousal: 0.3, energy: 0.5)

    static func resolve(signal: TorusSignal?, expression: String?, now: Date) -> Self {
        var result = neutral
        if let signal, signal.isFresh(at: now) {
            let valence = signal.valence * signal.valenceConfidence
            result.arousal += (signal.arousal - 0.3) * signal.arousalConfidence
            // Continuous restrained chromatic travel, not discrete mood buckets.
            let tint: SIMD3<Float> = valence >= 0 ? SIMD3(0.90, 0.70, 0.51) : SIMD3(0.57, 0.48, 0.87)
            result.primary += (tint - result.primary) * abs(valence) * 0.65
            result.accent += (tint - result.accent) * abs(valence) * 0.25
        }
        // Capacity remains uncalibrated in the canonical operational-energy
        // contract. Never substitute workload, arousal or battery as fatigue.
        if let expression {
            let colors = ExpressionPalette.forState(expression).rgb
            result.primary = colors.primary; result.accent = colors.accent
        }
        return result
    }
}

/// Ambient motion has its own integrated phase; changing speed never multiplies
/// a new rate by the app's uptime and jumps every particle to another position.
struct TorusDynamics {
    private(set) var current = TorusAppearance.neutral
    private(set) var flowPhase: Float = 0
    private(set) var breathPhase: Float = 0

    mutating func advance(toward target: TorusAppearance, seconds: Double, reducedMotion: Bool) {
        guard seconds.isFinite, seconds > 0 else { return }
        let dt = min(seconds, 1)
        let blend = Float(1 - exp(-dt / 3))
        current.primary += (target.primary - current.primary) * blend
        current.accent += (target.accent - current.accent) * blend
        current.arousal += (target.arousal - current.arousal) * blend
        current.energy += (target.energy - current.energy) * blend
        guard !reducedMotion else { return }
        flowPhase = (flowPhase + Float(dt) * (0.032 + current.arousal * 0.035))
            .truncatingRemainder(dividingBy: Float.pi * 2)
        breathPhase = (breathPhase + Float(dt) * (0.5 + current.arousal * 0.55))
            .truncatingRemainder(dividingBy: Float.pi * 2)
    }
}
