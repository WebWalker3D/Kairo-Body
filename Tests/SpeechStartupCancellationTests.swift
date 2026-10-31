import Foundation
import XCTest
@testable import KairoBody

private final class StartupCancellationSpeechHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var observer: (() -> Void)?

    static func observeRequests(_ observer: (() -> Void)?) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let observer = Self.observer
        Self.lock.unlock()
        observer?()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
        // Synthesis validates the envelope; this test must never reach playback.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("RIFF0000WAVE".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class SpeechStartupCancellationTests: XCTestCase {
    func testImmediateStopDoesNotStartSynthesisFromCancelledStartupTask() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StartupCancellationSpeechHTTP.self]
        let session = URLSession(configuration: config)
        let http = KairoHTTP(session: session, credentials: { ("fixture", "") })
        let speech = SpeechService(http: http, credentialAvailable: { true })
        defer {
            speech.stop()
            session.invalidateAndCancel()
            StartupCancellationSpeechHTTP.observeRequests(nil)
        }

        // Prove this exact client reaches the intercepted synthesis transport.
        let fixture = try await speech.synthesize("Transport fixture.")
        XCTAssertEqual(fixture, Data("RIFF0000WAVE".utf8))
        let synthesisAfterStop = expectation(description: "No synthesis starts after immediate stop")
        synthesisAfterStop.isInverted = true
        StartupCancellationSpeechHTTP.observeRequests { synthesisAfterStop.fulfill() }

        // No suspension between admission and stop: the startup task cannot have
        // executed yet, and must honor its cancellation before any HTTP work.
        XCTAssertTrue(speech.speak("This utterance was stopped before startup."))
        speech.stop()
        XCTAssertFalse(speech.isBusy)
        for _ in 0..<10 { await Task.yield() }
        await fulfillment(of: [synthesisAfterStop], timeout: 1)
        XCTAssertFalse(speech.isBusy)
        XCTAssertFalse(speech.isPlaying)
    }
}
