import XCTest
@testable import KairoBody

final class DotActivityTests: XCTestCase {
    private func message(sequence: Int = 1, phase: String = "thinking",
                         leaseMs: Int = 8_000, replay: Bool = false,
                         levels: [Double] = [], endpoint: String? = nil,
                         version: Int = 2) -> [String: Any] {
        [
            "type": "dot_activity",
            "protocol_version": version,
            "endpoint_id": endpoint ?? EchoBinding.endpointID,
            "sequence": sequence,
            "observed_at_ms": Int(Date().timeIntervalSince1970 * 1000),
            "lease_ms": leaseMs,
            "phase": phase,
            "replay_available": replay,
            "output_levels": levels,
        ]
    }

    func testBoundedIntegerRejectsBooleansAndRanges() {
        XCTAssertEqual(boundedInteger(NSNumber(value: 5)), 5)
        XCTAssertNil(boundedInteger(NSNumber(value: true)))
        XCTAssertNil(boundedInteger(NSNumber(value: 2.5)))
        XCTAssertNil(boundedInteger(NSNumber(value: -1), range: 0...10))
        XCTAssertNil(boundedInteger("7"))
        XCTAssertNil(boundedInteger(nil))
    }

    func testActivityAcceptedOnceThenWatermarked() {
        var state = DotActivityState()
        XCTAssertTrue(state.receive(message(sequence: 4)))
        XCTAssertEqual(state.activity?.phase, "thinking")
        XCTAssertEqual(state.activity?.sequence, 4)
        // A late re-send of a frame we already saw must not extend the lease.
        XCTAssertFalse(state.receive(message(sequence: 4)))
        XCTAssertFalse(state.receive(message(sequence: 3)))
        XCTAssertTrue(state.receive(message(sequence: 5)))
    }

    func testActivityRejectsWrongIdentityAndProtocol() {
        var state = DotActivityState()
        XCTAssertFalse(state.receive(message(version: 1)))
        XCTAssertFalse(state.receive(message(endpoint: "some-other-surface")))
        XCTAssertFalse(state.receive(["type": "dot_activity"]))
    }

    func testActivityRejectsUnboundedOrTypedLevels() {
        var state = DotActivityState()
        XCTAssertFalse(state.receive(message(levels: Array(repeating: 0.5, count: 33))))
        var tainted = message(levels: [0.1])
        tainted["output_levels"] = [NSNumber(value: 0.1), NSNumber(value: true)]
        XCTAssertFalse(state.receive(tainted))
        var over = message(levels: [1.2])
        over["output_levels"] = [1.2]
        XCTAssertFalse(state.receive(over))
        XCTAssertTrue(state.receive(message(levels: [0.0, 1.0])))
    }

    func testLeaseExpiresAndNewEpochResumesOnSameSocket() {
        var state = DotActivityState()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var frame = message(sequence: 9)
        frame["observed_at_ms"] = Int(base.timeIntervalSince1970 * 1000)
        frame["lease_ms"] = 1_000
        XCTAssertTrue(state.receive(frame, at: base))
        state.expire(at: base.addingTimeInterval(1.1))
        XCTAssertNil(state.activity)
        // After expiry the controller may resume with a new sequence epoch.
        var next = message(sequence: 1, phase: "listening")
        next["observed_at_ms"] = Int(base.addingTimeInterval(1.2).timeIntervalSince1970 * 1000)
        XCTAssertTrue(state.receive(next, at: base.addingTimeInterval(1.2)))
    }

    func testExpiredFrameNeverApplies() {
        var state = DotActivityState()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = message()
        stale["observed_at_ms"] = Int((base - 60).timeIntervalSince1970 * 1000)
        XCTAssertFalse(state.receive(stale, at: base))
    }

