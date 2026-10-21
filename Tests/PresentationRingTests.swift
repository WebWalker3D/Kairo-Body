import XCTest
@testable import KairoBody

final class PresentationTests: XCTestCase {
    private func object(phase: String = "working", expression: String? = "curious",
                        observed: Date = Date(), lifetime: TimeInterval = 20,
                        proximity: (String, String)? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": 1, "read_only": true,
            "observed_at": BodyJSON.iso8601.string(from: observed),
            "expires_at": BodyJSON.iso8601.string(from: observed.addingTimeInterval(lifetime)),
            "activity": ["phase": phase],
            "expression": ["available": true, "state": expression ?? "calm", "revision": 3],
        ]
        if let proximity {
            object["body_proximity"] = [
                "available": true, "state": proximity.0,
                "source_endpoint_id": proximity.1, "observation_id": "obs_1",
                "observed_at": BodyJSON.iso8601.string(from: observed),
                "expires_at": BodyJSON.iso8601.string(from: observed.addingTimeInterval(40)),
            ]
        }
        return object
    }

    func testFreshSnapshotParsesActivityExpressionAndProximity() {
        let snapshot = GlobalBodyPresentation(object: object(proximity: ("near", "s22plus-blaine-sensor")))
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.phase, "working")
        XCTAssertEqual(snapshot?.expression, "curious")
        XCTAssertEqual(snapshot?.proximity?.state, "near")
        XCTAssertEqual(snapshot?.proximity?.sourceEndpointID, "s22plus-blaine-sensor")
        XCTAssertTrue(snapshot?.processing ?? false)
    }

    func testStaleAndUnauthorisedShapesRejected() {
        XCTAssertNil(GlobalBodyPresentation(object: object(lifetime: -1)))
        var noReadOnly = object()
        noReadOnly["read_only"] = false
        XCTAssertNil(GlobalBodyPresentation(object: noReadOnly))
        var badPhase = object(phase: "confused")
        badPhase["activity"] = ["phase": "confused"]
        XCTAssertNil(GlobalBodyPresentation(object: badPhase))
        XCTAssertNil(GlobalBodyPresentation(object: ["schema_version": 2]))
    }

    func testExpressionOnlyFromCommittedRevision() {
        var snapshot = object()
        snapshot["expression"] = ["available": false]
        let parsed = GlobalBodyPresentation(object: snapshot)
        XCTAssertEqual(parsed?.expression, nil)
        snapshot["expression"] = ["available": true, "state": "elated", "revision": 9]
        XCTAssertNil(GlobalBodyPresentation(object: snapshot)?.expression) // preset not in the vocabulary
        snapshot["expression"] = ["available": true, "state": "reflective", "revision": 0]
        XCTAssertNil(GlobalBodyPresentation(object: snapshot)?.expression)
    }

    func testFailedRefreshKeepsOnlyFreshPrevious() {
        let previous = GlobalBodyPresentation(object: object(observed: Date(timeIntervalSinceNow: -5), lifetime: 20))
        let kept = GlobalBodyPresentation.afterRefresh(nil, previous: previous)
        XCTAssertNotNil(kept)
        let bothStale = GlobalBodyPresentation.afterRefresh(
            nil, previous: GlobalBodyPresentation(object: object(observed: Date(timeIntervalSinceNow: -60), lifetime: 30)))
        XCTAssertNil(bothStale)
    }

    func testExpressionStateNeverInventsMood() {
        // Unpaired keeps the other renderer's fallback.
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: nil, paired: false, fallback: "body calm"), "body calm")
        // Paired but no fresh committed mood: awaiting, not a guess.
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: nil, paired: true, fallback: "body calm"), "awaiting state")
        let snapshot = GlobalBodyPresentation(object: object(expression: "joyful"))
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: snapshot, paired: true, fallback: "body calm"), "joyful")
    }

    func testProximityNeedsReceiptAndFortyFiveSecondWindow() {
        var object = object(proximity: ("away", "s22plus-blaine-sensor"))
        object["body_proximity"] = (object["body_proximity"] as? [String: Any])?.merging(
            ["observation_id": ""]) { _, new in new }
        XCTAssertNil(GlobalBodyPresentation(object: object)?.proximity)
    }
}

