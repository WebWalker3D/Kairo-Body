import Foundation

/// Uses a moving ambient level to distinguish speech bursts from steady room noise.
struct SpeechActivityGate {
    private var noiseFloor = 0.01
    private var candidateAt: TimeInterval?

    mutating func observe(level: Double, at: TimeInterval) -> Bool {
        guard level.isFinite, level >= 0 else { return false }
        let threshold = max(0.028, noiseFloor * 2.5)
        if level > threshold {
            let sustained = candidateAt.map { at - $0 <= 0.25 } ?? false
            candidateAt = at
            return sustained
        }
        candidateAt = nil
        noiseFloor = noiseFloor * 0.9 + min(level, noiseFloor * 1.25) * 0.1
        return false
    }
}
