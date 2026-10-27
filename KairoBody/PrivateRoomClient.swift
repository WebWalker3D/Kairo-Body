import Foundation
import Observation

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
@Observable
final class PrivateRoomClient {
    private(set) var privateSessionID: String?
    private(set) var status = ""
    private(set) var error: String?
    private(set) var reply = ""
    private(set) var busy = false
    private(set) var memoryProposal: MemoryProposal?
    private(set) var decidingMemory = false
    typealias Request = (String, String, [String: Any]?, TimeInterval) async throws -> [String: Any]
    private let request: Request
    private let ownerProof: () -> String
    private let hasAgentToken: () -> Bool
    private var generation = UUID()
    private var sessionOwner: String?
    private var paused = false

    // Private request recovery is deliberately memory-only. A known job needs
    // only its handle; an unconfirmed POST retains its exact body/key until it
    // can be reconciled. None of this is written to UserDefaults or disk.
    private struct PendingRequest {
        let owner: String
        let sessionID: String
        var body: [String: Any]?
        var jobID: String?
    }
    private var pending: PendingRequest?
    var hasPendingTurn: Bool { pending != nil }

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

    var isPaired: Bool { PairingClient.validCredential(ownerProof()) }

    /// Hide all private presentation while inactive without losing a request
    /// that may still be executing. Foreground recovery never invents a new turn.
    func pause() {
        generation = UUID()
        paused = true
        clearVisibleState()
    }

    /// Forget the owner's complete local context, including recoverable work.
    func stop() {
        generation = UUID()
        paused = false
        clearVisibleState()
        pending = nil
        privateSessionID = nil
        sessionOwner = nil
    }

    private func clearVisibleState() {
        busy = false; decidingMemory = false
        reply = ""; status = ""; error = nil; memoryProposal = nil
    }

    private func isCurrent(_ run: UUID, owner: String) -> Bool {
        generation == run && !paused && ownerProof() == owner &&
            PairingClient.validCredential(owner) && hasAgentToken() && !Task.isCancelled
    }

    func openSession() async throws -> String {
        guard !paused, hasAgentToken(), isPaired else { throw PrivateBodyError.unpaired }
        let owner = ownerProof()
        let run = generation
        let opened = try await request("api/ipad/private/session", "POST", [:], 15)
        guard isCurrent(run, owner: owner) else { throw CancellationError() }
        guard let id = opened["id"] as? String, WireID.valid(id),
              id != EchoBinding.configuredSessionID,
              (opened["metadata_json"] as? [String: Any])?["client"] as? String == "ipad_private" else {
            throw PrivateBodyError.invalidResponse
        }
        privateSessionID = id
        sessionOwner = owner
        return id
    }

