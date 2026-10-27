import XCTest
import SwiftUI
@testable import KairoBody

final class ResponseActivityTests: XCTestCase {
    func testPermissionWaitAndFailureNeverClaimOngoingThinking() {
        XCTAssertEqual(ResponseActivity.headline(status: "waiting_permission", settled: nil), "Approval needed")
        XCTAssertEqual(ResponseActivity.headline(status: "running", settled: "failed"), "Response failed")
        XCTAssertEqual(ResponseActivity.headline(status: "running", settled: "completed"), "Answer ready")
        XCTAssertTrue(ResponseActivity.detail(status: "waiting_permission", progress: nil, tools: []).contains("paused"))
    }
    func testUnknownTokenTotalDoesNotDisplayZeroOrInventPercentage() {
        let progress = PromptTokenProgress(event: ["type": "PromptProgress", "processed": 123])!
        XCTAssertEqual(ResponseActivity.detail(status: "running", progress: progress, tools: []), "Reading context · 123 tokens")
        XCTAssertEqual(ResponseActivity.elapsed(since: Date(timeIntervalSince1970: 60), now: Date(timeIntervalSince1970: 50)), "0s")
    }
}

@MainActor
final class ResponseSceneTests: XCTestCase {
    func testDotWorkPermissionAndAnswerOnActualStage() async throws {
        var state = "running"
        let feed = TranscriptFeedClient(ownerProof: { "kbp_" + String(repeating: "z", count: 40) },
            agentAvailable: { true }, read: { _, _ in
                var job: [String: Any] = ["id": "fixture_dot_turn", "session_id": "fixture_dot_session",
                    "status": state, "prompt": "How do you feel?", "created_at": "2026-10-27T00:37:10Z",
                    "metadata_json": ["client": "echomuse", "surface_kind": "dot"],
                    "events": [["type": "ToolStarted", "name": "inspect_self_state", "seq": 1]]]
                if state == "completed" { job["settled_status"] = "completed"; job["settled_text"] = "I feel attentive. I am here with you." }
                return (.fresh, ["schema_version": 1, "read_only": true, "turns": [job]], nil)
            })
        let model = AppModel(feed: feed)
        let oldVisibility = model.settings.echoTranscriptVisible
        defer { model.settings.echoTranscriptVisible = oldVisibility; feed.stop() }
        model.settings.echoTranscriptVisible = true
        feed.followAllSurfaces(foreground: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 884))
        window.rootViewController = UIHostingController(rootView: PresenceStageView()
            .environmentObject(model).environment(\.accessibilityReduceMotion, true).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for phase in ["running", "waiting_permission", "completed"] {
            state = phase
            await feed.refresh()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(feed.turns.last?.status, phase)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Dot-response-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(feed.processing)
        XCTAssertEqual(feed.turns.last?.answer, "I feel attentive. I am here with you.")
    }
}
