import Foundation

/// Read-only projection of Kairo conversations across paired owner surfaces
/// (`/api/ipad/conversations`, conditional with ETag). There is no
/// SpeechService or job-submission dependency on this path. When owner
/// authority is absent, it can fall back to following only the configured
/// Dot session through the ordinary Agent API.
@MainActor
final class TranscriptFeedClient: ObservableObject {
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var liveState: LiveStateSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var following = false
    /// Shown beside a transcript that is kept while Kairo cannot be reached.
    @Published private(set) var connectionTrouble: String?
    @Published private(set) var lastUpdatedAt: Date?
    /// When Kairo last settled an answer on ANY surface, as observed here.
    /// The iPad is a surface, not a separate Kairo: a Discord answer is the
    /// body's own answer to show.
    @Published private(set) var lastAnsweredAt: Date?
    var processing: Bool { following && turns.contains(where: \.active) }

    typealias ConditionalRead = @MainActor (String, String?) async throws
        -> (response: ObserverResponse, object: [String: Any]?, validator: String?)

    private let read: ConditionalRead
    private let ownerProof: @MainActor () -> String
    private let agentAvailable: @MainActor () -> Bool
    private let sleep: @MainActor (Double) async throws -> Void
    private var pollTask: Task<Void, Never>?
    private var observerCredential = ""
    private var observerValidator: String?
    private var consecutiveFailures = 0
    private var generation = 0
    private var foreground = true
    private var refreshing = false
    private var lastSettledCreatedAt: String?

    convenience init(http: KairoHTTP = KairoHTTP()) {
        self.init(ownerProof: { AppConfig.ownerProof },
                  agentAvailable: { !AppConfig.agentToken.isEmpty },
                  read: { path, validator in
                      try await http.agentConditional(path, validator: validator)
                  })
    }

    init(ownerProof: @escaping @MainActor () -> String,
         agentAvailable: @escaping @MainActor () -> Bool,
         read: @escaping ConditionalRead,
         sleep: @escaping @MainActor (Double) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.ownerProof = ownerProof
        self.agentAvailable = agentAvailable
        self.read = read
        self.sleep = sleep
    }

    func followAllSurfaces(foreground: Bool) {
        // Already following this owner in the foreground: keep the running
        // loop. Restarting would discard the read in flight.
        let credential = ownerProof()
        if foreground, following, pollTask != nil,
           observerCredential == credential { return }
        stop()
        self.foreground = foreground
        guard agentAvailable(),
              PairingClient.validCredential(credential) else { clearObserver(); return }
        // Bind authority before capturing the loop generation. The first read
        // must not invalidate its own loop, and switching owners must clear
        // private content even while a cancelled request is still unwinding.
        if observerCredential != credential {
            clearObserver()
            observerCredential = credential
        }
        // Leaving the foreground pauses reads but keeps the transcript and its
        // scroll position; only missing or refused authority clears it.
        guard foreground else { return }
        following = true
        let current = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, current == self.generation else { return }
                let outcome = await self.refresh()
                // One loop owns the cadence, so reads never overlap. A skipped
                // read (one from a previous loop still in flight) retries soon.
                let delay = outcome == nil ? 1 : ObserverPollSchedule.interval(
                    turnRunning: self.turns.contains(where: \.active),
                    consecutiveFailures: self.consecutiveFailures)
                try? await self.sleep(delay)
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

    private func clearObserver() {
        turns = []; liveState = nil
        error = nil; observerCredential = ""; observerValidator = nil
        connectionTrouble = nil; lastUpdatedAt = nil; consecutiveFailures = 0
        lastAnsweredAt = nil; lastSettledCreatedAt = nil
    }

    /// A settled turn is something Kairo said out loud somewhere. Record the
    /// moment a newly settled answer is first observed so the body can beat
    /// it briefly. The first read only establishes the baseline: history that
    /// settled before this feed started is not a fresh answer.
    private func noteAnswers(in turns: [ConversationTurn]) {
        guard let newest = turns.compactMap({ $0.settledStatus == nil ? nil : $0.createdAt })
            .max() else { return }
        let previous = lastSettledCreatedAt
        lastSettledCreatedAt = newest
        if previous != nil, newest != previous { lastAnsweredAt = Date() }
    }

    /// One conditional read. Timeouts, server errors, unrequested 304s and
    /// malformed bodies keep the transcript and report trouble; only a
    /// confirmed 401/403 or a different owner proof clears it.
    @discardableResult
    func refresh() async -> ObserverResponse? {
        let credential = ownerProof()
        guard foreground, !refreshing else { return nil }
        guard PairingClient.validCredential(credential) else { clearObserver(); return .authorizationLost }
        if observerCredential != credential {
            // A different owner proof is a different conversation authority.
            clearObserver()
            observerCredential = credential
            // Credential checks below reject obsolete responses. A new owner
            // must not retire the polling loop that is observing this change.
        }
        let current = generation
        refreshing = true
        defer { refreshing = false }
        let validator = observerValidator
        do {
            let (outcome, snapshot, etag) = try await read(
                "api/ipad/conversations?tail=20", validator)
            guard current == generation, foreground, ownerProof() == credential,
                  !Task.isCancelled else { return nil }
            switch outcome {
            case .notModified:
                break
            case .fresh:
                guard let snapshot,
                      snapshot["schema_version"] as? Int == 1, snapshot["read_only"] as? Bool == true,
                      let jobs = snapshot["turns"] as? [[String: Any]], jobs.count <= 84 else {
                    throw MalformedResponse()
                }
                turns = jobs.compactMap { ConversationTurn(observedJob: $0) }
                    .sorted { $0.createdAt < $1.createdAt }
                noteAnswers(in: turns)
                liveState = LiveStateSnapshot(snapshot: snapshot)
                observerValidator = etag
            case .authorizationLost:
                // A refused owner proof must not leave owner-private content on screen.
                clearObserver()
                error = "Kairo refused this iPad's owner proof."
                return outcome
            case .transient:
                throw HTTPStatusError(status: 0)
            }
            consecutiveFailures = 0
            connectionTrouble = nil
            error = nil
            lastUpdatedAt = Date()
            return outcome
        } catch {
            guard current == generation, foreground, ownerProof() == credential,
                  !Task.isCancelled else { return nil }
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
}
