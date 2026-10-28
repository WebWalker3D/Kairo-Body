import XCTest
@testable import KairoBody

private final class SilentSpeechHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
        // A real short PCM file exercises AVAudioPlayer; only synthesis HTTP is replaced.
        let samples = 8_000
        var wav = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        u32(UInt32(36 + samples * 2)); wav.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        wav.append(Data("data".utf8)); u32(UInt32(samples * 2))
        wav.append(Data(repeating: 0, count: samples * 2))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: wav)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpeechPlaybackTests: XCTestCase {
    func testSpeechVisualBeginsAtPlayerStartAndEndsAtRealCompletionOrStop() async throws {
        let previous = KeychainStore.read(service: AppConfig.keychainService, account: AppConfig.agentAccount)
        try KeychainStore.setChecked("synthetic-speech-fixture", service: AppConfig.keychainService,
                                    account: AppConfig.agentAccount)
        defer { KeychainStore.set(previous ?? "", service: AppConfig.keychainService, account: AppConfig.agentAccount) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SilentSpeechHTTP.self]
        let http = KairoHTTP(session: URLSession(configuration: config), credentials: { ("fixture", "") })
        let speech = SpeechService(http: http)
        defer { speech.stop() }
        let started = expectation(description: "actual player started")
        let completed = expectation(description: "actual player finished")
        XCTAssertTrue(speech.speak("A silent fixture.", onEvent: { phase, detail in
            if phase == .started {
                XCTAssertTrue(speech.isPlaying)
                started.fulfill()
            } else if phase == .completed {
                XCTAssertFalse(speech.isPlaying)
                completed.fulfill()
            } else if phase == .failed { XCTFail(detail) }
        }))
        XCTAssertTrue(speech.isBusy)
        XCTAssertFalse(speech.isPlaying, "Synthesis admission cannot claim speech")
        await fulfillment(of: [started, completed], timeout: 10, enforceOrder: true)
        XCTAssertFalse(speech.isPlaying)
        XCTAssertFalse(speech.isBusy)
        let replayStarted = expectation(description: "replay starts")
        XCTAssertTrue(speech.speak("Replay.", onEvent: { phase, _ in
            if phase == .started { replayStarted.fulfill() }
        }))
        await fulfillment(of: [replayStarted], timeout: 10)
        speech.stop()
        XCTAssertFalse(speech.isPlaying)
        XCTAssertFalse(speech.isBusy)
    }
}
