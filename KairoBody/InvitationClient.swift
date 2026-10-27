import Foundation
import Observation

struct BodyInvitation {
    let id: String
    let text: String
    let sourceEventID: Int
    let sourceSessionID: String
    let expiresAt: Date
}

/// Kairo-authored conversation invitations for this iPad. Display requires
/// local opt-in, visible/idle foreground, fresh paired proof and an actual
/// Kairo source; every outcome (delivered/answered/dismissed/expired/cancelled)
/// is reported so the server's cadence and quiet guards stay honest.
@MainActor
@Observable
final class InvitationClient {
    private(set) var invitation: BodyInvitation?
    private(set) var canRespond = false
    typealias Request = (String, String, [String: Any]?) async throws -> [String: Any]
    private let request: Request
    private let ownerProof: () -> String
    private var generation = UUID()
    private var refreshing = false
    private var expiryTask: Task<Void, Never>?
    private var displayed = Set<String>()

    init(http: KairoHTTP = KairoHTTP(), ownerProof: @escaping () -> String = { AppConfig.ownerProof },
         request: Request? = nil) {
        self.ownerProof = ownerProof
        self.request = request ?? { path, method, body in
            try await http.agentObject(path, method: method, body: body, timeout: 10)
        }
    }

    func refresh(foreground: Bool) async {
        guard foreground, PairingClient.validCredential(ownerProof()) else { stop(); return }
        guard !refreshing, invitation == nil else { return }
        let run = generation
        refreshing = true
        defer { if generation == run { refreshing = false } }
        do {
            let response = try await request("api/ipad/invitations", "GET", nil)
            guard let proposal = response["invitation"] as? [String: Any],
                  let id = proposal["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isNumber && $0.isASCII }),
                  let text = proposal["text"] as? String, !text.isEmpty, text.count <= 500,
                  proposal["origin"] as? String == "kairo",
                  let source = proposal["source_event_id"] as? Int, source > 0,
                  let session = proposal["session_id"] as? String, WireID.valid(session),
                  let timestamp = proposal["expires_at"] as? String, let expires = BodyJSON.date(timestamp) else { return }
            guard generation == run else { await outcome(id, "cancelled"); return }
            guard expires > Date() else { await outcome(id, "expired"); return }
            canRespond = false
            invitation = BodyInvitation(id: id, text: text, sourceEventID: source,
                                        sourceSessionID: session, expiresAt: expires)
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow))) } catch { return }
                guard let self, self.generation == run, self.invitation?.id == id else { return }
                self.invitation = nil; self.canRespond = false
                await self.outcome(id, "expired")
            }
        } catch { /* Absence of private proof or connectivity is not an invitation. */ }
    }

    func markDisplayed() async {
        guard let item = invitation, item.expiresAt > Date(), !displayed.contains(item.id) else { return }
        displayed.insert(item.id)
        let run = generation
        let accepted = await outcome(item.id, "delivered")
        guard generation == run, invitation?.id == item.id else { return }
        if accepted, item.expiresAt > Date() {
            canRespond = true
        } else {
            invitation = nil; canRespond = false
            expiryTask?.cancel(); expiryTask = nil
        }
    }

    func dismiss() async {
        guard let item = invitation else { return }
        invitation = nil; canRespond = false; expiryTask?.cancel(); expiryTask = nil
        await outcome(item.id, "dismissed")
    }

    /// Preserve the source session along with the accepted invitation.
    func accept() async -> BodyInvitation? {
        guard canRespond, let item = invitation, item.expiresAt > Date() else { stop(); return nil }
        let run = generation
        invitation = nil; canRespond = false; expiryTask?.cancel(); expiryTask = nil
        let accepted = await outcome(item.id, "answered")
        guard accepted, generation == run else { return nil }
        return item
    }

    func stop() {
        generation = UUID(); refreshing = false; expiryTask?.cancel(); expiryTask = nil
        let previous = invitation; invitation = nil; canRespond = false
        if let previous { Task { await outcome(previous.id, "cancelled") } }
    }

    @discardableResult
    private func outcome(_ id: String, _ status: String) async -> Bool {
        do {
            let response = try await request("api/ipad/invitations/\(id)/result", "POST", ["status": status])
            return response["accepted"] as? Bool == true
        } catch { return false }
    }
}
