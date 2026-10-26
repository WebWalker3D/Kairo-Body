import XCTest
@testable import KairoBody

@MainActor
final class SurfaceVisibilityTests: XCTestCase {
    func testModalObscurationRejectsOutputBeforePublishingText() async {
        let model = AppModel(surfaceUnobscured: { false })
        model.setSurfaceVisibility(true)
        let applied = await model.surfaceDelivery.display("Hidden behind a photo picker")
        XCTAssertFalse(applied)
        XCTAssertNil(model.stageDisplayText)
    }

    func testOwnerRemovalInvalidatesAnInflightClaim() async {
        var claim: CheckedContinuation<[String: Any], Error>?
        let claimed = expectation(description: "claim started")
        var results: [String] = []
        let model = AppModel(deliveryRequest: { path, body in
            if path.hasSuffix("/claim") {
                return try await withCheckedThrowingContinuation { continuation in
                    claim = continuation; claimed.fulfill()
                }
            }
            if path.hasSuffix("/result") { results.append(body?["status"] as? String ?? "") }
            return [:]
        }, surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let delivery = Task { await model.surfaceDelivery.deliver(jobID: "job_unpair", destination: "ipad_display") }
        await fulfillment(of: [claimed], timeout: 2)
        model.pairingChanged() // this fixture is unpaired; invalidates any old claim
        claim?.resume(returning: ["job_id": "job_unpair", "target": "ipad_display", "kind": "text", "text": "Owner answer"])
        await delivery.value
        XCTAssertNil(model.stageDisplayText)
        XCTAssertEqual(results, ["failed"])
    }

    func testMountedDisplayAcknowledgesOnlyTheCurrentPresentation() async {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let delivery = Task { await model.surfaceDelivery.display("Visible answer") }
        for _ in 0..<40 {
            if model.stageDisplayText != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.acknowledgeStageDisplay("Visible answer")
        let applied = await delivery.value
        XCTAssertTrue(applied)
        model.clearStageDisplay()
        XCTAssertNil(model.stageDisplayText)
    }

    func testStateOnlySensoryCommandHasVisibleContent() {
        let state = BodyClient.DisplayState(state: "curious", headline: "Kairo", detail: "")
        XCTAssertTrue(state.surfaceText.localizedCaseInsensitiveContains("curious"))
    }

    func testRetainedActiveTurnIsNotCurrentWorkWhenFeedIsStale() {
        XCTAssertFalse(PresencePreviewPolicy.isWorking(active: true, feedFresh: false))
        XCTAssertTrue(PresencePreviewPolicy.isWorking(active: true, feedFresh: true))
    }
}
