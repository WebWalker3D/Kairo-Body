import Foundation

/// Mirrors the expression presets used by Kairo's Android/native bodies and
/// the living ring affect, so every body shows the same mood in the same
/// colours. Motion/energy drive the ring's breath and emitter floor.
struct ExpressionPalette {
    let name: String
    let motion: String
    let energy: Float
    let primaryHex: String
    let accentHex: String

    static func forState(_ state: String) -> Self {
        switch state.lowercased() {
        case "curious": return .init(name: "curious", motion: "orbit", energy: 0.68,
                                     primaryHex: "#a78bfa", accentHex: "#7dd3fc")
        case "focused": return .init(name: "focused", motion: "pulse", energy: 0.52,
                                     primaryHex: "#6ee7b7", accentHex: "#f8fafc")
        case "joyful": return .init(name: "joyful", motion: "spark", energy: 0.78,
                                    primaryHex: "#fbbf24", accentHex: "#f9a8d4")
        case "concerned": return .init(name: "concerned", motion: "pulse", energy: 0.58,
                                       primaryHex: "#fb7185", accentHex: "#fbbf24")
        case "playful": return .init(name: "playful", motion: "spark", energy: 0.72,
                                     primaryHex: "#f9a8d4", accentHex: "#fbbf24")
        case "reflective": return .init(name: "reflective", motion: "breathe", energy: 0.42,
                                        primaryHex: "#c4b5fd", accentHex: "#7dd3fc")
        case "resolute": return .init(name: "resolute", motion: "pulse", energy: 0.64,
                                      primaryHex: "#6ee7b7", accentHex: "#f8fafc")
        default: return .init(name: "calm", motion: "breathe", energy: 0.35,
                              primaryHex: "#5fb3ff", accentHex: "#e6f8ff")
        }
    }

    var rgb: (primary: SIMD3<Float>, accent: SIMD3<Float>) {
        (Self.rgb(primaryHex), Self.rgb(accentHex))
    }

    /// How this mood likes to move, in the renderer's vocabulary — the same
    /// pulse/orbit/spark/breathe modes the 1.0.x body and the Dot animate.
    var motionMode: RingMotion {
        switch motion.lowercased() {
        case "orbit": return .orbit
        case "pulse": return .pulse
        case "spark": return .spark
        default: return .breathe
        }
    }

    private static func rgb(_ hex: String) -> SIMD3<Float> {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return SIMD3<Float>(1, 1, 1) }
        return SIMD3<Float>(Float((value >> 16) & 0xff) / 255,
                            Float((value >> 8) & 0xff) / 255,
                            Float(value & 0xff) / 255)
    }
}
