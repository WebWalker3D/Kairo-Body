import XCTest
@testable import KairoBody

/// The iPad is a surface, not a separate Kairo: a conversation on Discord or
/// the Dot is THIS body's conversation. These tests pin what the ring must
/// show for activity that happens elsewhere - and what must never show.
final class RemoteActRingTests: XCTestCase {
    private func compose(remote: RemoteActs, local: LocalActs = LocalActs(),
                         dot: DotActivityState = DotActivityState()) -> RingMirrorState {
        RingMirror.compose(dot: dot, presentation: nil, remote: remote, local: local)
    }

    func testActiveJobAnywhereReadsAsThinking() {
        XCTAssertEqual(compose(remote: RemoteActs(thinking: true)).phase, .thinking)
    }

    func testSettledAnswerWithoutPlaybackNeverSpeaks() {
        XCTAssertEqual(compose(remote: RemoteActs(answeredAgo: 3)).phase, .idle)
        XCTAssertEqual(compose(remote: RemoteActs(answeredAgo: 8)).phase, .idle)
    }

    func testAnswerBeatLapsesAndNeverFiresOnFutureOrNegativeAges() {
        XCTAssertEqual(compose(remote: RemoteActs(answeredAgo: 20)).phase, .idle)
        XCTAssertEqual(compose(remote: RemoteActs(answeredAgo: -1)).phase, .idle)
        XCTAssertEqual(compose(remote: RemoteActs()).phase, .idle)
    }

    func testContinuingWorkOutranksTheAnswerBeat() {
        let state = compose(remote: RemoteActs(thinking: true, answeredAgo: 2))
        XCTAssertEqual(state.phase, .thinking)   // another job is already running
    }

    func testFreshDotActivityAndThisBodyOwnActsBothOutrankRemoteSignals() {
        var dot = DotActivityState()
        let accepted = dot.receive([
            "type": "dot_activity", "protocol_version": 2,
            "endpoint_id": EchoBinding.endpointID,
            "sequence": 1,
            "observed_at_ms": Int(Date().timeIntervalSince1970 * 1000),
            "lease_ms": 8_000,
            "phase": "listening",
            "replay_available": false,
            "output_levels": [Double](),
        ])
        XCTAssertTrue(accepted)
        XCTAssertEqual(compose(remote: RemoteActs(thinking: true, answeredAgo: 1),
                               dot: dot).phase, .listening)
        // Actual local playback outranks unrelated global work.
        XCTAssertEqual(compose(remote: RemoteActs(thinking: true),
                               local: LocalActs(speaking: true)).phase, .speaking)
        XCTAssertEqual(compose(remote: RemoteActs(answeredAgo: 1),
                               local: LocalActs(speaking: true)).phase, .speaking)
    }

    func testRemoteThinkingNeverInventsSpeaking() {
        // Nothing settled recently: an active job must animate as thought,
        // never as speech - the words may never have been said yet.
        let state = compose(remote: RemoteActs(thinking: true))
        XCTAssertNotEqual(state.phase, .speaking)
    }
}

final class PlaybackTimelineTests: XCTestCase {
    func testLongDotPlaybackUsesFreshReceiptsNotAnswerAgeAndStopsImmediately() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var dot = DotActivityState()
        for second in [0, 5, 10, 20, 40] {
            let now = base.addingTimeInterval(Double(second))
            XCTAssertTrue(dot.receive(["type": "dot_activity", "protocol_version": 2,
                "endpoint_id": EchoBinding.endpointID, "sequence": second + 1,
                "observed_at_ms": Int(now.timeIntervalSince1970 * 1000), "lease_ms": 5000,
                "phase": "speaking", "replay_available": false, "output_levels": [0.2]], at: now))
            XCTAssertEqual(RingMirror.compose(dot: dot, presentation: nil,
                remote: RemoteActs(answeredAgo: Double(second)), local: LocalActs(), now: now).phase, .speaking)
        }
        let end = base.addingTimeInterval(41)
        XCTAssertTrue(dot.receive(["type": "dot_activity", "protocol_version": 2,
            "endpoint_id": EchoBinding.endpointID, "sequence": 99,
            "observed_at_ms": Int(end.timeIntervalSince1970 * 1000), "lease_ms": 5000,
            "phase": "idle", "replay_available": true, "output_levels": []], at: end))
        XCTAssertEqual(RingMirror.compose(dot: dot, presentation: nil,
            remote: RemoteActs(answeredAgo: 1), local: LocalActs(), now: end).phase, .idle)
    }
}
