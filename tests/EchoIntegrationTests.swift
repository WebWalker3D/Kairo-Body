import Foundation
import XCTest
@testable import KairoBody

final class EchoIntegrationTests: XCTestCase {
    private func activity(_ sequence: Any = 8, phase: String = "idle", levels: [Any] = []) -> [String: Any] {
        ["type": "dot_activity", "protocol_version": 2, "endpoint_id": "echomuse-rs03qr",
         "sequence": sequence, "phase": phase, "observed_at_ms": 100_000,
         "lease_ms": 2_000, "replay_available": true, "output_levels": levels]
    }

    func testActivityExpiresAndRejectsReorderedFramesEvenAfterExpiry() {
        var state = EchoActivityState()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(state.receive(activity(), at: now))
        XCTAssertTrue(state.canReplay(at: now))
        state.expire(at: now.addingTimeInterval(2))
        XCTAssertNil(state.activity)
        XCTAssertFalse(state.receive(activity(7), at: now.addingTimeInterval(3)))
        state.disconnect()
        XCTAssertTrue(state.receive(activity(0), at: now))
    }

    func testAfterALapsedLeaseAReconnectedControllerIsAcceptedOnTheSameSocket() {
        // The controller restarts its sequence when its Kairo feed recovers.
        // Old frames stay out because each carries its own expiry.
        var state = EchoActivityState()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(state.receive(activity(8), at: now))
        state.expire(at: now.addingTimeInterval(2))
        XCTAssertNil(state.activity)
        var fresh = activity(1, phase: "thinking")
        fresh["observed_at_ms"] = 105_000
        XCTAssertTrue(state.receive(fresh, at: now.addingTimeInterval(5)), "new epoch accepted")
        XCTAssertEqual(state.activity?.phase, "thinking")
        XCTAssertFalse(state.receive(activity(9), at: now.addingTimeInterval(5)), "stale frame still rejected")
    }

    func testRejectsOtherEndpointFractionalSequencesBooleansAndOversizedLevels() {
        let now = Date(timeIntervalSince1970: 100)
        var state = EchoActivityState()
        var wrong = activity()
        wrong["endpoint_id"] = "other-role"
        XCTAssertFalse(state.receive(wrong, at: now))
        XCTAssertFalse(state.receive(activity(true), at: now))
        XCTAssertFalse(state.receive(activity(1.5), at: now))
        XCTAssertFalse(state.receive(activity(levels: [true]), at: now))
        XCTAssertFalse(state.receive(activity(levels: Array(repeating: 0.5, count: 33)), at: now))
        XCTAssertFalse(state.receive(activity(levels: [Double.nan]), at: now))
    }

    func testReplayIsDisabledDuringEveryBusyPhaseAndResultsAreCorrelated() {
        let now = Date(timeIntervalSince1970: 100)
        for phase in ["speech_detected", "thinking", "speaking", "replaying", "disconnected"] {
            var state = EchoActivityState()
            XCTAssertTrue(state.receive(activity(phase: phase), at: now))
            XCTAssertFalse(state.canReplay(at: now))
        }
        var state = EchoActivityState()
        XCTAssertTrue(state.receive(activity(), at: now))
        let request = state.beginReplay(at: now, requestID: "request-1")
        XCTAssertEqual(request?["request_id"] as? String, "request-1")
        XCTAssertNil(request?["endpoint_id"])
        XCTAssertNil(state.beginReplay(at: now, requestID: "request-2"))
        XCTAssertFalse(state.resolveReplay(["request_id": "other", "status": "accepted"]))
        XCTAssertFalse(state.resolveReplay(["request_id": "request-1", "status": "unknown"]))
        XCTAssertTrue(state.resolveReplay(["request_id": "request-1", "status": "busy"]))
        XCTAssertNil(state.pendingReplayID)
    }

