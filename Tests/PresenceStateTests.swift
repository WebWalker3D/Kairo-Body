import XCTest
@testable import KairoBody

final class PresenceStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rest(_ state: String = "sleeping", age: TimeInterval = 0) -> [String: Any] {
        ["schema_version": 1, "read_only": true,
         "observed_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)),
         "memory": ["available": true, "read_only": true,
                    "foreground_lease_acquired": false, "semantic_recall_performed": false,
                    "temporal": ["rest_state": ["current_state": state,
                       "dream_narrative": "Private text must never enter the projection"]]]]
    }

    func testRestProjectionRequiresFreshReadOnlyEvidence() {
        XCTAssertEqual(RestProjection(object: rest(), now: now)?.state, .sleeping)
        XCTAssertEqual(RestProjection(object: rest("awake"), now: now)?.state, .awake)
        XCTAssertEqual(RestProjection(object: rest("dreaming"), now: now)?.state, .dreaming)
        XCTAssertNil(RestProjection(object: rest("unknown"), now: now))
        XCTAssertNil(RestProjection(object: rest(age: 61), now: now))
        XCTAssertNil(RestProjection(object: rest(age: -6), now: now))
        var altered = rest(); altered["read_only"] = false
        XCTAssertNil(RestProjection(object: altered, now: now))
        altered = rest(); altered["memory"] = ["available": false]
        XCTAssertNil(RestProjection(object: altered, now: now))
        XCTAssertFalse(RestProjection(object: rest(), now: now)!.isFresh(at: now.addingTimeInterval(61)))
    }

    func testOutputSelectionHonorsSettledServerTargetWithoutGuessing() {
        func job(_ target: String?, status: String = "completed") -> [String: Any] {
            ["settled_status": status, "metadata_json": target.map { ["surface_output_target": $0] } ?? [:]]
        }
        XCTAssertEqual(SurfaceOutputPolicy.target(job: job("ipad_display"), requested: "kairo"), "ipad_display")
        XCTAssertEqual(SurfaceOutputPolicy.target(job: job("ipad_speech"), requested: "kairo"), "ipad_speech")
        for target in ["silent", "dot", "discord", "unknown"] {
            XCTAssertNil(SurfaceOutputPolicy.target(job: job(target), requested: "kairo"))
        }
        XCTAssertNil(SurfaceOutputPolicy.target(job: job(nil), requested: "kairo"))
        XCTAssertNil(SurfaceOutputPolicy.target(job: job("ipad_display", status: "failed"), requested: "kairo"))
        XCTAssertNil(SurfaceOutputPolicy.target(job: job("ipad_display"), requested: "silent"))
        XCTAssertEqual(SurfaceOutputPolicy.target(job: job(nil), requested: "ipad_speech"), "ipad_speech")
    }
}

extension PresenceStateTests {
    func testCapabilityAvailabilityIsNotInventedFromBooleanOrPrerequisites() {
        let fixture: [String: Any] = ["id": "cap_1", "name": "Vision", "enabled": 0,
                                    "prerequisites_json": ["Camera permission", 42, ["nested": true]]]
        let capability = SystemCapability(object: fixture)
        XCTAssertEqual(capability?.enabled, false)
        XCTAssertEqual(capability?.prerequisites, ["Camera permission"])
        var malformed = fixture; malformed["enabled"] = true
        XCTAssertNil(SystemCapability(object: malformed))
    }
}

final class ExplicitTextSurfaceTests: XCTestCase {
    func testTextHerePersistsDisplayTargetAndUsesClaimedDeliveryPolicy() throws {
        let target = ConversationClient.OutputDestination.textOnly.surfaceTarget
        let turn = PendingTurn.new(sessionID: "test-session", text: "Show this here",
                                   attachmentIDs: [], outputDestination: target)
        XCTAssertEqual(turn.outputDestination, "ipad_display")
        let completed: [String: Any] = ["settled_status": "completed", "settled_text": "An answer"]
        XCTAssertEqual(SurfaceOutputPolicy.target(job: completed, requested: turn.outputDestination), "ipad_display")
        // A server-selected remote surface still wins; do not duplicate output.
        let remote: [String: Any] = ["settled_status": "completed", "metadata_json": ["surface_output_target": "dot"]]
        XCTAssertNil(SurfaceOutputPolicy.target(job: remote, requested: turn.outputDestination))
        XCTAssertNil(SurfaceOutputPolicy.target(job: completed, requested: ConversationClient.OutputDestination.silent.surfaceTarget))
    }
}
