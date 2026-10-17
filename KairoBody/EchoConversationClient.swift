import Foundation

/// Read-only projection of Kairo conversations across paired owner surfaces. There is no
/// SpeechService or job-submission dependency on this path.
@MainActor
final class EchoConversationClient: ObservableObject {
    @Published private(set) var turns: [EchoTurn] = []
    @Published private(set) var progress: PromptTokenProgress?
    @Published private(set) var usage = EchoTokenUsage(events: [])
    @Published private(set) var state: EchoStateFrame?
    @Published private(set) var error: String?
    @Published private(set) var following = false
    /// Shown beside a transcript that is kept while Kairo cannot be reached.
    @Published private(set) var connectionTrouble: String?
    @Published private(set) var lastUpdatedAt: Date?
    var processing: Bool { following && turns.contains(where: \.active) }

    private let session: URLSession
    private let agentToken: () -> String
    private let ownerCredential: () -> String
    private var observerCredential = ""
    private var pollTask: Task<Void, Never>?
    private var binding = ""
    private var generation = 0
    private var settledIDs: Set<String> = []
    private var foreground = true
    private var refreshing = false
    private var observerValidator: String?
    private var consecutiveFailures = 0

    init(session: URLSession = .shared, agentToken: @escaping () -> String,
         ownerCredential: @escaping () -> String = { "" }) {
        self.session = session
        self.agentToken = agentToken
        self.ownerCredential = ownerCredential
    }

