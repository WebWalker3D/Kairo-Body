import Foundation

enum ContactIntent: String {
    case tap, sustainedContact, drag, cancelled
    static func classify(durationMs: Int, pathLength: Double, cancelled: Bool) -> ContactIntent {
        if cancelled { return .cancelled }
        if pathLength >= 0.01 { return .drag }
        return durationMs >= 1000 ? .sustainedContact : .tap
    }
    static func shouldSubmit(isBodySurface: Bool, cancelled: Bool, conversationBusy: Bool) -> Bool {
        isBodySurface && !cancelled && !conversationBusy
    }
}
