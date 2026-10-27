import Foundation

struct MemoryProposal {
    let id: String
    let hash: String
    let text: String
    let expiresAt: Date
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, id.hasPrefix("ipa_"), id.count <= 80,
              let hash = json["proposal_hash"] as? String, hash.count == 64,
              hash.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
              let note = json["note"] as? [String: Any], let text = note["text"] as? String,
              !text.isEmpty, text.count <= 12000,
              let raw = json["expires_at"] as? String else { return nil }
        guard let expiry = BodyJSON.date(raw), expiry > Date() else { return nil }
        self.id = id; self.hash = hash; self.text = text; expiresAt = expiry
    }
}

enum PrivateBodyError: LocalizedError {
    case unpaired, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .unpaired: return "Pair this iPad with Kairo first."
        case .invalidResponse: return "Kairo sent an invalid private response."
        case .server(let reason): return reason
        }
    }
}

/// Owner-private conversation on a dedicated server-side session that the
/// shared transcript never reads. A memory proposal pauses the job until the
/// person answers Keep or Dismiss on this device; keeping grants permission
/// for that exact note, and Kairo separately decides whether to adopt it.
@MainActor
final class PrivateRoomClient: ObservableObject {
    @Published private(set) var privateSessionID: String?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var reply = ""
    @Published private(set) var busy = false
    @Published private(set) var memoryProposal: MemoryProposal?
    @Published private(set) var decidingMemory = false
    private var currentJobID: String?
    typealias Request = (String, String, [String: Any]?, TimeInterval) async throws -> [String: Any]
    private let request: Request
    private let ownerProof: () -> String
    private let hasAgentToken: () -> Bool
    private var generation = UUID()

    init(http: KairoHTTP = KairoHTTP(),
         ownerProof: @escaping () -> String = { AppConfig.ownerProof },
         hasAgentToken: @escaping () -> Bool = { !AppConfig.agentToken.isEmpty },
         request: Request? = nil) {
        self.ownerProof = ownerProof
        self.hasAgentToken = hasAgentToken
        self.request = request ?? { path, method, body, timeout in
            try await http.agentObject(path, method: method, body: body, timeout: timeout)
        }
    }

    func resumePending() async {}
    func pause() { stop() }

    var isPaired: Bool { PairingClient.validCredential(ownerProof()) }

    func stop() {
        generation = UUID(); busy = false
        reply = ""; memoryProposal = nil; currentJobID = nil; decidingMemory = false
    }

    func openSession() async throws -> String {
        guard hasAgentToken(), isPaired else { throw PrivateBodyError.unpaired }
        let run = generation
        let opened = try await request("api/ipad/private/session", "POST", [:], 15)
        guard generation == run, let id = opened["id"] as? String, !id.isEmpty,
              id != EchoBinding.configuredSessionID,
              (opened["metadata_json"] as? [String: Any])?["client"] as? String == "ipad_private" else {
            throw PrivateBodyError.invalidResponse
        }
        privateSessionID = id
        return id
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, trimmed.count <= 4_000 else { return }
        busy = true; error = nil
        let run = generation
        defer { if generation == run { busy = false } }
        do {
            let id: String
            if let current = privateSessionID { id = current } else { id = try await openSession() }
            guard generation == run else { return }
            let job = try await request("api/sessions/\(id)/jobs", "POST", ["prompt": trimmed,
                       "idempotency_key": "ipad-private:\(UUID().uuidString.lowercased())",
                       "metadata": ["client": "ipad_private", "source": "ipad_private"]], 20)
            guard let jobID = job["id"] as? String else { throw PrivateBodyError.invalidResponse }
            currentJobID = jobID
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard generation == run else { return }
                let current = try await request("api/jobs/\(jobID)?compact=1", "GET", nil, 15)
                if current["status"] as? String == "waiting_permission" {
                    let pending = try await request("api/jobs/\(jobID)/ipad-memory", "GET", nil, 15)
                    guard generation == run else { return }
                    memoryProposal = (pending["proposals"] as? [[String: Any]])?.compactMap(MemoryProposal.init(json:)).first
                }
                if current["settled_status"] as? String == "completed", let answer = current["settled_text"] as? String {
                    memoryProposal = nil; currentJobID = nil
                    reply = answer; status = "Private reply"; return
                }
                if let terminal = current["settled_status"] as? String { throw PrivateBodyError.server(terminal) }
                status = "Kairo is considering your private request…"
                try await Task.sleep(for: .seconds(2))
            }
            throw PrivateBodyError.server("Private reply is still pending")
        } catch { if generation == run { self.error = error.localizedDescription } }
    }

    func decideMemory(_ decision: String) async {
        guard !decidingMemory, let proposal = memoryProposal, let jobID = currentJobID,
              proposal.expiresAt > Date(), decision == "keep" || decision == "dismiss" else { return }
        let run = generation
        decidingMemory = true
        defer { if generation == run { decidingMemory = false } }
        do {
            let result = try await request("api/jobs/\(jobID)/ipad-memory", "POST", ["approval_id": proposal.id, "proposal_hash": proposal.hash, "decision": decision], 20)
            guard generation == run else { return }
            guard result["accepted"] as? Bool == true else { throw PrivateBodyError.invalidResponse }
            memoryProposal = nil
            status = decision == "keep"
                ? "Permission given. Kairo still chooses whether to adopt."
                : "Proposal dismissed."
        } catch { if generation == run { self.error = error.localizedDescription } }
    }
}
