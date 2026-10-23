import XCTest
@testable import KairoBody

/// Pins the around-the-clock duty-cycle behaviour: every link the body holds
/// open must be bounded, supervised and self-healing, so a stalled peer —
/// e.g. a core whose APIs are drowning in recovery-backup I/O — can degrade
/// the surface but can never hang the app forever.
final class SelfHealingTests: XCTestCase {

    // MARK: Transport configuration

    func testWebsocketConfigurationNeverWaitsSilently() {
        let config = TransportConfig.websocket()
        // The client owns reconnection: backoff, probes, supervisor. URLSession
        // retries invisible to us are how a body sits dead for hours.
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertGreaterThan(config.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 300)
        XCTAssertTrue(config.shouldUseExtendedBackgroundIdleMode)
    }

    func testHTTPConfigurationIsBounded() {
        let config = TransportConfig.http()
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertGreaterThan(config.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 120)
    }

    // MARK: Bounded operations

    func testFastOperationPassesThroughUnharmed() async throws {
        let value = try await StalledOperation.call(5) { "here" }
        XCTAssertEqual(value, "here")
    }

    func testFailedOperationPropagatesItsOwnError() async {
        do {
            try await StalledOperation.call(5) { throw URLError(.timedOut) }
            XCTFail("expected the operation's error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("expected URLError, got \(type(of: error))")
        }
    }

    func testStalledOperationReturnsAtItsDeadline() async {
        let outcome = await StalledOperation.outcome(0.05) {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "late"
        }
        switch outcome {
        case .timedOut: break
        case .value: XCTFail("a 10 s sleep must not beat a 50 ms deadline")
        case .failure: XCTFail("expected timedOut, got failure")
        }
    }

    func testDeadlineCancelsTheStalledOperation() async {
        let cancelled = Flag()
        _ = await StalledOperation.outcome(0.05) {
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            } onCancel: {
                cancelled.set()
            }
        }
        // The cancel fires inside the deadline task just before the outcome is
        // delivered; give it a bounded moment to land.
        for _ in 0..<100 where !cancelled.isSet {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cancelled.isSet, "a deadline must cancel the operation it outran")
    }

    func testCallThrowsTimedOutAtTheDeadline() async {
        do {
            try await StalledOperation.call(0.05) {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "late"
            }
            XCTFail("expected TimedOut")
        } catch is StalledOperation.TimedOut {
            // the deadline is the expected outcome
        } catch { XCTFail("expected StalledOperation.TimedOut, got \(type(of: error))") }
    }

    // MARK: Link currency supervisor

    func testLinkActivityGracesThenStales() {
        let start = Date(timeIntervalSince1970: 1_000)
        var activity = LinkActivity()
        // Fresh transport: nothing noted yet, so the supervisor never races the
        // opening handshake.
        XCTAssertFalse(activity.stale(at: start.addingTimeInterval(9_999), after: 60))
        activity.note(start)
        XCTAssertFalse(activity.stale(at: start.addingTimeInterval(59.9), after: 60))
        XCTAssertTrue(activity.stale(at: start.addingTimeInterval(61), after: 60))
        activity.note(start.addingTimeInterval(61))
        XCTAssertFalse(activity.stale(at: start.addingTimeInterval(119), after: 60))
        activity.reset()
        XCTAssertFalse(activity.stale(at: start.addingTimeInterval(9_999), after: 60))
    }

    // MARK: Timing discipline

    func testBodyLinkTimingIsCoherent() {
        let timing = BodyLinkTiming()
        // Every probe cycle answers within interval+deadline; the supervisor is
        // strictly more patient, and both stay well under the frame cadence's
        // tolerance so a healthy link is never taken down by its watchdogs.
        XCTAssertLessThan(timing.livenessDeadline, timing.livenessInterval)
        XCTAssertGreaterThan(timing.activityStale, timing.livenessInterval + timing.livenessDeadline)
        XCTAssertLessThan(timing.activityStale, 120)
        XCTAssertGreaterThanOrEqual(timing.sendDeadline, 5)
        XCTAssertLessThanOrEqual(timing.sendDeadline, 30)
        // Reconnect is bounded exponential forever.
        XCTAssertEqual(timing.reconnectDelay(1), 1)
        XCTAssertEqual(timing.reconnectDelay(5), 16)
        XCTAssertEqual(timing.reconnectDelay(99), 30)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
