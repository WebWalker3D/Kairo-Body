import Foundation
import Observation
import CoreFoundation

struct PendingApproval: Equatable {
    let observationID = UUID()
    let jobID: String
    let requestID: Int
    let description: String
    let scope: String
    let truncated: Bool
}

/// Explicit once-only owner decisions. The observer itself uses agent authentication.
@MainActor
@Observable
final class ApprovalClient {
    private(set) var approval: PendingApproval?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var status = ""
    private let ownerProof: () -> String
    private let now: () -> Date
    private let request: (String, String, [String: Any]?) async throws -> [String: Any]
    private var generation = UUID()
    private var boundOwner = ""
    private var followedJob: String?
    private var lastRefresh: Date?
    private var observedAt: Date?

    init(ownerProof: @escaping () -> String = { AppConfig.ownerProof },
         now: @escaping () -> Date = Date.init,
         request: @escaping (String, String, [String: Any]?) async throws -> [String: Any] = { path, method, body in
             try await KairoHTTP().agentObject(path, method: method, body: body, timeout: 12)
         }) {
        self.ownerProof = ownerProof; self.now = now; self.request = request
    }

    /// The foreground composition root calls this only for an active waiting job.
    func refresh(jobID: String) async {
        let owner = ownerProof()
        guard PairingClient.validCredential(owner), Self.validJobID(jobID) else {
            stop()
            return
        }
        if followedJob != jobID || boundOwner != owner {
            stop()
            followedJob = jobID
            boundOwner = owner
        }
        guard !busy else { return }
        if let lastRefresh {
            let elapsed = now().timeIntervalSince(lastRefresh)
            if elapsed >= 0 && elapsed < 8 { return }
        }
        let epoch = generation
        lastRefresh = now()
        busy = true
        defer { if generation == epoch { busy = false } }
        do {
            let result = try await request("api/observe?limit=30", "GET", nil)
            guard current(epoch, owner: owner) else { return }
            guard let rows = result["approvals"] as? [[String: Any]], rows.count <= 1_920 else {
                throw MalformedResponse()
            }
            let matches = rows.filter { $0["job_id"] as? String == jobID }
            guard matches.count <= 1 else { throw MalformedResponse() }
            var incoming: PendingApproval?
            if let row = matches.first {
                guard let number = row["request_id"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let requestID = row["request_id"] as? Int, requestID > 0,
                      number.doubleValue == Double(requestID),
                      let description = row["description"] as? String,
                      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      description.count <= 12_000,
                      let scope = row["scope"] as? String, !scope.isEmpty, scope.count <= 120,
                      let truncated = Self.boolean(row["truncated"]) else {
                    throw MalformedResponse()
                }
                // Keep an open review stable across identical observations, but never
                // reuse its identity after stop, changed authority or a decision.
                if let previous = approval, previous.jobID == jobID,
                   previous.requestID == requestID, previous.description == description,
                   previous.scope == scope, previous.truncated == truncated {
                    incoming = previous
                } else {
                    incoming = PendingApproval(jobID: jobID, requestID: requestID,
                                               description: description, scope: scope, truncated: truncated)
                }
            }
            approval = incoming
            observedAt = now()
            error = nil
            if incoming != nil {
                status = incoming?.truncated == true
                    ? "The request is incomplete. Review it with the operator; no decision can be sent here."
                    : "Kairo is waiting for your decision."
            } else {
                status = "No pending approval was found in this observation."
            }
        } catch {
            guard current(epoch, owner: owner) else { return }
            approval = nil
            observedAt = nil
            self.error = "Approval could not be refreshed. No decision was sent."
            status = ""
        }
    }

    /// Invalidates late network completions when backgrounded, unpaired or unfollowed.
    func stop() {
        generation = UUID()
        boundOwner = ""
        followedJob = nil
        lastRefresh = nil
        observedAt = nil
        approval = nil
        busy = false
        error = nil
        status = ""
    }

    func decide(_ item: PendingApproval, allow: Bool) async {
        let owner = ownerProof()
        guard PairingClient.validCredential(owner), owner == boundOwner else {
            stop()
            return
        }
        guard !busy, approval == item, followedJob == item.jobID else { return }
        guard !item.truncated else {
            error = "The full request is unavailable. No decision was sent."
            return
        }
        guard let observedAt, (0...30).contains(now().timeIntervalSince(observedAt)) else {
            approval = nil
            self.observedAt = nil
            lastRefresh = nil
            error = "This approval needs a fresh observation before you decide."
            return
        }
        let epoch = generation
        busy = true
        approval = nil
        self.observedAt = nil
        lastRefresh = nil
        error = nil
        status = "Sending your decision…"
        defer { if generation == epoch { busy = false } }
        do {
            let result = try await request("api/jobs/\(item.jobID)/permission", "POST", [
                "request_id": item.requestID, "decision": allow ? "y" : "n"
            ])
            guard current(epoch, owner: owner) else { return }
            guard Self.boolean(result["accepted"]) == true else { throw MalformedResponse() }
            status = "Your decision is queued. Kairo's action has not yet completed."
        } catch {
            guard current(epoch, owner: owner) else { return }
            if let response = error as? HTTPStatusError, response.status == 409 {
                self.error = "This request is no longer pending. Refresh before reviewing another decision."
            } else {
                self.error = "Your decision is unconfirmed. Refresh its current status before deciding again; no automatic retry."
            }
            status = ""
        }
    }

    private func current(_ epoch: UUID, owner: String) -> Bool {
        guard generation == epoch else { return false }
        guard ownerProof() == owner, boundOwner == owner, PairingClient.validCredential(owner) else {
            stop()
            return false
        }
        return true
    }

    private static func validJobID(_ value: String) -> Bool {
        value.hasPrefix("job_") && (5...200).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
