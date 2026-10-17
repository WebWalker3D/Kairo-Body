import Foundation
import XCTest
@testable import KairoBody

private final class VoiceStubProtocol: URLProtocol {
    static var path = ""
    static var authorization = ""
    static var requestedText = ""
    static var holdResponse = false
    static var onRequest: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if Self.holdResponse { Self.onRequest?(); return }
        Self.path = request.url?.path ?? ""
        Self.authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        var payload = request.httpBody ?? Data()
        if payload.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                payload.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        Self.requestedText = body?["text"] as? String ?? ""
        let audio = Data("RIFF1234WAVEaudio".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: audio)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testBusySpeechCannotBeImplicitlyReplaced() async throws {
        let started = expectation(description: "first synthesis")
        VoiceStubProtocol.holdResponse = true
        VoiceStubProtocol.onRequest = { started.fulfill() }
        defer { VoiceStubProtocol.holdResponse = false; VoiceStubProtocol.onRequest = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        let service = SpeechService(settings: AppSettings(), session: URLSession(configuration: configuration),
            agentToken: { "agent-test" })
        var phases: [ActionPhase] = []
        XCTAssertTrue(service.speak("First", onEvent: { phase, _ in phases.append(phase) }))
        await fulfillment(of: [started], timeout: 5)
        XCTAssertFalse(service.speak("Second"))
        XCTAssertTrue(service.isBusy)
        XCTAssertEqual(phases, [])
        service.stop()
    }

    func testStopInvalidatesPendingAudioAndLateNetworkFailure() async throws {
        let started = expectation(description: "synthesis requested")
        VoiceStubProtocol.holdResponse = true
        VoiceStubProtocol.onRequest = { started.fulfill() }
        defer { VoiceStubProtocol.holdResponse = false; VoiceStubProtocol.onRequest = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        let service = SpeechService(settings: AppSettings(), session: URLSession(configuration: configuration),
            agentToken: { "agent-test" })
        var failures = 0
        var phases: [ActionPhase] = []
        XCTAssertTrue(service.speak("Hello", onEvent: { phase, _ in phases.append(phase) }, onFailure: { _ in failures += 1 }))
        await fulfillment(of: [started], timeout: 5)
        service.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isBusy)
        XCTAssertEqual(phases, [.stopped])
        XCTAssertEqual(failures, 0)
    }

    func testFetchesSelectedVoiceWithAgentCredential() async throws {
        let settings = AppSettings()
        let previous = settings.agentURL
        defer { settings.agentURL = previous }
        settings.agentURL = "https://connect.kairo.icu"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        let service = SpeechService(settings: settings,
                                    session: URLSession(configuration: configuration),
                                    agentToken: { "agent-only-token" })

        let audio = try await service.fetchChunk("Hello Blaine.")

        XCTAssertEqual(audio, Data("RIFF1234WAVEaudio".utf8))
        XCTAssertEqual(VoiceStubProtocol.path, "/api/speech/synthesis")
        XCTAssertEqual(VoiceStubProtocol.authorization, "Bearer agent-only-token")
        XCTAssertEqual(VoiceStubProtocol.requestedText, "Hello Blaine.")
    }

    func testSpeechChunksKeepWholeReplyWithinServerLimit() {
        let text = String(repeating: "a word ", count: 250)
        let chunks = SpeechService.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 700 })
        XCTAssertEqual(chunks.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }),
                       text.split(whereSeparator: { $0.isWhitespace }))
    }

    func testFirstSentenceIsItsOwnEarlyVoiceRequest() {
        let chunks = SpeechService.chunks(
            "Hello Blaine. I can see the room ahead of me. The display is bright now.")
        XCTAssertEqual(chunks.first, "Hello Blaine.")
        XCTAssertEqual(chunks.dropFirst().joined(separator: " "),
                       "I can see the room ahead of me. The display is bright now.")
    }
}
