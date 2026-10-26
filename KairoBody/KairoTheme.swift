import SwiftUI

/// Design tokens kept token-for-token with Android's design/Tokens.kt and the
/// shared Kairo visual identity. Elevation is luminosity and a lit edge, never
/// a stock iOS drop-shadow hierarchy.
enum KairoTheme {
    static let groundTop = Color(red: 7 / 255, green: 14 / 255, blue: 24 / 255)
    static let groundMid = Color(red: 6 / 255, green: 10 / 255, blue: 18 / 255)
    static let groundDeep = Color(red: 4 / 255, green: 7 / 255, blue: 13 / 255)
    static let plane = Color(red: 13 / 255, green: 20 / 255, blue: 31 / 255)
    static let prose = Color(red: 231 / 255, green: 236 / 255, blue: 245 / 255)
    static let dim = Color(red: 192 / 255, green: 201 / 255, blue: 216 / 255)
    static let chrome = Color(red: 154 / 255, green: 168 / 255, blue: 188 / 255)
    static let faint = Color(red: 113 / 255, green: 128 / 255, blue: 151 / 255)
    static let primary = Color(red: 95 / 255, green: 179 / 255, blue: 255 / 255)
    static let mind = Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)
    static let bond = Color(red: 244 / 255, green: 114 / 255, blue: 182 / 255)
    static let body = Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255)
    static let warn = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
    static let danger = Color(red: 251 / 255, green: 113 / 255, blue: 133 / 255)

    static var background: some View {
        LinearGradient(colors: [groundTop, groundMid, groundDeep],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    static func planeFill(_ shapeOpacity: Double = 1) -> some ShapeStyle {
        plane.opacity(shapeOpacity)
    }

    static let hairline = Color.white.opacity(0.07)

    /// Living-ring emitter colors measured from the physical Dot profile:
    /// the ring responds in cyan/teal for presence, violet for reflection,
    /// amber for warmth, rose for concern. The iPad mirrors that vocabulary.
    static let ringWake = Color(red: 77 / 255, green: 217 / 255, blue: 247 / 255)
    static let ringThinking = Color(red: 148 / 255, green: 163 / 255, blue: 255 / 255)
    static let ringSpeaking = Color(red: 95 / 255, green: 179 / 255, blue: 255 / 255)
    static let ringReflecting = Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)
    static let ringIdle = Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255)
}
