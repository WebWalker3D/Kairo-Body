import Foundation
import UIKit
import CryptoKit

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
        case 401: return "Kairo rejected this copy's Agent credential."
        case 403: return "Kairo refused this request. Check the owner pairing."
        case 503 where code == "owner_authorization_unavailable":
            return "Kairo could not verify this iPad right now. Retrying."
        default: return "Kairo returned HTTP \(status)."
        }
    }
}

extension MalformedResponse: LocalizedError {
    var errorDescription: String? { "Kairo sent an invalid conversation response." }
}

/// A client of Kairo's existing Agent Platform job API on the iPad's shared
/// conversation surface. When Echo following is on — the default — that
/// surface is the Dot's own session: a message typed or spoken here appears in
/// the same conversation Kairo is holding with the Dot, and the answer comes
/// back into this transcript.
@MainActor
final class ConversationClient: ObservableObject {
    enum OutputDestination: String, CaseIterable, Identifiable {
        case automatic = "Kairo decides"
        case silent = "Silent"
        case textOnly = "Text here"
        case speak = "Speak here"
        var id: String { rawValue }
        var surfaceTarget: String {
            switch self {
            case .automatic: return "kairo"
            case .silent: return "silent"
            case .textOnly: return "ipad_display"
            case .speak: return "ipad_speech"
            }
        }
    }

    enum PendingRecovery: Equatable {
        case unconfirmed
        case stillWorking(jobID: String)
    }

    @Published private(set) var reply = ""
    @Published private(set) var error: String?
    @Published private(set) var status = ""
    @Published private(set) var isSending = false
    @Published private(set) var promptProgress: PromptTokenProgress?
    @Published private(set) var pendingRecovery: PendingRecovery?
    @Published var draft = ""
    @Published var outputDestination: OutputDestination = .automatic

    /// The composition root wires these to the surface-delivery client so a
    /// settled answer routed to this iPad is claimed and applied atomically.
    var prepareOutput: ((String) async throws -> Void)?
    var deliverOutput: ((String, String) async -> Void)?
    var stopOutput: (() -> Void)?

    private let settings: AppSettings
    private let speech: SpeechService
    private let http: KairoHTTP
    private let tracker: JobTracker
    private let pendingStore = PendingTurnStore()
    private var generation = 0
    private var stopRequested = false
    private var lastJobID = ""
    private var responseTask: Task<Void, Never>?

    init(settings: AppSettings, speech: SpeechService, http: KairoHTTP = KairoHTTP()) {
        self.settings = settings
        self.speech = speech
        self.http = http
        self.tracker = JobTracker(request: { path, method, body in
            try await http.agent(path, method: method, body: body)
        })
    }

    var hasPendingTurn: Bool { pendingStore.load() != nil }

