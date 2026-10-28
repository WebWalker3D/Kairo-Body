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
        // The established rule (testLocalActsOnlyFillSilence): server truth
        // outranks this body's own claims, so remote work outranks a local
        // act too - and a local conversation that just settled lands in the
        // remote feed anyway, so this body's speech still shows as the beat.
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
