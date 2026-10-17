import SwiftUI

// Mirrors the expression presets used by Kairo's Android/native body.
struct BodyExpressionPalette {
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

    var primary: Color { Self.color(primaryHex) }
    var accent: Color { Self.color(accentHex) }
    var form: KairoBodyExpression {
        KairoBodyExpression(expression: name, motion: motion, energy: energy,
                            primaryColor: primaryHex, accentColor: accentHex)
    }

    private static func color(_ hex: String) -> Color {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return .white }
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}

struct KairoBodyExpression {
    var expression = "calm"
    var motion = "breathe"
    var energy: Float = 0.35
    var primaryColor = "#5fb3ff"
    var accentColor = "#e6f8ff"
}

struct KairoBodyProfile {
    let selected = false
    let width: Float = 0.70
    let height: Float = 1.02
    let tilt: Float = 0
    let openness: Float = 0.42
    let asymmetry: Float = 0
    let posture = "centered"
    let coreColor = "#ffffff"
    let motionScale: Float = 1
}