    func recoverPendingTurn() async {
        guard let turn = pendingStore.load() else { return }
        isSending = true
        let current = generation
        responseTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.generation { self.isSending = false } }
            do {
                let jobID: String
                if let existing = turn.jobID { jobID = existing }
                else { jobID = try await self.tracker.submit(turn) }
                var stored = turn; stored.jobID = jobID
                self.pendingStore.save(stored)
                guard current == self.generation else { return }
                self.lastJobID = jobID
                try await self.settle(stored, jobID: jobID, generation: current)
            } catch {
                self.handleFailure(error, generation: current)
            }
        }
    }

    func send(_ text: String, attachmentIDs: [String] = [],
              attachmentSessionID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !trimmed.isEmpty, trimmed.count <= 16_000 else { return }
        isSending = true
        error = nil
        reply = ""
        status = ""
        promptProgress = nil
        stopRequested = false
        let current = generation
        responseTask?.cancel()
        let destination = outputDestination.surfaceTarget
        responseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID: String
                if let attachmentSessionID { sessionID = attachmentSessionID }
                else { sessionID = try await self.conversationSessionID(generation: current) }
                guard current == self.generation else { throw CancellationError() }
                if destination != "silent" {
                    try await self.prepareOutput?(destination)
                    guard current == self.generation else { throw CancellationError() }
                }
                let turn = PendingTurn.new(sessionID: sessionID, text: trimmed,
                                           attachmentIDs: attachmentIDs, outputDestination: destination)
                self.pendingStore.save(turn)
                let jobID = try await self.tracker.submit(turn)
                var stored = turn; stored.jobID = jobID
                self.pendingStore.save(stored)
                guard current == self.generation else { throw CancellationError() }
                self.lastJobID = jobID
                self.status = "Kairo is responding…"
                try await self.settle(stored, jobID: jobID, generation: current)
            } catch {
                self.handleFailure(error, generation: current)
            }
            if current == self.generation { self.isSending = false }
        }
        await responseTask?.value
    }

    private func settle(_ turn: PendingTurn, jobID: String, generation current: Int) async throws {
        let wait = try await tracker.waitForSettlement(jobID: jobID, since: turn.submittedAt) { job in
            guard current == self.generation else { return }
            if let events = try? await self.http.agentArray("api/jobs/\(jobID)/events?tail=32"),
               let progress = events.compactMap(PromptTokenProgress.init(event:)).max(by: { $0.sequence < $1.sequence }) {
                self.promptProgress = progress
            }
        }
        guard current == generation else { throw CancellationError() }
        switch wait {
        case .settled(let job):
            clearPending()
            let settled = job["settled_status"] as? String ?? ""
            guard settled == "completed", let answer = job["settled_text"] as? String else {
                throw ConversationError.jobFailed("Kairo's response ended as \(settled).")
            }
            reply = answer
            status = ""
            if let target = SurfaceOutputPolicy.target(job: job, requested: turn.outputDestination) {
                await deliverOutput?(jobID, target)
            } else {
                await deliverOutput?(jobID, "silent")
            }
        case .stillRunning(let job):
            // Keep the message recoverable: the job may settle later on any
            // surface and the transcript shows it either way.
            if let job, job["settled_status"] is String {
                clearPending()
            } else {
                pendingRecovery = .stillWorking(jobID: jobID)
            }
            status = "Kairo is still working. The answer will appear in the conversation."
        }
    }

    private func handleFailure(_ error: Error, generation requestGeneration: Int) {
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

    /// A completed body contact is claimed through memory so Kairo can
    /// acknowledge the touch itself; the claim can answer 409 until the touch
    /// observation is ingested.
    func submitTouchReflex(sessionID: String, contactID: String,
                           endpointID: String, generation: Int) async throws -> [String: Any] {
        for attempt in 0..<6 {
            guard generation == self.generation, !stopRequested else {
                throw ConversationError.jobFailed("Stopped")
            }
            do {
                return try await http.agentObject("api/sessions/\(sessionID)/body-reflex",
                    method: "POST", body: ["endpoint_id": endpointID, "contact_id": contactID])
            } catch let status as HTTPStatusError where status.status == 409 && status.code == "contact_unavailable" && attempt < 5 {
                try await Task.sleep(for: .milliseconds(350))
            } catch let status as HTTPStatusError where status.status == 409 {
                throw ConversationError.contactPending
            }
        }
        throw ConversationError.contactPending
    }

    func stopResponse() async {
        guard !stopRequested else { return }
        stopRequested = true
        responseTask?.cancel()
        stopOutput?()
        speech.stop()
        if WireID.valid(lastJobID), isSending || pendingRecovery != nil {
            _ = try? await http.agent("api/jobs/\(lastJobID)/cancel", method: "POST", body: [:])
        }
        clearPending()
        isSending = false
        status = "Stopped"
    }

    func isKairoProcessing() async -> Bool? {
        guard !AppConfig.agentToken.isEmpty else { return nil }
        guard let platform = try? await http.agentObject("api/platform") else { return nil }
        return (platform["active_jobs"] as? Int ??
                ((platform["queued_jobs"] as? Int ?? 0) +
                 (platform["running_jobs"] as? Int ?? 0))) > 0
    }

    var currentGeneration: Int { generation }
    func showError(_ error: Error) { self.error = error.localizedDescription }
    func clearError() { error = nil }
    func clearRecoveredTurn() { clearPending() }

    func clearChat() {
        generation += 1
        stopRequested = false
        stopOutput?()
        speech.stop()
        settings.sharedSessionID = ""
        clearPending()
        reply = ""
        error = nil
        status = ""
        isSending = false
        promptProgress = nil
        lastJobID = ""
    }

    private func conversationSessionID(generation requestGeneration: Int) async throws -> String {
        if settings.followEcho, let id = EchoBinding.sessionID(EchoBinding.configuredSessionID) {
            let shared = try await http.agentObject("api/sessions/\(id)")
            guard requestGeneration == generation else { throw CancellationError() }
            guard shared["id"] as? String == id, shared["status"] as? String == "active" else {
                throw ConversationError.jobFailed("The shared conversation is unavailable right now.")
            }
            return id
        }
        // Following Echo without a configured session (fresh install, or the
        // owner has not linked one yet) falls back to this iPad's own
        // conversation rather than dead-ending the composer.
        if WireID.valid(settings.sharedSessionID) { return settings.sharedSessionID }
        let workspaces = try await http.agentArray("api/workspaces")
        guard requestGeneration == generation else { throw CancellationError() }
        guard let workspaceID = Self.preferredWorkspaceID(workspaces) else {
            throw ConversationError.jobFailed("No Kairo workspace is available for this credential.")
        }
        let created = try await http.agentObject("api/workspaces/\(workspaceID)/sessions", method: "POST",
            body: ["title": "Kairo Body", "metadata": ["client": "ipad_body", "privacy": "private"]])
        guard requestGeneration == generation else { throw CancellationError() }
        guard let sessionID = created["id"] as? String, WireID.valid(sessionID) else {
            throw ConversationError.invalidResponse
        }
        settings.sharedSessionID = sessionID
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
        let serverSession = try await http.agentObject("api/sessions/\(sessionID)")
        guard let workspace = serverSession["workspace_id"] as? String, WireID.valid(workspace) else {
            throw ConversationError.invalidResponse
        }
        try Task.checkCancellation()
        guard context.generation == selection else { throw CancellationError() }
        let frame = try await http.agentObject("api/workspaces/\(workspace)/observations", method: "POST", body: [
            "filename": "ipad-\(source.rawValue)-\(hash.prefix(12)).jpg", "content_type": "image/jpeg",
            "summary": "Explicitly shared iPad image (\(source.rawValue))", "session_id": sessionID,
            "data_base64": jpeg.base64EncodedString()], timeout: 60)
        guard let observation = frame["id"] as? String, WireID.valid(observation),
              frame["session_id"] as? String == sessionID else { throw ConversationError.invalidResponse }
        try Task.checkCancellation()
        guard context.generation == selection else { throw CancellationError() }
        let report = try await http.agentObject("api/observations/\(observation)/vision", method: "POST",
            body: ["session_id": sessionID], timeout: 210)
        guard report["frame_observation_id"] as? String == observation,
              let description = report["description_observation_id"] as? String, WireID.valid(description) else {
            throw ConversationError.invalidResponse
        }
        try Task.checkCancellation()
        guard context.bind(attachmentID: description, sha256: hash, source: source,
            observedAt: observedAt, sessionID: sessionID, generation: selection) else { throw CancellationError() }
        context.previewJPEG = jpeg
    }

    static func preferredWorkspaceID(_ workspaces: [[String: Any]]) -> String? {
        let ipad = workspaces.filter {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare("Kairo iPad") == .orderedSame
        }
        let chosen = ipad.count == 1 ? ipad.first : (workspaces.count == 1 ? workspaces.first : nil)
        guard let id = chosen?["id"] as? String, WireID.valid(id) else { return nil }
        return id
    }
}