final class RingMirrorTests: XCTestCase {
    private func dot(_ phase: String, levels: [Double] = [], at now: Date = Date()) -> DotActivityState {
        var state = DotActivityState()
        _ = state.receive([
            "type": "dot_activity", "protocol_version": 2,
            "endpoint_id": EchoBinding.endpointID, "sequence": 1,
            "observed_at_ms": Int(now.timeIntervalSince1970 * 1000), "lease_ms": 8_000,
            "phase": phase, "replay_available": false, "output_levels": levels,
        ])
        return state
    }

    func testResampleMapsOntoTwelveEmitters() {
        let zeros = RingMirror.resample([], to: 12)
        XCTAssertEqual(zeros.count, 12)
        XCTAssertEqual(zeros, Array(repeating: 0, count: 12))
        // Fewer levels than emitters: ends are held, the middle stretches.
        let stretched = RingMirror.resample([1.0], to: 12)
        XCTAssertEqual(stretched, Array(repeating: 1.0, count: 12))
        let ramp = RingMirror.resample([0.0, 1.0], to: 12)
        XCTAssertEqual(ramp.first, 0.0)
        XCTAssertEqual(ramp.last, 1.0)
        XCTAssertTrue(ramp[5] > 0.3 && ramp[5] < 0.7)
        // More levels than emitters: windows are averaged, deterministic.
        let wave = (0..<32).map { Double($0 % 8) / 7.0 }
        let wave12 = RingMirror.resample(wave, to: 12)
        XCTAssertEqual(wave12.count, 12)
        XCTAssertEqual(wave12, RingMirror.resample(wave, to: 12))
        XCTAssertTrue(wave12.allSatisfy { (0...1).contains($0) })
    }

    func testFreshDotPhaseWinsOverPresentation() {
        let now = Date()
        let presentation = GlobalBodyPresentation(object: [
            "schema_version": 1, "read_only": true,
            "observed_at": BodyJSON.iso8601.string(from: now),
            "expires_at": BodyJSON.iso8601.string(from: now.addingTimeInterval(20)),
            "activity": ["phase": "idle"],
            "expression": ["available": true, "state": "reflective", "revision": 2],
        ])
        let ring = RingMirror.compose(dot: dot("thinking"), presentation: presentation,
                                      local: LocalActs(), now: now)
        XCTAssertEqual(ring.phase, .thinking)
        XCTAssertEqual(ring.mood, "reflective")
        XCTAssertEqual(ring.posture, .focused)
        XCTAssertTrue(ring.dotFresh)
    }

    func testLocalActsOnlyFillSilence() {
        let now = Date()
        var ring = RingMirror.compose(dot: DotActivityState(), presentation: nil,
                                      local: LocalActs(speaking: true), now: now)
        XCTAssertEqual(ring.phase, .speaking)
        ring = RingMirror.compose(dot: dot("listening"), presentation: nil,
                                  local: LocalActs(sending: true), now: now)
        XCTAssertEqual(ring.phase, .listening)
    }

    func testBackgroundPresentationBecomesReflecting() {
        let now = Date()
        let presentation = GlobalBodyPresentation(object: [
            "schema_version": 1, "read_only": true,
            "observed_at": BodyJSON.iso8601.string(from: now),
            "expires_at": BodyJSON.iso8601.string(from: now.addingTimeInterval(20)),
            "activity": ["phase": "background"],
            "expression": ["available": true, "state": "calm", "revision": 1],
        ])
        let ring = RingMirror.compose(dot: DotActivityState(), presentation: presentation,
                                      local: LocalActs(), now: now)
        XCTAssertEqual(ring.phase, .reflecting)
        XCTAssertEqual(ring.posture, .reflecting)
    }

    func testDotDisconnectShowsDisconnected() {
        let ring = RingMirror.compose(dot: dot("disconnected"), presentation: nil, local: LocalActs())
        XCTAssertEqual(ring.phase, .disconnected)
    }

    func testExpiredDotFallsBackThenIdle() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DotActivityState()
        _ = state.receive([
            "type": "dot_activity", "protocol_version": 2,
            "endpoint_id": EchoBinding.endpointID, "sequence": 1,
            "observed_at_ms": Int(base.timeIntervalSince1970 * 1000), "lease_ms": 500,
            "phase": "speaking", "replay_available": false, "output_levels": [0.5],
        ])
        let later = base.addingTimeInterval(1)
        let ring = RingMirror.compose(dot: state, presentation: nil, local: LocalActs(), now: later)
        XCTAssertEqual(ring.phase, .idle)
        XCTAssertFalse(ring.dotFresh)
        XCTAssertEqual(ring.levels, [])
    }
}
