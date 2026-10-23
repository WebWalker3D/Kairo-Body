import Foundation

/// An Agent-authenticated observer of the existing ephemeral body relay. It
/// advertises no actuators; the sensory socket remains the only body endpoint.
/// This link is what lets the iPad see and answer the Dot's live state.
@MainActor
final class DotObserverClient: ObservableObject {
    @Published private(set) var state = DotActivityState()
    @Published private(set) var connected = false
    @Published private(set) var notice = "Dot link disconnected"

    private var socket: URLSessionWebSocketTask?
    private var followedToken: String?
    private var loop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var replayTimeout: Task<Void, Never>?
    private var generation = 0
    private var heartbeatSequence = 0
    private let instanceID = "ipad-dot-\(UUID().uuidString.lowercased())"
    /// Bounded like the sensory link: no silent URLSession retries, finite
    /// resource timeouts, and one session for the client's whole life.
    private let session = URLSession(configuration: TransportConfig.websocket())

    func follow(token: String, foreground: Bool) {
        // Re-following with the same token while already running is a no-op:
        // tearing the socket down would drop the Dot link for up to 30 s.
        if foreground, !token.isEmpty, loop != nil, token == followedToken { return }
        stop()
        guard foreground, !token.isEmpty else { return }
        followedToken = token
        let current = generation
        loop = Task { [weak self] in
            var backoff = 1
            while !Task.isCancelled {
                guard let self, current == self.generation else { return }
                guard let url = URL(string: AppConfig.dotObserverURL) else { return }
                let task = session.webSocketTask(with: url, protocols: ["novexai", token])
                self.socket = task
                task.resume()
                do {
                    try await self.send([
                        "type": "body_state", "protocol_version": 2, "sequence": 1,
                        "surface": ["kind": "native", "instance_id": self.instanceID, "foreground": true],
                        "state": ["actuators": ["canvas": false, "speech": false, "haptics": false],
                                  "channels": ["speech": "unavailable", "microphone": "unavailable", "camera": "off"],
                                  "viewport": ["visible": true],
                                  "client": ["platform": "Kairo Body Dot observer/iPadOS"]]
                    ], on: task)
                    self.startHeartbeat(on: task, generation: current)
                    while !Task.isCancelled, current == self.generation {
                        let message = try await task.receive()
                        guard current == self.generation, !Task.isCancelled else { return }
                        self.connected = true
                        backoff = 1
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard data.count <= 65_536,
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        self.receive(object)
                    }
                } catch {
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.notice = "Dot link reconnecting…"
                }
                task.cancel(with: .goingAway, reason: nil)
                self.socket = nil
                self.heartbeat?.cancel()
                self.expiry?.cancel()
                self.replayTimeout?.cancel()
                self.connected = false
                self.state.disconnect()
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    func stop() {
        followedToken = nil
        generation += 1
        loop?.cancel(); loop = nil
        heartbeat?.cancel(); heartbeat = nil
        expiry?.cancel(); expiry = nil
        replayTimeout?.cancel(); replayTimeout = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        state.disconnect()
        connected = false
        notice = "Dot link disconnected"
    }

    func requestReplay() {
        guard connected, let socket, let payload = state.beginReplay(),
              let id = payload["request_id"] as? String else { return }
        let current = generation
        Task { [weak self] in
            do { try await self?.send(payload, on: socket) }
            catch {
                guard let self, current == self.generation else { return }
                self.state.timeoutReplay(id)
            }
        }
        replayTimeout?.cancel()
        replayTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(18))
            guard let self, !Task.isCancelled, current == self.generation else { return }
            self.state.timeoutReplay(id)
        }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "dot_activity":
            guard state.receive(message) else { return }
            notice = "Echo Dot connected"
            expiry?.cancel()
            guard let activity = state.activity else { return }
            let current = generation
            expiry = Task { [weak self] in
                let delay = max(0, activity.expiresAt.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, current == self.generation else { return }
                // Keep the socket: a lapse means the Dot's feed from Kairo
                // paused, not that this link failed. Fresh activity resumes
                // here (a new controller epoch is accepted after expiry).
                self.state.expire()
                self.notice = "Waiting for fresh Dot activity"
            }
        case "dot_replay_result":
            guard (message["protocol_version"] as? Int) == 2, state.resolveReplay(message) else { return }
            replayTimeout?.cancel()
        default: break
        }
    }

    private func startHeartbeat(on task: URLSessionWebSocketTask, generation current: Int) {
        heartbeat?.cancel()
        heartbeatSequence = 0
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, current == self.generation else { return }
                self.heartbeatSequence += 1
                do {
                    try await self.send(["type": "body_heartbeat", "protocol_version": 2,
                                         "sequence": self.heartbeatSequence], on: task)
                } catch { task.cancel(with: .goingAway, reason: nil); return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func send(_ payload: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        // Bounded like the sensory link: a stalled write is a dead link, and
        // the heartbeat loop must stay free to notice.
        try await StalledOperation.call(10) { [task] in
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }
}
