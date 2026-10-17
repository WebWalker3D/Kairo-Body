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

/// Identity of the one live body transport. Callbacks carry the ID they were
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