    func testWakeListeningAllowsReplayOnlyWithFreshAvailableAudio() {
        let now = Date(timeIntervalSince1970: 100)
        var state = EchoActivityState()
        XCTAssertTrue(state.receive(activity(phase: "listening"), at: now))
        XCTAssertTrue(state.canReplay(at: now))
        XCTAssertNotNil(state.beginReplay(at: now))
        XCTAssertFalse(state.canReplay(at: now))
        state.disconnect()
        var unavailable = activity(phase: "listening")
        unavailable["replay_available"] = false
        XCTAssertTrue(state.receive(unavailable, at: now))
        XCTAssertFalse(state.canReplay(at: now))
        state.disconnect()
        XCTAssertTrue(state.receive(activity(phase: "listening"), at: now))
        XCTAssertFalse(state.canReplay(at: now.addingTimeInterval(3)))
    }

    func testActivityRejectsNumericReplayFlagAndHugeTimestampWithoutOverflow() {
        let now = Date(timeIntervalSince1970: 100)
        var state = EchoActivityState()
        var payload = activity()
        payload["replay_available"] = 1
        XCTAssertFalse(state.receive(payload, at: now))
        payload = activity()
        payload["observed_at_ms"] = Int.max
        XCTAssertFalse(state.receive(payload, at: now))
    }

    func testBufferedActivityDoesNotGetANewLeaseOnReceipt() {
        var state = EchoActivityState()
        XCTAssertFalse(state.receive(activity(), at: Date(timeIntervalSince1970: 103)))
        XCTAssertNil(state.activity)
    }

    func testSpeakingWithoutLevelsStillReportsSpeakingAndUsesNoInventedMeter() {
        var state = EchoActivityState()
        XCTAssertTrue(state.receive(activity(phase: "speaking"), at: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(state.activity?.phase, "speaking")
        XCTAssertNil(state.activity?.outputIntensity)
    }

    func testTurnRequiresExactSessionAndAuthenticatedSurfaceMetadata() {
        let valid: [String: Any] = ["id": "job-dot", "session_id": "echo-session", "prompt": "Hello",
            "status": "completed", "settled_status": "completed", "settled_text": "Welcome",
            "metadata_json": ["client": "echomuse", "surface_kind": "dot", "surface_instance_id": "echomuse-rs03qr"]]
        XCTAssertEqual(EchoTurn(job: valid, sessionID: "echo-session")?.answer, "Welcome")
        XCTAssertNil(EchoTurn(job: valid, sessionID: "other-session"))
        var spoofed = valid
        spoofed["metadata_json"] = ["client": "ios"]
        XCTAssertNil(EchoTurn(job: spoofed, sessionID: "echo-session"))
        var unsettled = valid
        unsettled.removeValue(forKey: "settled_status")
        XCTAssertEqual(EchoTurn(job: unsettled, sessionID: "echo-session")?.answer, "")
    }

    func testUsageShowsOnlyReportedTokenCountsAndThroughput() {
        let events: [[String: Any]] = [["type": "MemoryContextPrepared", "seq": 7,
            "trace": ["prompt_tokens": 1200, "completion_tokens": 80,
                      "request_timings": [["tokens_per_second": 32.5]]]]]
        let usage = EchoTokenUsage(events: events)
        XCTAssertEqual(usage.prompt, 1200)
        XCTAssertEqual(usage.completion, 80)
        XCTAssertNil(usage.cached)
        XCTAssertEqual(usage.tokensPerSecond, 32.5)
        XCTAssertNil(EchoTokenUsage(events: []).prompt)
    }
}

private final class EchoStubProtocol: URLProtocol {
    static var paths: [String] = []
    static var fixture = "completed"
    static var ownerProof: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.ownerProof = request.value(forHTTPHeaderField: "X-Kairo-Device")
        Self.paths.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
        let json: String
        if request.url!.path == "/api/ipad/conversations" {
            json = #"{"schema_version":1,"read_only":true,"turns":[{"id":"job-discord","session_id":"discord-session","status":"running","metadata_json":{"source":"discord"},"events":[{"type":"PromptProgress","seq":1,"processed":80}]}],"live_state":{"available":true,"committed":true,"revision":43,"dimensions":[]}}"#
        } else if request.url!.path == "/api/sessions/echo-session/jobs" {
            json = """
            [{"id":"job-dot","session_id":"echo-session","prompt":"Hello Dot","status":"completed","settled_status":"completed","settled_text":"Hi from Kairo","metadata_json":{"client":"echomuse","surface_kind":"dot","surface_instance_id":"echomuse-rs03qr"}},
             {"id":"job-other","session_id":"other-session","prompt":"Other","status":"running","metadata_json":{"client":"echomuse","surface_kind":"dot","surface_instance_id":"echomuse-rs03qr"}}]
            """
        } else if request.url!.path == "/api/kairo-state" {
            json = #"{"read_only":true,"live_state":{"available":true,"committed":true,"revision":42,"dimensions":[]}}"#
        } else if request.url!.path.hasSuffix("/events") {
            json = #"[{"type":"PromptProgress","seq":1,"processed":45}]"#
        } else { json = "{}" }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.fixture == "forbidden" ? 403 : (Self.fixture == "offline" ? 503 : 200),
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class EchoConversationClientTests: XCTestCase {
    func testGlobalObserverUsesPairedGETWithoutDotBinding() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []; EchoStubProtocol.fixture = "completed"
        let proof = "kbp_" + String(repeating: "a", count: 40)
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { proof })
        await client.refreshAllSurfaces()
        XCTAssertEqual(EchoStubProtocol.paths, ["GET /api/ipad/conversations"])
        XCTAssertEqual(EchoStubProtocol.ownerProof, proof)
        XCTAssertEqual(client.turns.first?.sessionID, "discord-session")
        XCTAssertEqual(client.turns.first?.progress?.processed, 80)
        XCTAssertEqual(client.state?.revision, 43)
        client.stop()
        await client.refreshAllSurfaces()
        XCTAssertEqual(EchoStubProtocol.paths.count, 1)
    }

    func testRepeatedFollowDoesNotRestartTheObserverOrDropItsRead() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []; EchoStubProtocol.fixture = "completed"
        let proof = "kbp_" + String(repeating: "a", count: 40)
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { proof })
        client.followAllSurfaces(foreground: true)
        for _ in 0..<50 where client.turns.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(client.turns.isEmpty)
        for _ in 0..<5 { client.followAllSurfaces(foreground: true) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(EchoStubProtocol.paths.count, 1, "a redundant follow neither restarts nor re-reads")
        client.stop()
    }

