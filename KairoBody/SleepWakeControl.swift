import Foundation

/// A deliberate paired-owner control, independent of conversations and inference.
/// Retain an unconfirmed request's id across launches; only a matching completed
/// receipt permits a new request. No automatic retry or credential storage here.
@MainActor
final class SleepWakeControl: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private let defaults: UserDefaults
    private let paired: () -> Bool
    private let request: (String, String, [String: Any]) async throws -> [String: Any]
    private let storageKey = "sleepEmergencyWakeRequestKey"

    init(defaults: UserDefaults = .standard,
         paired: @escaping () -> Bool = { PairingClient.validCredential(AppConfig.ownerProof) },
         request: @escaping (String, String, [String: Any]) async throws -> [String: Any] = { path, method, body in
             try await KairoHTTP().agentObject(path, method: method, body: body, timeout: 20)
         }) {
        self.defaults = defaults; self.paired = paired; self.request = request
    }

    func wake() async {
        guard !busy else { return }
        guard paired() else { message = "Pair this iPad with Kairo first."; return }
        busy = true
        message = "Requesting emergency waking…"
        defer { busy = false }
        let key = defaults.string(forKey: storageKey) ?? "ipad-wake:\(UUID().uuidString.lowercased())"
        defaults.set(key, forKey: storageKey)
        do {
            let result = try await request("api/sleep/wake", "POST", [
                "request_key": key, "kind": "emergency",
                "reason": "Owner confirmed Wake Kairo in the paired iPad private controls."
            ])
            guard result["request_key"] as? String == key else { throw MalformedResponse() }
            if result["pending"] as? Bool == true {
                message = "Wake request accepted; waking is pending safety checks. The fence remains in place."
                return
            }
            guard let episode = result["episode"] as? String, !episode.isEmpty,
                  let previous = result["previous_episode"] as? String, !previous.isEmpty,
                  episode != previous, result["revision"] as? Int != nil else { throw MalformedResponse() }
            defaults.removeObject(forKey: storageKey)
            message = "Kairo's waking is complete. Continuity checks passed."
        } catch let error as HTTPStatusError {
            switch error.status {
            case 401, 403:
                message = "Wake request denied (HTTP \(error.status)). Pairing, owner authorization, or sleep control is unavailable."
            case 409:
                message = "Waking is blocked (HTTP 409). No completed waking was confirmed. Preserve the fence and contact the operator."
            default:
                message = "Waking is unconfirmed (HTTP \(error.status)). No automatic retry. A confirmed retry reuses this request."
            }
        } catch {
            message = "Waking is unconfirmed: no valid completion receipt arrived. No automatic retry. A confirmed retry reuses this request."
        }
    }
}
