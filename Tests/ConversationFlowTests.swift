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

extension ConversationFlowTests {
    func testInvitationAcceptanceReservesItsConversationHandoff() async throws {
        let suiteName = "InvitationHandoff.\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName); ConversationHTTPFixture.respond = nil }
        let accepting = expectation(description: "acceptance in flight")
        var release: CheckedContinuation<[String: Any], Never>?
        let invitation = InvitationClient(ownerProof: { "kbp_" + String(repeating: "v", count: 40) }, request: { _, method, body in
            if method == "GET" {
                return ["invitation": ["id": "1", "text": "Continue our earlier thought", "origin": "kairo",
                                       "source_event_id": 7, "session_id": "source_session",
                                       "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))]]
            }
            if body?["status"] as? String == "answered" {
                return await withCheckedContinuation { release = $0; accepting.fulfill() }
            }
            return ["accepted": true]
        })
        var postedPaths: [String] = []
        ConversationHTTPFixture.respond = { request in
            postedPaths.append(request.url!.path)
            return (403, [:])
        }
        let model = AppModel(http: http(), appSettings: AppSettings(defaults: suite),
                             pendingStore: PendingTurnStore(defaults: suite), invitations: invitation)
        model.settings.followEcho = false
        model.settings.sharedSessionID = "session_local"
        model.conversation.prepareOutput = nil
        await invitation.refresh(foreground: true)
        await invitation.markDisplayed()
        let first = Task { await model.acceptInvitationIntoConversation() }
        await fulfillment(of: [accepting], timeout: 2)
        let accepted = await model.conversation.send("Intervening request")
        XCTAssertFalse(accepted, "Acceptance must reserve the handoff before awaiting its receipt")
        release?.resume(returning: ["accepted": true])
        await first.value
        XCTAssertEqual(postedPaths, ["/api/sessions/source_session/jobs"])
    }
}

extension ConversationFlowTests {
    func testJSONNullSettlementStillReportsPermissionAndOptionalProgress() async throws {
        let suiteName = "PermissionFlow.\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName); ConversationHTTPFixture.respond = nil }
        var reads = 0
        var eventReads = 0
        ConversationHTTPFixture.respond = { request -> (Int, Any) in
            if request.httpMethod == "POST" { return (200, ["id": "job_permission"]) }
            if request.url!.path.hasSuffix("/events") {
                eventReads += 1
                let events: [[String: Any]] = [["type": "PromptProgress", "processed": 123, "seq": 1]]
                return (200, events)
            }
            reads += 1
            if reads == 1 {
                let job: [String: Any] = ["status": "waiting_permission", "settled_status": NSNull()]
                return (200, job)
            }
            return (200, ["status": "completed", "settled_status": "completed", "settled_text": "After explicit approval"])
        }
        let settings = AppSettings(defaults: suite)
        settings.followEcho = false; settings.sharedSessionID = "session_fixture"
        let client = ConversationClient(settings: settings, speech: SpeechService(), http: http(),
                                       pendingStore: PendingTurnStore(defaults: suite))
        client.outputDestination = .silent
        var observed: [String] = []
        client.onObservedStatusChange = { observed.append($0) }
        await client.send("A question")
        XCTAssertTrue(observed.contains("waiting_permission"))
        XCTAssertEqual(eventReads, 1, "Null settlement is active; completed answers skip optional event reads")
        XCTAssertEqual(client.promptProgress?.processed, 123)
        XCTAssertEqual(client.reply, "After explicit approval")
    }
}