    func testConnectionTroubleNamesItsCause() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []; EchoStubProtocol.fixture = "offline"
        let proof = "kbp_" + String(repeating: "a", count: 40)
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { proof })
        await client.refreshAllSurfaces()
        XCTAssertTrue(client.connectionTrouble?.contains("HTTP 503") == true, client.connectionTrouble ?? "nil")
        EchoStubProtocol.fixture = "completed"
    }

    func testRevokedOwnerAccessClearsVisibleConversationAndState() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []; EchoStubProtocol.fixture = "completed"
        let proof = "kbp_" + String(repeating: "b", count: 40)
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { proof })
        await client.refreshAllSurfaces()
        XCTAssertFalse(client.turns.isEmpty)
        EchoStubProtocol.fixture = "forbidden"
        await client.refreshAllSurfaces()
        XCTAssertTrue(client.turns.isEmpty)
        XCTAssertNil(client.state)
        XCTAssertNil(client.progress)
        XCTAssertNotNil(client.error)
        EchoStubProtocol.fixture = "completed"
    }

    func testLocallyForgottenOwnerProofClearsPreviouslyVisibleTurns() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []; EchoStubProtocol.fixture = "completed"
        var proof = "kbp_" + String(repeating: "c", count: 40)
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { proof })
        await client.refreshAllSurfaces()
        let readCount = EchoStubProtocol.paths.count
        proof = ""
        await client.refreshAllSurfaces()
        XCTAssertTrue(client.turns.isEmpty)
        XCTAssertNil(client.state)
        XCTAssertEqual(EchoStubProtocol.paths.count, readCount)
    }

    func testUnpairedGlobalObserverMakesNoRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
            agentToken: { "agent" }, ownerCredential: { "" })
        await client.refreshAllSurfaces()
        XCTAssertTrue(EchoStubProtocol.paths.isEmpty)
    }

    func testReadOnlyFollowRefreshesSettledStateOnceAndDoesNotSubmitOrSpeak() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []
        EchoStubProtocol.fixture = "completed"
        let client = EchoConversationClient(session: URLSession(configuration: configuration),
                                            agentToken: { "test-agent" })
        await client.refresh(sessionID: "echo-session")
        XCTAssertEqual(client.turns.map(\.id), ["job-dot"])
        XCTAssertEqual(client.turns.first?.answer, "Hi from Kairo")
        XCTAssertEqual(client.state?.revision, 42)
        XCTAssertEqual(client.progress?.processed, 45)
        await client.refresh(sessionID: "echo-session")
        XCTAssertEqual(EchoStubProtocol.paths.filter { $0 == "GET /api/kairo-state" }.count, 1)
        XCTAssertTrue(EchoStubProtocol.paths.allSatisfy { $0.hasPrefix("GET ") })
        EchoStubProtocol.fixture = "offline"
        await client.refresh(sessionID: "echo-session")
        XCTAssertEqual(client.turns.first?.answer, "Hi from Kairo")
        XCTAssertNotNil(client.error)
    }

    func testStoppedFollowerDoesNotIssueMoreReads() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []
        EchoStubProtocol.fixture = "completed"
        let client = EchoConversationClient(session: URLSession(configuration: configuration), agentToken: { "test" })
        await client.refresh(sessionID: "echo-session")
        let requests = EchoStubProtocol.paths.count
        client.stop()
        await client.refresh(sessionID: "echo-session")
        XCTAssertEqual(EchoStubProtocol.paths.count, requests)
        XCTAssertFalse(client.following)
        XCTAssertFalse(client.processing)
    }

    func testMissingOrInvalidBindingDoesNotReadAnotherConversation() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoStubProtocol.self]
        EchoStubProtocol.paths = []
        let client = EchoConversationClient(session: URLSession(configuration: configuration), agentToken: { "test" })
        await client.refresh(sessionID: "")
        await client.refresh(sessionID: "../other")
        XCTAssertTrue(EchoStubProtocol.paths.isEmpty)
        XCTAssertTrue(client.turns.isEmpty)
    }
}