    func testReplayWindowIsBoundedToFreshIdleLease() {
        var state = DotActivityState()
        XCTAssertTrue(state.receive(message(phase: "idle", replay: true)))
        XCTAssertTrue(state.canReplay())
        var request = state.beginReplay()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?["type"] as? String, "dot_replay_last")
        XCTAssertEqual(request?["protocol_version"] as? Int, 2)
        XCTAssertNotNil(request?["request_id"])
        // In flight: no second request.
        XCTAssertNil(state.beginReplay())
        var result = ["type": "dot_replay_result", "protocol_version": 2,
                      "request_id": request!["request_id"]!, "status": "accepted"] as [String: Any]
        XCTAssertTrue(state.resolveReplay(result))
        XCTAssertEqual(state.replayStatus, "Replay accepted by the Dot.")
        // Wrong request id, unknown status and non-v2 frames are all ignored.
        _ = state.beginReplay()
        result["request_id"] = "unrelated"
        XCTAssertFalse(state.resolveReplay(result))
        state.timeoutReplay(state.pendingReplayID ?? "")
        XCTAssertNil(state.pendingReplayID)
        // Speaking now: replay is not offered while the Dot is busy.
        XCTAssertTrue(state.receive(message(sequence: 2, phase: "speaking", replay: true)))
        XCTAssertFalse(state.canReplay())
    }

    func testDisconnectClearsWatermarkAndReplayState() {
        var state = DotActivityState()
        XCTAssertTrue(state.receive(message(phase: "idle", replay: true)))
        _ = state.beginReplay()
        state.disconnect()
        XCTAssertNil(state.activity)
        XCTAssertNil(state.pendingReplayID)
        // A brand-new socket accepts sequence 0 again.
        XCTAssertTrue(state.receive(message(sequence: 0)))
    }
}

final class ConversationProjectionTests: XCTestCase {
    func testObservedTurnProjection() {
        let job: [String: Any] = [
            "id": "job_1", "session_id": "session_1", "status": "completed",
            "settled_status": "completed", "settled_text": "The answer",
            "prompt": "The question", "created_at": "2026-10-21T00:00:00Z",
            "metadata_json": ["surface_kind": "discord", "surface_instance_id": "kairo-bot"],
            "events": [
                ["type": "PromptProgress", "seq": 1, "processed": 100, "total": 400, "cached": 20],
                ["type": "ToolStarted", "seq": 2, "name": "web.search"],
                ["type": "ToolFinished", "seq": 3, "name": "web.search", "ok": false],
                ["type": "ModelRequestTiming", "seq": 4, "prompt_tokens": 400,
                 "cached_prompt_tokens": 20, "completion_tokens": 51, "tokens_per_second": 41.5],
            ],
        ]
        let turn = ConversationTurn(observedJob: job)
        XCTAssertNotNil(turn)
        XCTAssertEqual(turn?.answer, "The answer")
        XCTAssertEqual(turn?.progress?.processed, 100)
        XCTAssertEqual(turn?.usage.prompt, 400)
        XCTAssertEqual(turn?.toolActivity, ["Tool started · web.search", "Tool finished · web.search · failed"])
        XCTAssertTrue(turn?.sourceCaption.contains("discord") ?? false)
        XCTAssertFalse(turn?.active ?? true)
    }

    func testActiveTurnWithoutSettlement() {
        let turn = ConversationTurn(observedJob: ["id": "j", "session_id": "s", "status": "running"])
        XCTAssertEqual(turn?.active, true)
        XCTAssertEqual(turn?.answer, "")
    }

    func testDotTurnFilterRequiresExactDotMetadata() {
        let good: [String: Any] = [
            "id": "j1", "session_id": "echo-session", "status": "completed",
            "metadata_json": ["client": "echomuse", "surface_kind": "dot",
                              "surface_instance_id": EchoBinding.endpointID],
        ]
        XCTAssertNotNil(ConversationTurn(dotJob: good, sessionID: "echo-session"))
        let impostor = ["id": "j1", "session_id": "echo-session", "status": "completed",
                        "metadata_json": ["client": "echomuse", "surface_kind": "web"]] as [String: Any]
        XCTAssertNil(ConversationTurn(dotJob: impostor, sessionID: "echo-session"))
    }

    func testLiveStateSnapshotExcludesIdentityAndBeliefs() {
        let snapshot: [String: Any] = [
            "read_only": true,
            "live_state": [
                "available": true, "committed": true, "revision": 7,
                "dimensions": [
                    ["name": "identity", "fields": [["key": "name", "value": "Kairo"]]],
                    ["name": "beliefs", "fields": [["key": "x", "value": "y"]]],
                    ["name": "affect", "fields": [
                        ["key": "mood", "value": "calm"],
                        ["key": "num", "value": 0.4],
                        ["key": "null", "value": NSNull()],
                    ]],
                ],
            ],
        ]
        let state = LiveStateSnapshot(snapshot: snapshot)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.revision, 7)
        XCTAssertEqual(state?.fields, ["affect · mood: calm", "affect · num: 0.4"])
    }

    func testLiveStateSnapshotNeedsCommittedFrame() {
        XCTAssertNil(LiveStateSnapshot(snapshot: ["live_state": ["available": true, "committed": false, "revision": 1]]))
        XCTAssertNil(LiveStateSnapshot(snapshot: ["read_only": false, "live_state": ["available": true, "committed": true, "revision": 1]]))
    }
}
