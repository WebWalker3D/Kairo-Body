import XCTest
@testable import KairoBody

@MainActor
final class BodyCommandTests: XCTestCase {
    func testRearCameraIsRejectedBeforeHardwareAccess() async {
        do { _ = try await CameraCaptureService().capture(position: .back); XCTFail("Rear is blocked") }
        catch { XCTAssertEqual(error as? CameraCaptureService.CameraError, .blockedByBody) }
    }

    func testFailedSendCannotAcknowledgeSuccessfulIngestion() async {
        let delivery = ObservationDelivery()
        do {
            _ = try await delivery.deliver(sequence: 1, send: { false })
            XCTFail("Failed upload cannot succeed")
        } catch { XCTAssertEqual(error as? ObservationDelivery.Failure, .sendFailed) }
    }

    func testOnlyMatchingServerReceiptCompletesDelivery() async throws {
        let delivery = ObservationDelivery()
        let pending = Task { try await delivery.deliver(sequence: 2, send: { true }) }
        await Task.yield()
        delivery.acknowledge(sequence: 1, observationID: "wrong")
        delivery.acknowledge(sequence: 2, observationID: "actual-server-observation")
        let result = try await pending.value
        XCTAssertEqual(result, "actual-server-observation")
    }
}
