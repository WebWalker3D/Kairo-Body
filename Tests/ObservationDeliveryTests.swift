import XCTest
@testable import KairoBody

@MainActor
final class ObservationDeliveryTests: XCTestCase {
    // A stopped body restarts its sequence counter. A send from its previous
    // run may finish after the new request registered that same sequence.
    func testLateSendFailureCannotFinishReusedSequence() async throws {
        let delivery = ObservationDelivery()
        var finishOldSend: CheckedContinuation<Bool, Never>?
        let oldSendStarted = expectation(description: "old send started")
        let old = Task {
            try await delivery.deliver(sequence: 1) {
                await withCheckedContinuation { continuation in
                    finishOldSend = continuation
                    oldSendStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [oldSendStarted], timeout: 2)
        delivery.cancel()
        do { _ = try await old.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? ObservationDelivery.Failure, .cancelled) }

        let newSendStarted = expectation(description: "replacement send started")
        let replacement = Task {
            try await delivery.deliver(sequence: 1) {
                newSendStarted.fulfill()
                return true
            }
        }
        await fulfillment(of: [newSendStarted], timeout: 2)
        finishOldSend?.resume(returning: false)
        // Drain the old async send's completion on the main actor before the
        // new server receipt. An old failure must not consume the new waiter.
        for _ in 0..<20 { await Task.yield() }
        delivery.acknowledge(sequence: 1, observationID: "new-observation")
        let observation = try await replacement.value
        XCTAssertEqual(observation, "new-observation")
    }

    func testDuplicateReceiptOnlyCompletesOnce() async throws {
        let delivery = ObservationDelivery()
        let sent = expectation(description: "send")
        let task = Task {
            try await delivery.deliver(sequence: 5) { sent.fulfill(); return true }
        }
        await fulfillment(of: [sent], timeout: 2)
        delivery.acknowledge(sequence: 5, observationID: "first")
        delivery.acknowledge(sequence: 5, observationID: "duplicate")
        let observation = try await task.value
        XCTAssertEqual(observation, "first")
    }
}
