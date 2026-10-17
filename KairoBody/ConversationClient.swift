import Foundation
import UIKit
import CryptoKit

struct PromptTokenProgress {
    let processed: Int
    let total: Int?
    let cached: Int?
    let sequence: Int

    init?(event: [String: Any]) {
        guard event["type"] as? String == "PromptProgress",
              let processed = event["processed"] as? Int,
              processed >= 0, processed <= 1_000_000 else { return nil }
        self.processed = processed
        self.total = (event["total"] as? Int).flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        self.cached = (event["cached"] as? Int).flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        self.sequence = event["seq"] as? Int ?? 0
    }
}

/// A small client of Kairo's existing Agent Platform job API. This uses a
/// separate Agent Platform credential; the sensory bearer never submits jobs.
@MainActor
final class ConversationClient: ObservableObject {
    @Published private(set) var reply = ""
    @Published private(set) var error: String?
    @Published private(set) var status = ""
    @Published private(set) var isSending = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var promptProgress: PromptTokenProgress?
    @Published private(set) var lastJobID = ""
    /// A message whose reply has not been delivered yet and can be recovered.
    @Published private(set) var pendingRecovery: PendingRecovery?
    @Published var speakReplies = true
    @Published var outputDestination: String?
    var prepareOutput: ((String) async throws -> Void)?
    var deliverOutput: ((String, String) async -> Void)?
    var stopOutput: (() -> Void)?

    func applyDeliveredAnswer(_ text: String) { reply = text; status = "Kairo replied on the iPad" }

    enum PendingRecovery: Equatable {
        /// No response confirmed the message; resending it is safe (same key).
        case unconfirmed
        /// Kairo accepted the message but had not settled when waiting ended.
        case stillWorking(jobID: String)
    }

    private let settings: AppSettings
    private let speech: SpeechService
    private let session: URLSession
    private let agentToken: () -> String
    private let pendingStore: PendingTurnStore
    private lazy var tracker = JobTracker(request: { [weak self] path, method, body in
        guard let self else { throw CancellationError() }
        return try await self.perform(path, method: method, body: body)
    }, now: now, sleep: sleep)
    private let now: () -> Date
    private let sleep: (Double) async throws -> Void
    private var generation = 0
    private var stopRequested = false
    private var foreground = true

    init(settings: AppSettings, speech: SpeechService, session: URLSession = .shared,
         agentToken: (() -> String)? = nil, pendingStore: PendingTurnStore = PendingTurnStore(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (Double) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
         }) {
        self.settings = settings
        self.speech = speech
        self.session = session
        self.agentToken = agentToken ?? { settings.agentToken }
        self.pendingStore = pendingStore
        self.now = now
        self.sleep = sleep
        self.speech.onPlaybackStateChange = { [weak self] active in
            self?.isSpeaking = active
        }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value { stopOutput?(); speech.stop() }
        // A turn interrupted by suspension or relaunch continues where it was.
        if value { Task { await resumePendingIfNeeded() } }
    }

