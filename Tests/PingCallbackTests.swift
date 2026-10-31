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
}
