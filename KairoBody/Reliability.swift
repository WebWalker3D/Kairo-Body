import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A non-2xx HTTP answer. `code` is the server's machine-readable reason, when sent.
struct HTTPStatusError: Error, Equatable {
    let status: Int
    var code: String? = nil
}

/// A 2xx answer whose body was not the expected JSON shape.
struct MalformedResponse: Error, Equatable {}

/// How a failed request should be treated. Only `authorizationLost` may erase
/// owner-private content; `transient` keeps what is on screen and retries.
enum RequestFailureKind: Equatable {
    case transient
    case authorizationLost
    case rejected
}

enum RequestFailure {
    static func kind(status: Int) -> RequestFailureKind {
        switch status {
        case 401, 403: return .authorizationLost
        case 408, 425, 429, 500...599: return .transient
        default: return .rejected
        }
    }

    static func kind(of error: Error) -> RequestFailureKind {
        if let status = error as? HTTPStatusError { return kind(status: status.status) }
        if error is MalformedResponse { return .transient }
        if let url = error as? URLError {
            switch url.code {
            case .userAuthenticationRequired: return .authorizationLost
            case .badURL, .unsupportedURL: return .rejected
            default: return .transient
            }
        }
        return .rejected
    }
}

enum Backoff {
    /// 1, 2, 4, 8 … seconds after successive failures, capped.
    static func delay(afterFailures failures: Int, cap: Double = 15) -> Double {
        min(cap, pow(2, Double(max(failures, 1) - 1)))
    }
}

/// Cadence of the read-only all-surfaces conversation observer.
enum ObserverPollSchedule {
    static let active: Double = 2
    static let idle: Double = 10

    static func interval(turnRunning: Bool, consecutiveFailures: Int) -> Double {
        guard consecutiveFailures > 0 else { return turnRunning ? active : idle }
        return min(idle, max(active, Backoff.delay(afterFailures: consecutiveFailures)))
    }
}

enum ObserverResponse: Equatable {
    case fresh
    case notModified
    case transient
    case authorizationLost

    static func classify(status: Int, sentValidator: Bool) -> ObserverResponse {
        switch status {
        case 200: return .fresh
        case 304: return sentValidator ? .notModified : .transient
        case 401, 403: return .authorizationLost
        default: return .transient
        }
    }
}

/// Body socket heartbeat cadence while the app is active.
enum LivenessSchedule {
    static let interval: Double = 20
    static let deadline: Double = 10
}

/// URLSession configuration for every link this app holds open on a body that
/// runs around the clock. The client owns reconnection — bounded backoff,
/// liveness probes, a data-currency supervisor — so URLSession must never sit
/// silently on a half-dead link: `waitsForConnectivity` retries invisibly
/// where our own loop would report and reconnect, and the default 7-day
/// resource timeout lets a stalled operation linger forever. Every timeout
/// here is finite, and every reconnect goes through the client's loop.
enum TransportConfig {
    /// One HTTP session for the whole app; per-call `timeoutInterval` still applies.
    static let sharedSession = URLSession(configuration: http())

    static func websocket() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.shouldUseExtendedBackgroundIdleMode = true
        return config
    }

    static func http() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        return config
    }
}

/// Pure supervisor of link data currency: successful sends, receives and pongs
/// advance it; while the transport claims to be connected, silence longer than
/// the grace period means the link is a lie and the owner must tear it down.
/// Freshness is unknown (not stale) until a transport reports its opening ping,
/// so the connect handshake itself is never raced by the supervisor.
struct LinkActivity {
    private(set) var lastActivityAt: Date?

    mutating func note(_ date: Date = Date()) { lastActivityAt = date }
    mutating func reset() { lastActivityAt = nil }

    func stale(at date: Date, after grace: TimeInterval) -> Bool {
        guard let lastActivityAt else { return false }
        return date.timeIntervalSince(lastActivityAt) > grace
    }
}

/// A deadline on an await that could hang forever — the most common way a
/// foreground body app dies: one stalled WebSocket send leaves a caller
/// suspended indefinitely, then the next, and the next. The wrapped operation
/// is cancelled at the deadline and the caller always receives an outcome, so
/// nothing that supervises the body can be held open by a dead peer. The
/// attempt may finish after the deadline; its late result is simply ignored.
enum StalledOperation {
    struct TimedOut: Error {}

    enum Outcome<T> {
        case value(T)
        case failure(Error)
        case timedOut
    }

    static func outcome<T>(_ seconds: Double,
                           _ operation: @escaping @Sendable () async throws -> T) async -> Outcome<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let once = ResumeOnceOutcome(continuation)
            let attempt = Task {
                do { once.resume(.value(try await operation())) }
                catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                once.resume(.timedOut)
                attempt.cancel()
            }
        }
    }

    static func call<T>(_ seconds: Double,
                        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        switch await outcome(seconds, operation) {
        case .value(let value): return value
        case .failure(let error): throw error
        case .timedOut: throw TimedOut()
        }
    }
}

private final class ResumeOnceOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StalledOperation.Outcome<T>, Never>?

    init(_ continuation: CheckedContinuation<StalledOperation.Outcome<T>, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: StalledOperation.Outcome<T>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

enum LivenessProbe {
    /// Whether `ping` completes within `seconds`. A ping that never calls back
    /// (a half-open socket) counts as dead at the deadline rather than hanging.
    static func answered(within seconds: Double,
                         ping: @escaping @Sendable () async throws -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let outcome = ResumeOnce(continuation)
            let attempt = Task {
                do { try await ping(); outcome.resume(true) } catch { outcome.resume(false) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                outcome.resume(false)
                attempt.cancel()
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Identity of the one live transport. Callbacks carry the ID they were
/// started with, so a late error from a replaced socket cannot tear down its
/// replacement, and one socket's failures schedule exactly one reconnect.
struct TransportGate {
    private(set) var current: UUID?
    private(set) var reconnectPending = false

    mutating func begin() -> UUID {
        let id = UUID()
        current = id
        reconnectPending = false
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { current == id }

    /// True exactly once for the current transport; the caller tears it down
    /// and schedules the single reconnect.
    mutating func fail(_ id: UUID) -> Bool {
        guard current == id else { return false }
        current = nil
        reconnectPending = true
        return true
    }

    mutating func stop() {
        current = nil
        reconnectPending = false
    }
}

enum BodyJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func now() -> String { iso8601.string(from: Date()) }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
