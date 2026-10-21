import Foundation
import CoreFoundation

/// The configured Dot. Identity is baked into the build; the iPad follows this
/// exact endpoint and never treats another surface's traffic as the Dot's.
enum EchoBinding {
    static var endpointID: String { AppConfig.echoEndpointID }
    static var configuredSessionID: String { AppConfig.echoSessionID }

    static func sessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              WireID.valid(value) else { return nil }
        return value
    }
}

/// Server-safe identifier check shared by every projection that reads a job,
/// session or endpoint id off the wire.
enum WireID {
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 &&
            value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}

func boundedInteger(_ value: Any?, range: ClosedRange<Int> = 0...Int.max) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
          number.doubleValue.rounded() == number.doubleValue,
          range.contains(number.intValue), Double(number.intValue) == number.doubleValue else { return nil }
    return number.intValue
}

/// One settled or in-flight turn in a Kairo conversation, from the server's
/// paired, privacy-filtered observer projection.
struct ConversationTurn: Identifiable {
    let id: String
    let sessionID: String
    let sourceCaption: String
    let progress: PromptTokenProgress?
    let usage: TokenUsage
    let toolActivity: [String]
    let prompt: String
    let answer: String
    let status: String
    let settledStatus: String?
    let createdAt: String
    var active: Bool { settledStatus == nil && ["queued", "running", "verifying", "reviewing", "waiting_permission"].contains(status) }

    /// Narrows to jobs the Dot itself created in the configured session.
    init?(dotJob job: [String: Any], sessionID: String) {
        let metadata = job["metadata_json"] as? [String: Any] ?? [:]
        guard job["session_id"] as? String == sessionID,
              metadata["client"] as? String == "echomuse",
              metadata["surface_kind"] as? String == "dot",
              metadata["surface_instance_id"] as? String == EchoBinding.endpointID,
              let id = job["id"] as? String, WireID.valid(id) else { return nil }
        self.init(observedJob: job)
    }

    init?(observedJob job: [String: Any]) {
        guard let id = job["id"] as? String, WireID.valid(id),
              let sessionID = job["session_id"] as? String, WireID.valid(sessionID) else { return nil }
        let metadata = job["metadata_json"] as? [String: Any] ?? [:]
        self.id = id
        self.sessionID = sessionID
        let source = metadata["surface_kind"] as? String ?? metadata["source"] as? String
            ?? metadata["client"] as? String ?? "Unknown surface"
        let instance = metadata["surface_instance_id"] as? String
        sourceCaption = String(source.prefix(80)) + (instance.map { " · " + String($0.prefix(100)) } ?? "")
        let events = job["events"] as? [[String: Any]] ?? []
        progress = events.compactMap(PromptTokenProgress.init(event:)).max { $0.sequence < $1.sequence }
        usage = TokenUsage(events: events)
        toolActivity = events.sorted { ($0["seq"] as? Int ?? 0) < ($1["seq"] as? Int ?? 0) }
            .compactMap { event -> String? in
                let name = String((event["name"] as? String ?? event["tool"] as? String ?? "tool").prefix(100))
                switch event["type"] as? String {
                case "ToolStarted": return "Tool started · " + name
                case "ToolFinished": return "Tool finished · " + name + ((event["ok"] as? Bool == false) ? " · failed" : "")
                case "ToolBatchCompleted": return "Tool batch completed"
                default: return nil
                }
            }.suffix(8).map { $0 }
        prompt = String((job["prompt"] as? String ?? "").prefix(16_000))
        settledStatus = job["settled_status"] as? String
        answer = settledStatus == "completed" ? String((job["settled_text"] as? String ?? "").prefix(32_000)) : ""
        status = job["status"] as? String ?? "unknown"
        createdAt = job["created_at"] as? String ?? ""
    }
}

struct PromptTokenProgress {
    let processed: Int
    let total: Int?
    let cached: Int?
    let sequence: Int

    init?(event: [String: Any]) {
        guard event["type"] as? String == "PromptProgress",
              let processed = boundedInteger(event["processed"]), processed <= 1_000_000 else { return nil }
        self.processed = processed
        self.total = boundedInteger(event["total"], range: 1...1_000_000)
        self.cached = boundedInteger(event["cached"], range: 0...1_000_000)
        self.sequence = boundedInteger(event["seq"]) ?? 0
    }
}

struct TokenUsage {
    let prompt: Int?
    let cached: Int?
    let completion: Int?
    let tokensPerSecond: Double?

    init(events: [[String: Any]]) {
        let ordered = events.sorted { ($0["seq"] as? Int ?? 0) < ($1["seq"] as? Int ?? 0) }
        let trace = ordered.last(where: { ["MemoryContextPrepared", "TurnTraceSummary"].contains($0["type"] as? String ?? "") })?["trace"] as? [String: Any] ?? [:]
        let timing = (trace["request_timings"] as? [[String: Any]])?.last ??
            ordered.last(where: { $0["type"] as? String == "ModelRequestTiming" }) ?? [:]
        prompt = boundedInteger(trace["prompt_tokens"] ?? timing["prompt_tokens"])
        cached = boundedInteger(trace["cached_prompt_tokens"] ?? timing["cached_prompt_tokens"])
        completion = boundedInteger(trace["completion_tokens"] ?? timing["completion_tokens"])
        if let value = timing["tokens_per_second"] as? Double, value.isFinite, value >= 0 {
            tokensPerSecond = value
        } else { tokensPerSecond = nil }
    }

