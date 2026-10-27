import XCTest
import SwiftUI
@testable import KairoBody

final class ResponseActivityTests: XCTestCase {
    func testLocalFailureCannotHideADifferentSharedQuestion() {
        XCTAssertTrue(ResponseActivity.shouldShowShared(localJobID: "job_ipad", sharedJobID: "job_dot", localHasStatus: true))
        XCTAssertFalse(ResponseActivity.shouldShowShared(localJobID: "job_dot", sharedJobID: "job_dot", localHasStatus: true))
    }

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
                var job: [String: Any] = ["id": "job_fixture_dot_turn", "session_id": "fixture_dot_session",
                    "status": state, "prompt": "How do you feel?", "created_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-52)),
                    "metadata_json": ["client": "echomuse", "surface_kind": "dot"],
                    "events": [["type": "ToolStarted", "name": "inspect_self_state", "seq": 1]]]
                if state == "completed" { job["settled_status"] = "completed"; job["settled_text"] = "I feel attentive. I am here with you." }
                return (.fresh, ["schema_version": 1, "read_only": true, "turns": [job]], nil)
            })
        let suiteName = "ResponseSceneFixture.\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let proof = "kbp_" + String(repeating: "z", count: 40)
        let approvals = ApprovalClient(ownerProof: { proof }, request: { _, method, _ in
            XCTAssertEqual(method, "GET", "Scene capture never sends a decision")
            return ["approvals": [["job_id": "job_fixture_dot_turn", "request_id": 1,
                                   "description": "Inspect current internal state for this question", "scope": "tool", "truncated": false]]]
        })
        let model = AppModel(pairingClient: PairingClient(defaults: suite, readProof: { proof }),
                             appSettings: AppSettings(defaults: suite), pendingStore: PendingTurnStore(defaults: suite),
                             feed: feed, approvals: approvals)
        let oldVisibility = model.settings.echoTranscriptVisible
        defer { model.settings.echoTranscriptVisible = oldVisibility; feed.stop() }
        model.settings.echoTranscriptVisible = true
        feed.followAllSurfaces(foreground: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1280, height: 884)
        let host = UIHostingController(rootView: PresenceStageView()
            .environmentObject(model).preferredColorScheme(.dark))
        window.rootViewController = host
        window.windowLevel = .alert + 1
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for phase in ["running", "waiting_permission", "completed"] {
            state = phase
            await feed.refresh()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(feed.turns.last?.status, phase)
            if phase == "waiting_permission" {
                await approvals.refresh(jobID: "job_fixture_dot_turn")
                XCTAssertNotNil(approvals.approval)
            }
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let cg = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data
            let bytes = [UInt8](data)
            var lit = 0
            var offset = 0
            while offset + 2 < bytes.count {
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if red + green + blue > 150 { lit += 1 }
                offset += 4
            }
            XCTAssertGreaterThan(lit, 1000, "A blank scene is not visual evidence")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Dot-response-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(feed.processing)
        XCTAssertEqual(feed.turns.last?.answer, "I feel attentive. I am here with you.")
    }
}
