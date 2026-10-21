import Foundation

/// Reports permission and action readiness separately from actual observation
/// data. The server treats availability as authority for what it may command.
struct BodyCapabilities {
    var frontCameraEnabled: Bool
    var cameraPermission: String
    var microphoneEnabled: Bool
    var microphonePermission: String
    var speechEnabled: Bool
    var locationEnabled: Bool
    var locationPermission: String
    var locationObservedAt: String?
    var locationAccuracyM: Double?
    var accuracyAuthorization: String
    var appVersion: String
    var permissionRevision = 0
    var speechBusy = false
    var displayVisible = true

    func makeMessage(sequence: Int, bodyID: String, sessionID: String, foreground: Bool) -> [String: Any] {
        func status(_ enabled: Bool, _ permission: String) -> [String: Any] {
            let availability = !enabled || permission != "granted" ? "disabled" : foreground ? "ready" : "background"
            var reason: Any = NSNull()
            if availability == "disabled" { reason = "permission_off" }
            if availability == "background" { reason = "app_background" }
            return ["enabled": enabled, "permission": permission, "availability": availability, "reason": reason]
        }
        var rear = status(false, cameraPermission)
        rear["availability"] = "blocked"
        rear["reason"] = "blocked_by_body"
        var speech = status(speechEnabled, "granted")
        if foreground && speechEnabled && speechBusy {
            speech["availability"] = "busy"; speech["reason"] = "speech_busy"
        }
        var display = status(true, "granted")
        if foreground && !displayVisible {
            display["availability"] = "blocked"; display["reason"] = "display_hidden"
        }
        return ["type": "body_capabilities", "schema": "kairo.body_capabilities.v1",
            "protocolVersion": "kairo-body/1", "bodyID": bodyID, "sessionID": sessionID,
            "app_version": appVersion, "sequence": sequence, "permission_revision": permissionRevision,
            "foreground": foreground, "interfaces": [
                "front_camera": status(frontCameraEnabled, cameraPermission), "rear_camera": rear,
                "microphone": status(microphoneEnabled, microphonePermission),
                "speech": speech, "display": display,
                "location": status(locationEnabled, locationPermission)],
            "location": ["accuracy_authorization": accuracyAuthorization,
                "observed_at": locationObservedAt as Any? ?? NSNull(),
                "horizontal_accuracy_m": locationAccuracyM as Any? ?? NSNull()]]
    }
}

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