final class AllSurfaceConversationTests: XCTestCase {
    func testObserverAttributesConcurrentTurnsAndKeepsProgressSeparate() {
        let discord: [String: Any] = ["id": "job-discord", "session_id": "discord-room", "status": "running",
            "metadata_json": ["source": "discord", "surface_kind": "discord", "surface_instance_id": "room-1"],
            "events": [["type": "PromptProgress", "seq": 2, "processed": 99],
                       ["type": "ToolStarted", "seq": 3, "name": "search"]]]
        let dot: [String: Any] = ["id": "job-dot", "session_id": "dot-room", "status": "running",
            "metadata_json": ["client": "echomuse", "surface_kind": "dot"],
            "events": [["type": "PromptProgress", "seq": 1, "processed": 12]]]
        let first = EchoTurn(observedJob: discord)
        let second = EchoTurn(observedJob: dot)
        XCTAssertEqual(first?.sessionID, "discord-room")
        XCTAssertTrue(first?.sourceCaption.contains("discord") == true)
        XCTAssertEqual(first?.progress?.processed, 99)
        XCTAssertEqual(second?.progress?.processed, 12)
        XCTAssertEqual(first?.toolActivity, ["Tool started · search"])
        XCTAssertNil(EchoTurn(job: discord, sessionID: "discord-room"))
    }

    func testObserverDoesNotPresentUnacceptedDraftOrInvalidIdentity() {
        let job: [String: Any] = ["id": "job-private", "session_id": "private-session", "status": "running",
            "settled_text": "unaccepted draft", "events": [["type": "CandidateGenerated", "text": "draft"]]]
        XCTAssertEqual(EchoTurn(observedJob: job)?.answer, "")
        XCTAssertNil(EchoTurn(observedJob: ["id": "../invalid", "session_id": "private-session"]))
    }
}
