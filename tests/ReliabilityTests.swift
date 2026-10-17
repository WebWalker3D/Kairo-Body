import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KairoBody

final class RequestFailureTests: XCTestCase {
    func testOutagesAreTransientAndOnlyAuthorizationStatusesMeanLoss() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertEqual(RequestFailure.kind(status: status), .transient, "\(status)")
        }
        XCTAssertEqual(RequestFailure.kind(status: 401), .authorizationLost)
        XCTAssertEqual(RequestFailure.kind(status: 403), .authorizationLost)
        for status in [400, 404, 409, 422] {
            XCTAssertEqual(RequestFailure.kind(status: status), .rejected, "\(status)")
        }
    }

    func testNetworkErrorsAndMalformedBodiesAreTransient() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertEqual(RequestFailure.kind(of: URLError(code)), .transient, "\(code)")
        }
        XCTAssertEqual(RequestFailure.kind(of: HTTPStatusError(status: 502)), .transient)
        XCTAssertEqual(RequestFailure.kind(of: HTTPStatusError(status: 403)), .authorizationLost)
        XCTAssertEqual(RequestFailure.kind(of: MalformedResponse()), .transient)
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual((1...6).map { Backoff.delay(afterFailures: $0) }, [1, 2, 4, 8, 15, 15])
        XCTAssertEqual(Backoff.delay(afterFailures: 3, cap: 5), 4)
        XCTAssertEqual(Backoff.delay(afterFailures: 9, cap: 5), 5)
    }
}

final class ObserverPollTests: XCTestCase {
    func testPollsEveryTwoSecondsDuringATurnAndEveryTenWhileIdle() {
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: true, consecutiveFailures: 0), 2)
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: false, consecutiveFailures: 0), 10)
    }

    func testFailuresBackOffWithoutExceedingTheIdleInterval() {
        let delays = (1...6).map { ObserverPollSchedule.interval(turnRunning: true, consecutiveFailures: $0) }
        XCTAssertEqual(delays, [2, 2, 4, 8, 10, 10])
    }

    func testOnlyAValidatedNotModifiedKeepsTheTranscriptAsCurrent() {
        XCTAssertEqual(ObserverResponse.classify(status: 200, sentValidator: true), .fresh)
        XCTAssertEqual(ObserverResponse.classify(status: 304, sentValidator: true), .notModified)
        // A 304 we never asked for is a proxy or server fault, not "nothing changed".
        XCTAssertEqual(ObserverResponse.classify(status: 304, sentValidator: false), .transient)
        XCTAssertEqual(ObserverResponse.classify(status: 401, sentValidator: true), .authorizationLost)
        XCTAssertEqual(ObserverResponse.classify(status: 403, sentValidator: false), .authorizationLost)
        for status in [404, 500, 502, 503, 504] {
            XCTAssertEqual(ObserverResponse.classify(status: status, sentValidator: true), .transient)
        }
    }
}

final class TransportGateTests: XCTestCase {
    func testStaleTransportCallbacksAreIgnored() {
        var gate = TransportGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertFalse(gate.fail(first), "a late failure from the replaced socket must not tear down its replacement")
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testOneFailureSchedulesExactlyOneReconnect() {
        var gate = TransportGate()
        let transport = gate.begin()
        XCTAssertTrue(gate.fail(transport))
        XCTAssertFalse(gate.fail(transport), "receive and send errors for one socket must not stack reconnects")
        XCTAssertTrue(gate.reconnectPending)
        XCTAssertNil(gate.current)
        _ = gate.begin()
        XCTAssertFalse(gate.reconnectPending)
    }

    func testStopClearsTransportAndPendingReconnect() {
        var gate = TransportGate()
        let transport = gate.begin()
        _ = gate.fail(transport)
        gate.stop()
        XCTAssertFalse(gate.reconnectPending)
        XCTAssertNil(gate.current)
    }
}

final class LivenessProbeTests: XCTestCase {
    func testAnsweredPingIsAlive() async {
        let alive = await LivenessProbe.answered(within: 1) { }
        XCTAssertTrue(alive)
    }

    func testFailedPingIsDead() async {
        let alive = await LivenessProbe.answered(within: 1) { throw URLError(.networkConnectionLost) }
        XCTAssertFalse(alive)
    }

    func testUnansweredPingIsDeadAtTheDeadlineEvenIfItNeverReturns() async {
        let started = Date()
        let alive = await LivenessProbe.answered(within: 0.2) {
            // Models URLSessionWebSocketTask.sendPing on a half-open socket:
            // the completion handler is never called.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        XCTAssertFalse(alive)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testScheduleMatchesTheRequestedCadence() {
        XCTAssertEqual(LivenessSchedule.interval, 20)
        XCTAssertEqual(LivenessSchedule.deadline, 10)
    }
}
