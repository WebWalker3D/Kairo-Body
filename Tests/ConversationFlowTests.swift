import XCTest
@testable import KairoBody

/// Only the HTTP boundary is replaced. The model, voice handoff, request
/// tracker and cancellation/recovery code remain the real application clients.
private final class ConversationHTTPFixture: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, value) = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class ConversationFlowTests: XCTestCase {
    private func http() -> KairoHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConversationHTTPFixture.self]
        return KairoHTTP(session: URLSession(configuration: config), credentials: { ("fixture-agent", "fixture-owner") })
    }

    func testRepeatedVoiceRequestsRearmAfterSuccessAndFailure() async throws {
        var fail = false
        var submissions = 0
        ConversationHTTPFixture.respond = { request in
            let path = request.url!.path
            if path == "/api/ipad/destinations" { return (200, ["destinations": []]) }
            if path.hasSuffix("/jobs") {
                submissions += 1
                return fail ? (403, [:]) : (200, ["id": "job_voice_fixture"])
            }
            if path == "/api/jobs/job_voice_fixture" {
                return (200, ["status": "completed", "settled_status": "completed", "settled_text": "A real client fixture answer",
                              "metadata_json": ["surface_output_target": "silent"]])
            }
            XCTFail("Unexpected HTTP request: \(path)")
            return (500, [:])
        }
        let suiteName = "VoiceFlowFixture.\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let model = AppModel(http: http(), appSettings: AppSettings(defaults: suite),
                             pendingStore: PendingTurnStore(defaults: suite))
        let previousFollow = model.settings.followEcho
        let previousSession = model.settings.sharedSessionID
        defer {
            model.settings.followEcho = previousFollow
            model.settings.sharedSessionID = previousSession
            ConversationHTTPFixture.respond = nil
        }
        model.settings.followEcho = false
        model.settings.sharedSessionID = "session_voice_fixture"
        model.wireVoiceCallbacks()
        for shouldFail in [false, true, false] {
            fail = shouldFail
            model.voice.submitCapturedCommand("Fixture question")
            XCTAssertTrue(model.voice.awaitingResponse)
            let deadline = Date().addingTimeInterval(3)
            while model.voice.awaitingResponse && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.voice.awaitingResponse, "Completion and failure must both rearm voice input")
            XCTAssertFalse(model.conversation.isSending)
            if shouldFail { XCTAssertNotNil(model.conversation.error) }
            else { XCTAssertEqual(model.conversation.reply, "A real client fixture answer") }
        }
        XCTAssertEqual(submissions, 3)
        model.speech.onPlaybackStateChange?(true)
        XCTAssertTrue(model.voice.awaitingResponse, "Playback must block capture")
        model.speech.onPlaybackStateChange?(false)
        XCTAssertFalse(model.voice.awaitingResponse)
    }

    func testFailedCancellationRetainsOriginalJobForReconciliation() async {
        let name = "CancelFixture.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); ConversationHTTPFixture.respond = nil }
        let store = PendingTurnStore(defaults: defaults)
        var turn = PendingTurn.new(sessionID: "session_fixture", text: "Original", attachmentIDs: [], outputDestination: "silent")
        turn.jobID = "job_original"; store.save(turn)
        ConversationHTTPFixture.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/jobs/job_original/cancel")
            return (503, [:])
        }
        let client = ConversationClient(settings: AppSettings(defaults: defaults), speech: SpeechService(),
                                        http: http(), pendingStore: store)
        await client.stopResponse()
        XCTAssertEqual(store.load()?.jobID, "job_original")
        XCTAssertEqual(store.load()?.cancelRequested, true)
        XCTAssertEqual(client.pendingRecovery, .stillWorking(jobID: "job_original"))
        XCTAssertNotNil(client.error)
    }
}
