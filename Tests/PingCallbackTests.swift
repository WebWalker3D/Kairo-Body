import XCTest
@testable import KairoBody

final class PingCallbackTests: XCTestCase {
    // Reproduces the device crash: a pong is followed by a cancellation error
    // from the same URLSession ping callback. Only the first outcome may win.
    func testSuccessThenErrorCompletesOnce() async throws {
        try await SessionBoundSocket.ping { completion in
            completion(nil)
            completion(URLError(.cancelled))
        }
    }

    func testErrorThenSuccessKeepsOriginalError() async {
        do {
            try await SessionBoundSocket.ping { completion in
                completion(URLError(.networkConnectionLost))
                completion(nil)
            }
            XCTFail("Expected the first callback's error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConcurrentDuplicateCallbacksCompleteOnce() async throws {
        try await SessionBoundSocket.ping { completion in
            DispatchQueue.concurrentPerform(iterations: 32) { _ in completion(nil) }
        }
    }

    func testCancellationWithoutCallbackFinishesAndIgnoresLateCallbacks() async {
        let registered = expectation(description: "ping callback registered")
        let callback = HeldPingCallback()
        let attempt = Task {
            try await SessionBoundSocket.ping { completion in
                callback.store(completion)
                registered.fulfill()
            }
        }
        await fulfillment(of: [registered], timeout: 2)
        attempt.cancel()
        let outcome = await StalledOperation.outcome(0.1) {
            try await attempt.value
        }

        // Always release the callback, even on the buggy implementation, so
        // the failed regression leaves no checked continuation suspended.
        callback.fire(nil)
        callback.fire(URLError(.cancelled))
        _ = try? await attempt.value

        switch outcome {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        case .value:
            XCTFail("A cancelled ping must throw CancellationError")
        case .timedOut:
            XCTFail("Cancellation must finish without waiting for a URLSession callback")
        }
    }
}

private final class HeldPingCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?

    func store(_ callback: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func fire(_ error: Error?) {
        lock.lock()
        let completion = callback
        lock.unlock()
        completion?(error)
    }
}