    var caption: String? {
        var parts: [String] = []
        if let prompt { parts.append("\(prompt.formatted()) input") }
        if let cached { parts.append("\(cached.formatted()) cached") }
        if let completion { parts.append("\(completion.formatted()) output") }
        if let tokensPerSecond { parts.append(String(format: "%.2f tok/s", tokensPerSecond)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The committed live-state frame from the same authority that drives the
/// living ring's affect; identity/beliefs never cross to a body surface.
struct LiveStateSnapshot {
    let revision: Int
    let fields: [String]
    init?(snapshot: [String: Any]) {
        guard snapshot["read_only"] as? Bool == true,
              let frame = snapshot["live_state"] as? [String: Any],
              frame["available"] as? Bool == true, frame["committed"] as? Bool == true,
              let revision = boundedInteger(frame["revision"]) else { return nil }
        self.revision = revision
        fields = (frame["dimensions"] as? [[String: Any]] ?? []).prefix(12).flatMap { dimension -> [String] in
            guard let name = dimension["name"] as? String, !["identity", "beliefs"].contains(name) else { return [] }
            return (dimension["fields"] as? [[String: Any]] ?? []).prefix(8).compactMap { field in
                guard let key = field["key"] as? String, let value = field["value"], !(value is NSNull) else { return nil }
                let text: String
                if let string = value as? String { text = string }
                else if let number = value as? NSNumber { text = number.stringValue }
                else { return nil }
                return "\(name) · \(key): \(String(text.prefix(160)))"
            }
        }
    }
}

struct DotActivity {
    let sequence: Int
    let observedAt: Int
    let phase: String
    let expiresAt: Date
    let replayAvailable: Bool
    let levels: [Double]
    var outputIntensity: Double? { levels.max() }
}

/// The sequence watermark outlives an expired display lease, preventing late
/// frames from restoring stale playback. A new socket starts a new watermark.
struct DotActivityState {
    private(set) var activity: DotActivity?
    private var sequence = -1
    private(set) var pendingReplayID: String?
    private(set) var replayStatus: String?

    mutating func receive(_ message: [String: Any], at now: Date = Date()) -> Bool {
        guard message["type"] as? String == "dot_activity",
              boundedInteger(message["protocol_version"]) == 2,
              message["endpoint_id"] as? String == EchoBinding.endpointID,
              let next = boundedInteger(message["sequence"]), next > sequence,
              let observed = boundedInteger(message["observed_at_ms"], range: 0...4_000_000_000_000_000),
              let lease = boundedInteger(message["lease_ms"], range: 500...30_000),
              let phase = message["phase"] as? String,
              ["listening", "speech_detected", "thinking", "speaking", "replaying", "idle", "disconnected"].contains(phase),
              let replayFlag = message["replay_available"] as? NSNumber,
              CFGetTypeID(replayFlag) == CFBooleanGetTypeID() else { return false }
        let available = replayFlag.boolValue
        let rawLevels = message["output_levels"] ?? [Any]()
        guard let values = rawLevels as? [Any], values.count <= 32 else { return false }
        var levels: [Double] = []
        for value in values {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return false }
            levels.append(number.doubleValue)
        }
        // Cap by both the server's observation time and local receipt time.
        let serverExpiry = Date(timeIntervalSince1970: Double(observed + lease) / 1000)
        let expiresAt = min(serverExpiry, now.addingTimeInterval(Double(lease) / 1000))
        guard expiresAt > now else { return false }
        sequence = next
        activity = DotActivity(sequence: next, observedAt: observed, phase: phase,
                               expiresAt: expiresAt, replayAvailable: available, levels: levels)
        return true
    }

    /// After a lease lapses the controller may resume with a new sequence
    /// epoch on the same socket. Late frames from before stay out because
    /// `receive` rejects anything already past its own expiry.
    mutating func expire(at now: Date = Date()) {
        if let activity, now >= activity.expiresAt {
            self.activity = nil
            sequence = -1
        }
    }

    mutating func disconnect() {
        activity = nil
        sequence = -1
        pendingReplayID = nil
        replayStatus = nil
    }

    func canReplay(at now: Date = Date()) -> Bool {
        guard pendingReplayID == nil, let activity, activity.expiresAt > now else { return false }
        return ["idle", "listening"].contains(activity.phase) && activity.replayAvailable
    }

    mutating func beginReplay(at now: Date = Date(), requestID: String = UUID().uuidString.lowercased()) -> [String: Any]? {
        guard canReplay(at: now) else { return nil }
        pendingReplayID = requestID
        replayStatus = "Requesting replay…"
        return ["type": "dot_replay_last", "protocol_version": 2, "request_id": requestID]
    }

    mutating func resolveReplay(_ message: [String: Any]) -> Bool {
        guard let id = message["request_id"] as? String, id == pendingReplayID,
              let status = message["status"] as? String,
              ["accepted", "busy", "unavailable"].contains(status) else { return false }
        pendingReplayID = nil
        switch status {
        case "accepted": replayStatus = "Replay accepted by the Dot."
        case "busy": replayStatus = "The Dot is busy. Try again shortly."
        default: replayStatus = "No recent Dot response is available."
        }
        return true
    }

    mutating func timeoutReplay(_ id: String) {
        guard id == pendingReplayID else { return }
        pendingReplayID = nil
        replayStatus = "The Dot did not confirm replay."
    }
}