    func followAllSurfaces(foreground: Bool) {
        // Already following this owner in the foreground: keep the running
        // loop. Restarting would discard the read in flight.
        if foreground, following, pollTask != nil, !agentToken().isEmpty,
           observerCredential == ownerCredential() { return }
        stop()
        self.foreground = foreground
        guard !agentToken().isEmpty, PrivateBodyClient.validCredential(ownerCredential()) else {
            clearObserver()
            return
        }
        // Leaving the foreground pauses reads but keeps the transcript and its
        // scroll position; only missing or refused authority clears it.
        guard foreground else { return }
        following = true
        // stop() cancels this task; refreshes themselves bump `generation`
        // when they adopt an owner proof, so it is not a loop identity.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.refreshAllSurfaces()
                // One loop owns the cadence, so reads never overlap. A skipped
                // read (one from a previous loop still in flight) retries soon.
                let delay = outcome == nil ? 1 : ObserverPollSchedule.interval(
                    turnRunning: self.turns.contains(where: \.active),
                    consecutiveFailures: self.consecutiveFailures)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func clearObserver() {
        turns = []; state = nil; progress = nil; usage = EchoTokenUsage(events: [])
        error = nil; observerCredential = ""; observerValidator = nil
        connectionTrouble = nil; lastUpdatedAt = nil; consecutiveFailures = 0
    }

    /// One conditional read. Timeouts, server errors, unrequested 304s and
    /// malformed bodies keep the transcript and report trouble; only a
    /// confirmed 401/403 or a different owner proof clears it.
    @discardableResult
    func refreshAllSurfaces() async -> ObserverResponse? {
        let credential = ownerCredential()
        guard foreground, !refreshing, !agentToken().isEmpty else { return nil }
        guard PrivateBodyClient.validCredential(credential) else { clearObserver(); return .authorizationLost }
        if observerCredential != credential {
            // A different owner proof is a different conversation authority.
            clearObserver()
            observerCredential = credential
            generation += 1
        }
        let current = generation
        refreshing = true
        defer { refreshing = false }
        let validator = observerValidator
        do {
            let (status, data, etag) = try await conditionalGet(
                "api/ipad/conversations?tail=20", ownerProof: credential, validator: validator)
            guard current == generation, foreground, ownerCredential() == credential, !Task.isCancelled else { return nil }
            let outcome = ObserverResponse.classify(status: status, sentValidator: validator != nil)
            switch outcome {
            case .notModified:
                break
            case .fresh:
                guard let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      snapshot["schema_version"] as? Int == 1, snapshot["read_only"] as? Bool == true,
                      let jobs = snapshot["turns"] as? [[String: Any]], jobs.count <= 84 else {
                    throw MalformedResponse()
                }
                turns = jobs.compactMap { EchoTurn(observedJob: $0) }.sorted { $0.createdAt < $1.createdAt }
                state = EchoStateFrame(snapshot: snapshot)
                // Global progress is deliberately represented on each attributed turn.
                progress = nil; usage = EchoTokenUsage(events: [])
                observerValidator = etag
            case .authorizationLost:
                // A refused owner proof must not leave owner-private content on screen.
                clearObserver()
                error = EchoReadError.refused.localizedDescription
                return outcome
            case .transient:
                throw HTTPStatusError(status: status)
            }
            consecutiveFailures = 0
            connectionTrouble = nil
            error = nil
            lastUpdatedAt = Date()
            return outcome
        } catch {
            guard current == generation, foreground, ownerCredential() == credential, !Task.isCancelled else { return nil }
            consecutiveFailures += 1
            let cause = Self.troubleCause(error)
            connectionTrouble = lastUpdatedAt.map {
                "Connection trouble (\(cause)). Showing the conversation as of \($0.formatted(date: .omitted, time: .shortened)); retrying."
            } ?? "Can't reach Kairo's conversations right now (\(cause)); retrying."
            return .transient
        }
    }

    static func troubleCause(_ error: Error) -> String {
        if let status = error as? HTTPStatusError { return "HTTP \(status.status)" }
        if error is MalformedResponse { return "unreadable response" }
        if let url = error as? URLError {
            return url.code == .timedOut ? "timed out" : "network: \(url.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    func follow(sessionID: String?, foreground: Bool) {
        stop()
        self.foreground = foreground
        guard foreground, let id = EchoBinding.sessionID(sessionID), !agentToken().isEmpty else { return }
        following = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(sessionID: id)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        following = false
        foreground = false
    }

    func refresh(sessionID: String) async {
        guard foreground, !refreshing, let id = EchoBinding.sessionID(sessionID), !agentToken().isEmpty else { return }
        if binding != id {
            generation += 1
            binding = id
            settledIDs = []
            turns = []
            state = nil
            progress = nil
            usage = EchoTokenUsage(events: [])
        }
        let current = generation
        refreshing = true
        defer { refreshing = false }
        do {
            let object = try await get("api/sessions/\(id)/jobs?tail=20&compact=1")
            guard current == generation, foreground, !Task.isCancelled else { return }
            guard let jobs = object as? [[String: Any]] else { throw EchoReadError.invalid }
            let next = jobs.compactMap { EchoTurn(job: $0, sessionID: id) }
                .sorted { $0.createdAt < $1.createdAt }
            turns = next
            error = nil
            let latest = next.last(where: \.active) ?? next.last
            if let latest {
                let value = try await get("api/jobs/\(latest.id)/events?tail=64")
                guard current == generation, foreground, !Task.isCancelled else { return }
                guard let events = value as? [[String: Any]] else { throw EchoReadError.invalid }
                progress = events.compactMap(PromptTokenProgress.init(event:)).max { $0.sequence < $1.sequence }
                usage = EchoTokenUsage(events: events)
            } else {
                progress = nil
                usage = EchoTokenUsage(events: [])
            }
            let completed = Set(next.filter { $0.settledStatus != nil }.map(\.id))
            if state == nil || !completed.subtracting(settledIDs).isEmpty {
                let value = try await get("api/kairo-state")
                guard current == generation, foreground, !Task.isCancelled else { return }
                guard let snapshot = value as? [String: Any] else { throw EchoReadError.invalid }
                state = EchoStateFrame(snapshot: snapshot)
                settledIDs = completed
            }
        } catch {
            guard current == generation, foreground, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// GET that returns the status instead of throwing on non-2xx, so the
    /// caller can tell "unchanged" and "refused" apart from an outage.
    private func conditionalGet(_ path: String, ownerProof: String,
                                validator: String?) async throws -> (Int, Data, String?) {
        guard let url = URL(string: "https://connect.kairo.icu/" + path) else { throw EchoReadError.invalid }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(agentToken())", forHTTPHeaderField: "Authorization")
        request.setValue(ownerProof, forHTTPHeaderField: "X-Kairo-Device")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-None-Match") }
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        guard data.count <= 8_388_608 else { throw MalformedResponse() }
        return (http.statusCode, data, http.value(forHTTPHeaderField: "ETag"))
    }

    private func get(_ path: String, ownerProof: String? = nil) async throws -> Any {
        guard let url = URL(string: "https://connect.kairo.icu/" + path) else { throw EchoReadError.invalid }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(agentToken())", forHTTPHeaderField: "Authorization")
        if let ownerProof { request.setValue(ownerProof, forHTTPHeaderField: "X-Kairo-Device") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= (ownerProof == nil ? 1_048_576 : 8_388_608) else { throw EchoReadError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }
}

private enum EchoReadError: LocalizedError {
    case invalid, unavailable, refused
    var errorDescription: String? {
        switch self {
        case .invalid: return "Kairo returned an invalid conversation projection."
        case .unavailable: return "Could not refresh conversations. Check owner pairing, the Agent token and connection."
        case .refused: return "Kairo refused this iPad's owner access. Check the Agent token and pair again in Settings."
        }
    }
}
