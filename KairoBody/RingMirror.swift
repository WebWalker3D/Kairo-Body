import Foundation

/// The iPad's own living ring. It composes exactly the signals Kairo's Dot
/// ring runs on — the Dot's transient activity stream (phase, output levels,
/// lease), the paired-owner presentation (activity phase, committed affect,
/// background reflection) and this body's local acts — into one renderable
/// state. It never invents affect: absent signals fall back to idle.
struct RingMirrorState: Equatable {
    enum Phase: String {
        case idle, listening, thinking, speaking, waiting, reflecting, disconnected
    }
    enum Posture: String { case idle, focused, reflecting, sleeping }

    var phase: Phase = .idle
    var mood: String = "calm"
    var levels: [Double] = []
    var intensity: Double = 0
    var posture: Posture = .idle
    var dotFresh = false
    var presentationFresh = false
    var observedAt = Date()
}

enum RingMirror {
    static let emitterCount = 12

    /// The composed phase becomes a verb the ring animates: what Kairo is
    /// doing right now. Waiting-on-owner is an attentive posture, so it moves
    /// like listening; reflection and disconnection stay calm.
    static func activity(for phase: RingMirrorState.Phase) -> RingActivity {
        switch phase {
        case .speaking: return .speaking
        case .thinking: return .thinking
        case .listening, .waiting: return .listening
        case .idle, .reflecting, .disconnected: return .idle
        }
    }

    /// 32-level Dot waveforms render onto the physical ring's twelve measured
    /// emitters; the resample is deterministic so both bodies show the same
    /// light.
    static func resample(_ levels: [Double], to emitters: Int) -> [Double] {
        guard emitters > 0 else { return [] }
        guard levels.count > emitters else {
            if levels.isEmpty { return Array(repeating: 0, count: emitters) }
            // Fewer levels than emitters: hold the ends, stretch the middle.
            return (0..<emitters).map { index in
                let source = Double(index) * Double(max(levels.count - 1, 1)) / Double(max(emitters - 1, 1))
                let lower = min(Int(floor(source)), levels.count - 1)
                let upper = min(lower + 1, levels.count - 1)
                let fraction = source - Double(lower)
                return levels[lower] * (1 - fraction) + levels[upper] * fraction
            }
        }
        return (0..<emitters).map { index in
            let start = index * levels.count / emitters
            let end = max(start + 1, (index + 1) * levels.count / emitters)
            let slice = levels[start..<end]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// The Dot's transient phase wins over the coarse presentation phase while
    /// its lease is fresh; presentation covers background reflection and
    /// waiting-on-owner; local acts cover this body only.
    static func compose(dot: DotActivityState, presentation: GlobalBodyPresentation?,
                        local: LocalActs, now: Date = Date()) -> RingMirrorState {
        var state = RingMirrorState()
        state.observedAt = now
        let dotActivity = dot.activity
        state.dotFresh = dotActivity.map { $0.expiresAt > now } ?? false
        state.presentationFresh = presentation?.isFresh(at: now) ?? false

        if let dotActivity, dotActivity.expiresAt > now {
            state.levels = dotActivity.levels
            state.intensity = dotActivity.outputIntensity ?? 0
            switch dotActivity.phase {
            case "listening": state.phase = .listening
            case "speech_detected": state.phase = .listening
            case "thinking": state.phase = .thinking
            case "speaking": state.phase = .speaking
            case "replaying": state.phase = .speaking
            case "disconnected": state.phase = .disconnected
            default: state.phase = .idle
            }
        }

        if let presentation, presentation.isFresh(at: now) {
            state.mood = presentation.expression ?? state.mood
            switch presentation.phase {
            case "background":
                if state.phase == .idle { state.phase = .reflecting }
            case "waiting":
                if state.phase == .idle { state.phase = .waiting }
            case "working", "queued":
                if state.phase == .idle { state.phase = .thinking }
            default: break
            }
        }

        // Local acts only matter when nothing farther is already visible.
        switch state.phase {
        case .idle:
            if local.speaking { state.phase = .speaking }
            else if local.capturing { state.phase = .listening }
            else if local.sending { state.phase = .thinking }
        default: break
        }

        if let presentation, presentation.isFresh(at: now), presentation.phase == "background" {
            state.posture = .reflecting
        } else if state.phase == .thinking || state.phase == .waiting || state.phase == .speaking {
            state.posture = .focused
        } else {
            state.posture = .idle
        }
        return state
    }
}

struct LocalActs: Equatable {
    var speaking = false
    var capturing = false
    var sending = false
}
