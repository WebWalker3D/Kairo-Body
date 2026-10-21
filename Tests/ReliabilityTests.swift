import XCTest
@testable import KairoBody

final class ReliabilityTests: XCTestCase {
    func testHTTPStatusClassification() {
        XCTAssertEqual(RequestFailure.kind(status: 401), .authorizationLost)
        XCTAssertEqual(RequestFailure.kind(status: 403), .authorizationLost)
        XCTAssertEqual(RequestFailure.kind(status: 408), .transient)
        XCTAssertEqual(RequestFailure.kind(status: 429), .transient)
        XCTAssertEqual(RequestFailure.kind(status: 503), .transient)
        XCTAssertEqual(RequestFailure.kind(status: 400), .rejected)
        XCTAssertEqual(RequestFailure.kind(status: 409), .rejected)
        XCTAssertEqual(RequestFailure.kind(of: HTTPStatusError(status: 500, code: "x")), .transient)
        XCTAssertEqual(RequestFailure.kind(of: MalformedResponse()), .transient)
    }

    func testURLErrorClassification() {
        XCTAssertEqual(RequestFailure.kind(of: URLError(.userAuthenticationRequired)), .authorizationLost)
        XCTAssertEqual(RequestFailure.kind(of: URLError(.badURL)), .rejected)
        XCTAssertEqual(RequestFailure.kind(of: URLError(.timedOut)), .transient)
    }

    func testBackoffIsBoundedExponential() {
        XCTAssertEqual(Backoff.delay(afterFailures: 1), 1)
        XCTAssertEqual(Backoff.delay(afterFailures: 2), 2)
        XCTAssertEqual(Backoff.delay(afterFailures: 4), 8)
        XCTAssertEqual(Backoff.delay(afterFailures: 30, cap: 15), 15)
    }

    func testObserverCadence() {
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: true, consecutiveFailures: 0), 2)
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: false, consecutiveFailures: 0), 10)
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: false, consecutiveFailures: 2), 2)
        XCTAssertEqual(ObserverPollSchedule.interval(turnRunning: false, consecutiveFailures: 9), 10)
    }

    func testConditionalClassification() {
        XCTAssertEqual(ObserverResponse.classify(status: 200, sentValidator: true), .fresh)
        XCTAssertEqual(ObserverResponse.classify(status: 304, sentValidator: true), .notModified)
        // A 304 we never asked for cannot be trusted as "nothing changed".
        XCTAssertEqual(ObserverResponse.classify(status: 304, sentValidator: false), .transient)
        XCTAssertEqual(ObserverResponse.classify(status: 401, sentValidator: true), .authorizationLost)
        XCTAssertEqual(ObserverResponse.classify(status: 503, sentValidator: true), .transient)
    }

    func testTransportGateAllowsOneReconnectPerTransport() {
        var gate = TransportGate()
        let first = gate.begin()
        let second = gate.begin()          // replaced before it ever failed
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertFalse(gate.fail(first))   // late failure from the replaced socket
        XCTAssertTrue(gate.fail(second))   // exactly once
        XCTAssertFalse(gate.fail(second))  // never twice
        XCTAssertTrue(gate.reconnectPending)
        let third = gate.begin()           // the reconnect
        XCTAssertTrue(gate.isCurrent(third))
    }

    func testLivenessProbeAnswersWithinDeadline() async {
        let answered = await LivenessProbe.answered(within: 0.5) {}
        XCTAssertTrue(answered)
        let hung = await LivenessProbe.answered(within: 0.05) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTAssertFalse(hung)
        let failed = await LivenessProbe.answered(within: 0.5) { throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(failed)
    }

    func testJSONDateParsingBothFormats() {
        XCTAssertNotNil(BodyJSON.date("2026-10-21T12:00:00.123Z"))
        XCTAssertNotNil(BodyJSON.date("2026-10-21T12:00:00Z"))
        XCTAssertNil(BodyJSON.date("not-a-date"))
        XCTAssertNil(BodyJSON.date(42))
    }

    func testEndpointPathBuiltSegmentedBySegment() {
        let base = URL(string: "https://connect.kairo.icu")!
        let url = KairoHTTP.endpoint(base, path: "api/sessions/abc/jobs?tail=20&compact=1")
        XCTAssertEqual(url?.host, "connect.kairo.icu")
        XCTAssertEqual(url?.path, "/api/sessions/abc/jobs")
        XCTAssertEqual(url?.query?.contains("tail"), true)
        // Caller text can never escape into host or query.
        let hostile = KairoHTTP.endpoint(base, path: "api/x/../evil?#h")
        XCTAssertEqual(hostile?.host, "connect.kairo.icu")
        XCTAssertNil(KairoHTTP.endpoint(URL(string: "http://connect.kairo.icu")!, path: "api/x"))
        XCTAssertNil(KairoHTTP.endpoint(URL(string: "https://evil.example")!, path: "api/x"))
        XCTAssertNil(KairoHTTP.endpoint(URL(string: "https://evil.example/@connect.kairo.icu")!, path: "api/x"))
    }

    func testWireIDRejectsUntrustedShapes() {
        XCTAssertTrue(WireID.valid("session_017c"))
        XCTAssertTrue(WireID.valid("ipad-pro-2017-blaine"))
        XCTAssertFalse(WireID.valid(""))
        XCTAssertFalse(WireID.valid("has space"))
        XCTAssertFalse(WireID.valid("query?x=1"))
        XCTAssertFalse(WireID.valid(String(repeating: "a", count: 201)))
    }
}
