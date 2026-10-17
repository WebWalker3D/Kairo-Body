import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One logical typed or spoken message, kept until Kairo's reply settles.
/// Its idempotency key is created once; every retry resends the identical body,
/// so the server returns the original job instead of creating a second one.
struct PendingTurn: Codable, Equatable {
    let sessionID: String
    let text: String
    let idempotencyKey: String
    let attachmentIDs: [String]
    var outputDestination: String?
    let submittedAt: Date
    var jobID: String?

    static func new(sessionID: String, text: String, attachmentIDs: [String],
                    outputDestination: String?, at date: Date = Date()) -> PendingTurn {
        PendingTurn(sessionID: sessionID, text: text,
                    idempotencyKey: "ipad-body:\(UUID().uuidString.lowercased())",
                    attachmentIDs: attachmentIDs, outputDestination: outputDestination,
                    submittedAt: date, jobID: nil)
    }

    var submissionPath: String { "api/sessions/\(sessionID)/jobs" }

    /// Deterministic wire form of a request body.
    static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func requestBody() -> [String: Any] {
        var body: [String: Any] = ["prompt": text, "idempotency_key": idempotencyKey,
                                   "attachment_ids": attachmentIDs,
                                   "metadata": ["source": "ipad_body", "client": "ipad_body"]]
        if let outputDestination { body["output_destination"] = outputDestination }
        return body
    }
}

/// Survives app suspension and relaunch so a reply in progress is never lost.
struct PendingTurnStore {
    static let key = "pendingConversationTurn"
    var defaults: UserDefaults = .standard

    func load() -> PendingTurn? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard let turn = try? JSONDecoder().decode(PendingTurn.self, from: data) else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        return turn
    }

    func save(_ turn: PendingTurn) {
        if let data = try? JSONEncoder().encode(turn) { defaults.set(data, forKey: Self.key) }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Every submission attempt failed transiently and recovery by key found
/// nothing reachable. The server may or may not hold the job; resending
/// `turn` unchanged is safe either way.
struct SubmissionUnconfirmed: Error, Equatable {
    let turn: PendingTurn
}

enum JobWait {
    case settled([String: Any])
    /// The waiting deadline passed while the job had not settled (or Kairo
    /// could not be reached). The job ID is kept for a later check.
    case stillRunning([String: Any]?)
}

final class JobTracker {
    typealias Request = (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> Any

    static let submitAttempts = 4
    static let deadline: TimeInterval = 600
    static let pollInterval: Double = 2

    private let request: Request
    private let now: () -> Date
    private let sleep: (Double) async throws -> Void

    init(request: @escaping Request, now: @escaping () -> Date = Date.init,
         sleep: @escaping (Double) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
         }) {
        self.request = request
        self.now = now
        self.sleep = sleep
    }

    /// Returns the job ID for `turn`, retrying transient failures with the
    /// identical request and then recovering the job by its idempotency key.
    func submit(_ turn: PendingTurn) async throws -> String {
        let body = turn.requestBody()
        for attempt in 1...Self.submitAttempts {
            do {
                let created = try await request(turn.submissionPath, "POST", body)
                guard let object = created as? [String: Any], let id = object["id"] as? String,
                      Self.validID(id) else { throw MalformedResponse() }
                return id
            } catch {
                guard RequestFailure.kind(of: error) == .transient, !Task.isCancelled else { throw error }
                if attempt < Self.submitAttempts { try await sleep(Backoff.delay(afterFailures: attempt)) }
            }
        }
        do {
            let key = turn.idempotencyKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? turn.idempotencyKey
            let found = try await request("\(turn.submissionPath)?idempotency_key=\(key)", "GET", nil)
            if let rows = found as? [[String: Any]], let id = rows.first?["id"] as? String, Self.validID(id) {
                return id
            }
        } catch {
            guard RequestFailure.kind(of: error) == .transient else { throw error }
        }
        throw SubmissionUnconfirmed(turn: turn)
    }

    /// Polls until the job settles or `deadline` seconds have elapsed since
    /// `since`. Transient failures back off and keep waiting; at least one
    /// check is made even when resuming after the deadline.
    /// `onPoll` sees every job read, including the settling one, so callers
    /// can show final progress before applying the result.
    func waitForSettlement(jobID: String, since: Date,
                           onPoll: ([String: Any]) async -> Void) async throws -> JobWait {
        var failures = 0
        var last: [String: Any]?
        while true {
            try Task.checkCancellation()
            do {
                let value = try await request("api/jobs/\(jobID)?compact=1", "GET", nil)
                guard let job = value as? [String: Any] else { throw MalformedResponse() }
                failures = 0
                last = job
                await onPoll(job)
                if job["settled_status"] is String { return .settled(job) }
            } catch {
                guard RequestFailure.kind(of: error) == .transient, !Task.isCancelled else { throw error }
                failures += 1
            }
            let remaining = Self.deadline - now().timeIntervalSince(since)
            guard remaining > 0 else { return .stillRunning(last) }
            let pause = failures == 0 ? Self.pollInterval : Backoff.delay(afterFailures: failures)
            try await sleep(min(pause, remaining))
        }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 &&
            value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}