    func send(_ text: String) async {
        guard !busy, !paused else { return }
        guard hasAgentToken(), isPaired else { stop(); error = PrivateBodyError.unpaired.localizedDescription; return }
        let owner = ownerProof()
        if let sessionOwner, sessionOwner != owner { stop() }
        guard pending == nil else {
            error = "A private request is still pending. Check that request before sending another."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else {
            error = "Enter a private message of 1–4,000 characters."
            return
        }
        busy = true; error = nil
        let run = generation
        defer { if generation == run { busy = false } }
        do {
            let id: String
            if let current = privateSessionID { id = current } else { id = try await openSession() }
            guard isCurrent(run, owner: owner) else { return }
            pending = PendingRequest(owner: owner, sessionID: id, body: [
                "prompt": trimmed,
                "idempotency_key": "ipad-private:\(UUID().uuidString.lowercased())",
                "metadata": ["client": "ipad_private", "source": "ipad_private"]
            ])
            try await continuePending(run: run, owner: owner)
        } catch { handleFailure(error, run: run, owner: owner) }
    }

    func resumePending() async {
        paused = false
        guard !busy else { return }
        guard let item = pending else { return }
        guard hasAgentToken(), isPaired, item.owner == ownerProof(), sessionOwner == item.owner else {
            stop()
            return
        }
        let run = generation
        busy = true; error = nil
        defer { if generation == run { busy = false } }
        do { try await continuePending(run: run, owner: item.owner) }
        catch { handleFailure(error, run: run, owner: item.owner) }
    }

    private func continuePending(run: UUID, owner: String) async throws {
        guard var item = pending, isCurrent(run, owner: owner), item.owner == owner else { return }
        let jobID: String
        if let existing = item.jobID {
            jobID = existing
        } else {
            guard let body = item.body else { throw PrivateBodyError.invalidResponse }
            let job = try await request("api/sessions/\(item.sessionID)/jobs", "POST", body, 20)
            guard isCurrent(run, owner: owner) else { return }
            guard let id = job["id"] as? String, WireID.valid(id) else { throw PrivateBodyError.invalidResponse }
            jobID = id
            item.jobID = id
            item.body = nil // The private prompt is no longer needed for recovery.
            pending = item
        }
        for _ in 0..<600 {
            guard isCurrent(run, owner: owner) else { return }
            let current = try await request("api/jobs/\(jobID)?compact=1", "GET", nil, 15)
            guard isCurrent(run, owner: owner) else { return }
            if current["status"] as? String == "waiting_permission" {
                let proposals = try await request("api/jobs/\(jobID)/ipad-memory", "GET", nil, 15)
                guard isCurrent(run, owner: owner) else { return }
                memoryProposal = (proposals["proposals"] as? [[String: Any]])?.compactMap(MemoryProposal.init(json:)).first
                status = "Kairo is waiting for your private memory decision."
            } else {
                memoryProposal = nil
                status = "Kairo is considering your private request…"
            }
            if current["settled_status"] as? String == "completed", let answer = current["settled_text"] as? String {
                pending = nil; memoryProposal = nil
                reply = answer; status = "Private reply"; return
            }
            if let terminal = current["settled_status"] as? String {
                pending = nil; memoryProposal = nil
                throw PrivateBodyError.server(terminal)
            }
            try await Task.sleep(for: .seconds(2))
        }
        status = "Your private request is still pending. Check again while this app remains open."
    }

    private func handleFailure(_ failure: Error, run: UUID, owner: String) {
        guard generation == run else { return }
        if ownerProof() != owner || !isPaired || RequestFailure.kind(of: failure) == .authorizationLost {
            stop()
            error = failure.localizedDescription
            return
        }
        // Keep ambiguous submission/poll failures recoverable with the same key.
        // A definitive HTTP rejection of the POST did not create a job.
        if let http = failure as? HTTPStatusError, RequestFailure.kind(of: http) == .rejected,
           pending?.jobID == nil {
            pending = nil
        }
        if !(failure is CancellationError) { error = failure.localizedDescription }
        if pending != nil { status = "Your private request is unconfirmed or still pending. Check again; do not resend it." }
    }

    func decideMemory(_ decision: String) async {
        guard !paused, !decidingMemory, let item = pending, let jobID = item.jobID,
              let proposal = memoryProposal, proposal.expiresAt > Date(),
              decision == "keep" || decision == "dismiss" else { return }
        let run = generation
        guard isCurrent(run, owner: item.owner) else { stop(); return }
        decidingMemory = true
        defer { if generation == run { decidingMemory = false } }
        do {
            let result = try await request("api/jobs/\(jobID)/ipad-memory", "POST", [
                "approval_id": proposal.id, "proposal_hash": proposal.hash, "decision": decision
            ], 20)
            guard isCurrent(run, owner: item.owner) else { return }
            guard result["accepted"] as? Bool == true else { throw PrivateBodyError.invalidResponse }
            memoryProposal = nil
            status = decision == "keep"
                ? "Permission given. Kairo still chooses whether to adopt."
                : "Proposal dismissed."
        } catch { handleFailure(error, run: run, owner: item.owner) }
    }
}
