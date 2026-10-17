import Foundation

/// A short-lived visual snapshot. Contains no conversation or appraisal text.
struct GlobalBodyPresentation {
    let proximity: BodyProximity?
    let phase: String
    let expression: String?
    let observedAt: Date
    let expiresAt: Date
    var processing: Bool { ["working", "queued", "background"].contains(phase) }

    func isFresh(at now: Date = Date()) -> Bool {
        observedAt <= now.addingTimeInterval(5) && expiresAt > now &&
            expiresAt > observedAt && expiresAt.timeIntervalSince(observedAt) <= 30
    }

    static func afterRefresh(_ incoming: GlobalBodyPresentation?, previous: GlobalBodyPresentation?,
                             now: Date = Date()) -> GlobalBodyPresentation? {
        if let incoming, incoming.isFresh(at: now) { return incoming }
        if let previous, previous.isFresh(at: now) { return previous }
        return nil
    }

    static func expressionState(snapshot: GlobalBodyPresentation?, paired: Bool,
                                fallback: String, now: Date = Date()) -> String {
        guard paired else { return fallback }
        // A failed read must not replace committed mood with a different renderer's state.
        guard let snapshot, snapshot.isFresh(at: now), let state = snapshot.expression else { return "awaiting state" }
        return state
    }

    init?(object: [String: Any], now: Date = Date()) {
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: text) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard object["schema_version"] as? Int == 1, object["read_only"] as? Bool == true,
              let observed = date(object["observed_at"]), let expires = date(object["expires_at"]),
              let activity = object["activity"] as? [String: Any], let phase = activity["phase"] as? String,
              ["working", "queued", "waiting", "background", "idle"].contains(phase) else { return nil }
        self.phase = phase; observedAt = observed; expiresAt = expires
        proximity = BodyProximity(object: object["body_proximity"] as? [String: Any], now: now)
        let affect = object["expression"] as? [String: Any]
        let presets = ["calm", "curious", "focused", "joyful", "concerned", "playful", "reflective", "resolute"]
        if affect?["available"] as? Bool == true, let state = affect?["state"] as? String,
           presets.contains(state), let revision = affect?["revision"] as? Int, revision > 0 {
            expression = state
        } else { expression = nil }
        guard isFresh(at: now) else { return nil }
    }
}

struct BodyProximity {
    let state: String
    let sourceEndpointID: String
    let observedAt: Date
    let expiresAt: Date

    func isFresh(at now: Date) -> Bool {
        observedAt <= now && expiresAt > now && expiresAt > observedAt &&
            expiresAt.timeIntervalSince(observedAt) <= 45
    }

    init?(object: [String: Any]?, now: Date) {
        guard let object, object["available"] as? Bool == true,
              let state = object["state"] as? String, ["near", "away"].contains(state),
              let source = object["source_endpoint_id"] as? String, !source.isEmpty,
              let receipt = object["observation_id"] as? String, !receipt.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        func parse(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard let observed = parse(object["observed_at"]), let expires = parse(object["expires_at"]) else { return nil }
        self.state = state; sourceEndpointID = source; observedAt = observed; expiresAt = expires
        guard isFresh(at: now) else { return nil }
    }
}

enum BodyActivityPolicy {
    static func resolve(capturing: Bool, speaking: Bool, sending: Bool, processing: Bool,
                        dotPhase: String?, dotFresh: Bool, connected: Bool) -> KairoBodyActivity {
        let dot = dotFresh ? dotPhase : nil
        if capturing { return .listening }
        if speaking || dot == "speaking" || dot == "replaying" { return .speaking }
        if sending || processing || dot == "thinking" { return .working }
        if dot == "listening" || dot == "speech_detected" { return .listening }
        return connected ? .idle : .disconnected
    }
}
