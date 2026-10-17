import Foundation

enum ActionPhase: String, Codable {
    case accepted, started, completed, stopped, failed, expired
    var terminal: Bool { [.completed, .stopped, .failed, .expired].contains(self) }
}
struct BodyActionEvent: Codable {
    let commandID: String
    let sequence: Int
    let phase: ActionPhase
    let detail: String
}
struct BodyActionLifecycle {
    private var events: [String: BodyActionEvent] = [:]
    func lastEvent(commandID: String) -> BodyActionEvent? { events[commandID] }
    mutating func transition(commandID: String, phase: ActionPhase, detail: String) -> BodyActionEvent? {
        let old = events[commandID]
        if let old {
            guard !old.phase.terminal, old.phase != phase,
                  old.phase == .started ? phase.terminal : phase != .completed && phase != .accepted else { return nil }
        } else if phase != .accepted { return nil }
        let event = BodyActionEvent(commandID: commandID, sequence: (old?.sequence ?? 0) + 1,
            phase: phase, detail: String(detail.prefix(500)))
        events[commandID] = event
        return event
    }
}
