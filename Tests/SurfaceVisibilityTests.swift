import XCTest
import SwiftUI
import UIKit
@testable import KairoBody

@MainActor
final class SurfaceVisibilityTests: XCTestCase {
    func testExpressionCommandUpdatesRingWithoutOpeningAnswerPanel() async {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let state = BodyClient.DisplayState(state: "curious", headline: "Kairo", detail: "Current expression: curious")
        let delivery = Task { await model.body.applyDisplay(state) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.stageDisplayText, "Expression updates belong in the ring, not the answer panel")
        XCTAssertEqual(model.currentRingState().mood, "curious")
        delivery.cancel()
        _ = await delivery.value
    }

    func testMountedRingReceiptsExpressionChangesAndRendersThem() async throws {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PresenceStageView().environment(model).preferredColorScheme(.dark))
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (mood, size) in [("calm", CGSize(width: 884, height: 1280)),
                             ("curious", CGSize(width: 1280, height: 884))] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            let applied = await model.body.applyDisplay(.init(state: mood, headline: "Kairo", detail: "Current expression: \(mood)"))
            XCTAssertTrue(applied, "A mounted center ring must receipt the expression")
            XCTAssertNil(model.stageDisplayText)
            XCTAssertEqual(model.currentRingState().mood, mood)
            XCTAssertEqual(model.renderState().moodPrimary, ExpressionPalette.forState(mood).rgb.primary)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Ring-expression-\(mood)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testExpressionDoesNotClaimDisplayWhenStageIsHidden() async {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        model.destination = .conversation
        let applied = await model.body.applyDisplay(.init(state: "joyful", headline: "Kairo", detail: "Current expression: joyful"))
        XCTAssertFalse(applied)
        XCTAssertNil(model.stageDisplayText)
        model.destination = .stage
        model.systemsOpen = true
        let covered = await model.body.applyDisplay(.init(state: "curious", headline: "Kairo", detail: ""))
        XCTAssertFalse(covered)
        XCTAssertNil(model.stageDisplayText)
    }

    func testRestoredSocketExpressionAlsoDrivesTheRing() {
        let model = AppModel(surfaceUnobscured: { true })
        model.body.display = .init(state: "playful", headline: "Kairo", detail: "Current expression: playful")
        XCTAssertEqual(model.currentRingState().mood, "playful")
        model.body.display = .init(state: "resolute", headline: "Kairo", detail: "")
        XCTAssertEqual(model.currentRingState().mood, "resolute")
        XCTAssertNil(model.stageDisplayText)
    }

    func testUnmountedRingCannotReceiptAnExpression() async {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let applied = await model.body.applyDisplay(.init(state: "calm", headline: "Kairo", detail: "Current expression: calm"))
        XCTAssertFalse(applied, "Setting ring data alone is not visible delivery")
        XCTAssertNil(model.stageDisplayText)
    }

    func testCoveringRingInvalidatesPendingDisplayReceipt() async throws {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let delivery = Task { await model.body.applyDisplay(.init(state: "calm", headline: "Kairo", detail: "")) }
        for _ in 0..<40 {
            if model.ringDisplayID != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let id = try XCTUnwrap(model.ringDisplayID)
        model.systemsOpen = true
        model.acknowledgeRingDisplay(id: id, expression: "calm")
        let applied = await delivery.value
        XCTAssertFalse(applied)
    }

    func testRepeatedExpressionRequiresItsOwnMountedReceipt() async throws {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let state = BodyClient.DisplayState(state: "calm", headline: "Kairo", detail: "")
        let first = Task { await model.body.applyDisplay(state) }
        for _ in 0..<40 {
            if model.ringDisplayID != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let firstID = try XCTUnwrap(model.ringDisplayID)
        let second = Task { await model.body.applyDisplay(state) }
        for _ in 0..<40 {
            if model.ringDisplayID != firstID { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let secondID = try XCTUnwrap(model.ringDisplayID)
        XCTAssertNotEqual(firstID, secondID)
        model.acknowledgeRingDisplay(id: firstID, expression: "calm")
        let firstApplied = await first.value
        XCTAssertFalse(firstApplied)
        XCTAssertEqual(model.ringDisplayID, secondID)
        model.acknowledgeRingDisplay(id: secondID, expression: "calm")
        let secondApplied = await second.value
        XCTAssertTrue(secondApplied)
    }

    func testWrittenSensoryDisplayStillUsesAnswerPanel() async {
        let model = AppModel(surfaceUnobscured: { true })
        model.setSurfaceVisibility(true)
        let display = BodyClient.DisplayState(state: "curious", headline: "Look outside", detail: "The sky is clearing.")
        let delivery = Task { await model.body.applyDisplay(display) }
        for _ in 0..<40 {
            if model.stageDisplayText != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.stageDisplayText, "Look outside\nCurious\nThe sky is clearing.")
        model.acknowledgeStageDisplay(display.surfaceText)
        let applied = await delivery.value
        XCTAssertTrue(applied)
    }

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