    func send(_ rawText: String, attachmentIDs: [String] = [], attachmentSessionID: String? = nil) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 4_000 else {
            error = "Keep messages under 4,000 characters."
            return
        }
        await submit(text: text, contactID: nil, endpointID: nil, attachmentIDs: attachmentIDs, attachmentSessionID: attachmentSessionID)
    }

    func sendTouchReflex(contactID: String, endpointID: String) async {
        guard Self.validID(contactID), Self.validID(endpointID) else { return }
        await submit(text: nil, contactID: contactID, endpointID: endpointID)
    }

    private func submit(text: String?, contactID: String?, endpointID: String?, attachmentIDs: [String] = [], attachmentSessionID: String? = nil) async {
        guard !isSending else { return }
        guard !agentToken().isEmpty else {
            error = "Add your separate Agent API token in Settings to talk with Kairo."
            return
        }
        let requestGeneration = generation
        let selectedOutput = outputDestination
        beginTurn()
        defer { if requestGeneration == generation { isSending = false } }
        do {
            let sessionID = try await conversationSessionID(generation: requestGeneration)
            guard requestGeneration == generation else { return }
            guard attachmentIDs.isEmpty || (attachmentSessionID == sessionID && attachmentIDs.count <= 1) else {
                throw ConversationError.jobFailed("The selected image belongs to a different conversation. Select it again here.")
            }
            if let contactID, let endpointID {
                status = "Kairo noticed contact…"
                let submitted = try await submitTouchReflex(sessionID: sessionID,
                    contactID: contactID, endpointID: endpointID,
                    generation: requestGeneration)
                guard requestGeneration == generation else { return }
                guard let jobID = submitted["id"] as? String, Self.validID(jobID) else {
                    throw ConversationError.invalidResponse
                }
                await follow(jobID: jobID, output: selectedOutput, since: now(), speak: true,
                             pending: nil, generation: requestGeneration)
            } else if let text {
                // A new message supersedes an older unrecovered one; its reply
                // still appears in the all-surfaces conversation.
                clearPending()
                if let selectedOutput {
                    try await prepareOutput?(selectedOutput)
                    guard requestGeneration == generation else { return }
                }
                // One key per logical message, persisted before the first attempt.
                let turn = PendingTurn.new(sessionID: sessionID, text: text, attachmentIDs: attachmentIDs,
                                           outputDestination: selectedOutput, at: now())
                pendingStore.save(turn)
                await deliver(turn, since: turn.submittedAt, speak: true, generation: requestGeneration)
            }
        } catch {
            fail(error, generation: requestGeneration)
        }
    }

    /// Re-check a reply that outlived the waiting deadline, or resend an
    /// unconfirmed message with its original key. Neither can duplicate it.
    func recoverPending() async {
        guard !isSending, let turn = pendingStore.load() else { return }
        let requestGeneration = generation
        beginTurn()
        pendingRecovery = nil
        defer { if requestGeneration == generation { isSending = false } }
        await deliver(turn, since: now(), speak: true, generation: requestGeneration)
    }

    /// Continue a turn after foreground return or relaunch without the user asking.
    func resumePendingIfNeeded() async {
        guard foreground, !isSending, !agentToken().isEmpty,
              let turn = pendingStore.load() else { return }
        let requestGeneration = generation
        beginTurn()
        pendingRecovery = nil
        defer { if requestGeneration == generation { isSending = false } }
        // A reply that arrives long after the user stopped waiting is shown, not spoken.
        let live = now().timeIntervalSince(turn.submittedAt) < JobTracker.deadline
        await deliver(turn, since: turn.submittedAt, speak: live, generation: requestGeneration)
    }

    private func beginTurn() {
        stopRequested = false
        isSending = true
        error = nil
        reply = ""
        promptProgress = nil
        lastJobID = ""
        status = "Sending to Kairo…"
    }

    private func deliver(_ initial: PendingTurn, since: Date, speak: Bool, generation requestGeneration: Int) async {
        var turn = initial
        do {
            if turn.jobID == nil {
                status = "Sending to Kairo…"
                let jobID = try await tracker.submit(turn)
                guard requestGeneration == generation else { return }
                turn.jobID = jobID
                pendingStore.save(turn)
            }
            guard let jobID = turn.jobID else { return }
            await follow(jobID: jobID, output: turn.outputDestination, since: since, speak: speak,
                         pending: turn, generation: requestGeneration)
        } catch is SubmissionUnconfirmed {
            guard requestGeneration == generation else { return }
            pendingRecovery = .unconfirmed
            error = "Kairo didn't confirm your message. It is kept; retry to send it once."
            status = ""
        } catch {
            fail(error, generation: requestGeneration)
        }
    }

    private func follow(jobID: String, output selectedOutput: String?, since: Date, speak: Bool,
                        pending: PendingTurn?, generation requestGeneration: Int) async {
        lastJobID = jobID
        do {
            if stopRequested {
                _ = try? await request("api/jobs/\(jobID)/cancel", method: "POST", body: [:])
                clearPending()
                status = "Stopped"
                return
            }
            let outcome = try await tracker.waitForSettlement(jobID: jobID, since: since) { [weak self] job in
                await self?.observePoll(job, jobID: jobID, generation: requestGeneration)
            }
            guard requestGeneration == generation else { return }
            if stopRequested { status = "Stopped"; return }
            switch outcome {
            case .settled(let job):
                if pending != nil { clearPending() }
                try await applySettlement(job, jobID: jobID, selectedOutput: selectedOutput, speak: speak)
            case .stillRunning:
                if pending != nil { pendingRecovery = .stillWorking(jobID: jobID) }
                status = "Kairo is still working on this. Check again for the reply."
            }
        } catch {
            fail(error, generation: requestGeneration)
        }
    }

    private func observePoll(_ job: [String: Any], jobID: String, generation requestGeneration: Int) async {
        guard requestGeneration == generation, !stopRequested else { return }
        if let events = try? await requestArray("api/jobs/\(jobID)/events?tail=32"),
           requestGeneration == generation,
           let latest = events.compactMap(PromptTokenProgress.init(event:)).max(by: {
               $0.sequence < $1.sequence
           }) {
            promptProgress = latest
        }
        guard requestGeneration == generation else { return }
        switch job["status"] as? String {
        case "queued": status = "Queued for Kairo"
        case "waiting_permission": status = "Kairo needs approval in the main interface"
        case "running": status = "Kairo is thinking…"
        default: status = "Kairo is responding…"
        }
    }

    private func applySettlement(_ job: [String: Any], jobID: String, selectedOutput: String?,
                                 speak: Bool) async throws {
        let settled = job["settled_status"] as? String
        if settled == "completed", let answer = job["settled_text"] as? String, !answer.isEmpty {
            status = "Kairo replied"
            let settledTarget = (job["metadata_json"] as? [String: Any])?["surface_output_target"] as? String
            let actualTarget = settledTarget ?? (selectedOutput == "kairo" ? "silent" : selectedOutput)
            if let actualTarget {
                // Only the claimed delivery may apply a selected answer locally.
                reply = ""
                if foreground { await deliverOutput?(jobID, actualTarget) }
            } else {
                reply = answer
                if speakReplies && foreground && speak {
                    speech.speak(answer, onFailure: { [weak self] reason in
                        self?.error = "Voice playback failed: \(reason)"
                    })
                }
            }
            return
        }
        throw ConversationError.jobFailed(
            (job["error"] as? String) ?? "Kairo's reply did not complete (\(settled ?? "unknown")).")
    }

    private func fail(_ error: Error, generation requestGeneration: Int) {
        guard requestGeneration == generation, !(error is CancellationError) else { return }
        // Outages keep the message for recovery; a definitive answer releases it.
        if RequestFailure.kind(of: error) == .transient, let turn = pendingStore.load() {
            pendingRecovery = turn.jobID.map { .stillWorking(jobID: $0) } ?? .unconfirmed
        } else {
            clearPending()
        }
        stopOutput?()
        self.error = error.localizedDescription
        status = ""
    }

    private func clearPending() {
        pendingStore.clear()
        pendingRecovery = nil
    }

    private func submitTouchReflex(sessionID: String, contactID: String,
                                   endpointID: String, generation: Int) async throws -> [String: Any] {
        for attempt in 0..<6 {
            guard generation == self.generation, !stopRequested else {
                throw ConversationError.jobFailed("Stopped")
            }
            do {
                return try await request("api/sessions/\(sessionID)/body-reflex",
                    method: "POST", body: ["endpoint_id": endpointID, "contact_id": contactID])
            } catch ConversationError.contactPending where attempt < 5 {
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw ConversationError.contactPending
    }

    func stopResponse() async {
        guard !stopRequested else { return }
        stopRequested = true
        stopOutput?()
        speech.stop()
        if Self.validID(lastJobID), isSending || pendingRecovery != nil {
            _ = try? await request("api/jobs/\(lastJobID)/cancel", method: "POST", body: [:])
        }
        clearPending()
        status = "Stopped"
    }

    func isKairoProcessing() async -> Bool? {
        guard !agentToken().isEmpty else { return nil }
        guard let platform = try? await request("api/platform") else { return nil }
        return (platform["active_jobs"] as? Int ??
                ((platform["queued_jobs"] as? Int ?? 0) +
                 (platform["running_jobs"] as? Int ?? 0))) > 0
    }

    func clearChat() {
        generation += 1
        stopRequested = false
        stopOutput?()
        speech.stop()
        settings.agentSessionID = ""
        clearPending()
        reply = ""
        error = nil
        status = ""
        isSending = false
        promptProgress = nil
        lastJobID = ""
    }

    private func conversationSessionID(generation requestGeneration: Int) async throws -> String {
        if settings.followEcho {
            guard let id = EchoBinding.sessionID(settings.echoSessionID) else {
                throw ConversationError.jobFailed("Set the shared Echo session ID in Settings before sending.")
            }
            let shared = try await request("api/sessions/\(id)")
            guard requestGeneration == generation else { throw CancellationError() }
            guard shared["id"] as? String == id, shared["status"] as? String == "active",
                  settings.agentWorkspaceID.isEmpty || shared["workspace_id"] as? String == settings.agentWorkspaceID else {
                throw ConversationError.jobFailed("The shared Echo conversation is unavailable in this workspace.")
            }
            return id
        }
        if Self.validID(settings.agentSessionID) { return settings.agentSessionID }
        let workspaces = try await requestArray("api/workspaces")
        guard requestGeneration == generation else { throw CancellationError() }
        let workspaceID: String
        if !settings.agentWorkspaceID.isEmpty {
            guard workspaces.contains(where: { ($0["id"] as? String) == settings.agentWorkspaceID }),
                  Self.validID(settings.agentWorkspaceID) else {
                throw ConversationError.jobFailed("Workspace ID was not found. Check Settings.")
            }
            workspaceID = settings.agentWorkspaceID
        } else if let preferred = Self.preferredWorkspaceID(workspaces) {
            workspaceID = preferred
        } else {
            throw ConversationError.jobFailed("Enter your Kairo workspace ID in Settings.")
        }
        let created = try await request("api/workspaces/\(workspaceID)/sessions", method: "POST",
            body: ["title": "Kairo Body", "metadata": ["client": "ipad_body", "privacy": "private"]])
        guard requestGeneration == generation else { throw CancellationError() }
        guard let sessionID = created["id"] as? String, Self.validID(sessionID) else {
            throw ConversationError.invalidResponse
        }
        settings.agentSessionID = sessionID
        return sessionID
    }

    func prepareVisualSession() async throws -> String {
        try await conversationSessionID(generation: generation)
    }

    func uploadVisual(_ image: UIImage, source: VisualSource, to context: SharedVisualContext,
                      sessionID: String, selection: UUID, observedAt: Date) async throws {
        let (jpeg, _, _) = try CameraCaptureService.prepare(image)
        let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        guard context.generation == selection, context.sessionID == sessionID else { throw CancellationError() }
        let serverSession = try await request("api/sessions/\(sessionID)")
        guard let workspace = serverSession["workspace_id"] as? String, Self.validID(workspace) else {
            throw ConversationError.invalidResponse
        }
        try Task.checkCancellation()
        guard context.generation == selection else { throw CancellationError() }
        let frame = try await request("api/workspaces/\(workspace)/observations", method: "POST", body: [
            "filename": "ipad-\(source.rawValue)-\(hash.prefix(12)).jpg", "content_type": "image/jpeg",
            "summary": "Explicitly shared iPad image (\(source.rawValue))", "session_id": sessionID,
            "data_base64": jpeg.base64EncodedString()])
        guard let observation = frame["id"] as? String, Self.validID(observation),
              frame["session_id"] as? String == sessionID else { throw ConversationError.invalidResponse }
        try Task.checkCancellation()
        guard context.generation == selection else { throw CancellationError() }
        let report = try await request("api/observations/\(observation)/vision", method: "POST",
            body: ["session_id": sessionID])
        guard report["frame_observation_id"] as? String == observation,
              let description = report["description_observation_id"] as? String, Self.validID(description) else {
            throw ConversationError.invalidResponse
        }
        try Task.checkCancellation()
        guard context.bind(attachmentID: description, sha256: hash, source: source,
            observedAt: observedAt, sessionID: sessionID, generation: selection) else { throw CancellationError() }
        context.previewJPEG = jpeg
    }

    private func requestArray(_ path: String) async throws -> [[String: Any]] {
        let value = try await perform(path, method: "GET", body: nil)
        guard let rows = value as? [[String: Any]] else { throw MalformedResponse() }
        return rows
    }

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        let value = try await perform(path, method: method, body: body)
        guard let object = value as? [String: Any] else { throw MalformedResponse() }
        return object
    }

    private func perform(_ path: String, method: String, body: [String: Any]?) async throws -> Any {
        guard let base = URL(string: settings.agentURL), base.scheme == "https",
              base.host == "connect.kairo.icu", base.user == nil,
              base.password == nil, base.path.isEmpty || base.path == "/" else {
            throw ConversationError.jobFailed("Use https://connect.kairo.icu as the Agent URL.")
        }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base
        for component in parts[0].split(separator: "/") { url.appendPathComponent(String(component)) }
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = parts[1]
            if let queryURL = components.url { url = queryURL }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(agentToken())", forHTTPHeaderField: "Authorization")
        let owner = PrivateBodyClient.ownerCredential()
        if !owner.isEmpty { request.setValue(owner, forHTTPHeaderField: "X-Kairo-Device") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = path.hasSuffix("/vision") ? 210 : 30
        if let body {
            // Sorted keys make a retried message byte-identical to its first attempt.
            request.httpBody = try PendingTurn.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        guard data.count <= 256_000 else { throw MalformedResponse() }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if http.statusCode == 409, detail?["code"] as? String == "contact_unavailable" {
                throw ConversationError.contactPending
            }
            throw HTTPStatusError(status: http.statusCode, code: detail?["code"] as? String)
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw MalformedResponse() }
        return value
    }

    nonisolated static func validID(_ value: String) -> Bool { JobTracker.validID(value) }

    static func preferredWorkspaceID(_ workspaces: [[String: Any]]) -> String? {
        let ipad = workspaces.filter {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare("Kairo iPad") == .orderedSame
        }
        let chosen = ipad.count == 1 ? ipad.first : (workspaces.count == 1 ? workspaces.first : nil)
        guard let id = chosen?["id"] as? String, validID(id) else { return nil }
        return id
    }
}

enum ConversationError: LocalizedError {
    case invalidResponse
    case contactPending
    case jobFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Kairo sent an invalid conversation response."
        case .contactPending: return "That touch did not reach Kairo in time. Try again."
        case .jobFailed(let reason): return reason
        }
    }
}

extension HTTPStatusError: LocalizedError {
    var errorDescription: String? {
        switch status {
        case 401: return "Agent API token was rejected. Check Settings."
        case 403: return "Kairo refused this request. Check the Agent token and owner pairing in Settings."
        case 503 where code == "owner_authorization_unavailable":
            return "Kairo could not verify this iPad right now. Retrying."
        default: return "Kairo returned HTTP \(status)."
        }
    }
}

extension MalformedResponse: LocalizedError {
    var errorDescription: String? { "Kairo sent an invalid conversation response." }
}
