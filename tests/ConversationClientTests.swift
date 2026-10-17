import Foundation
import XCTest
@testable import KairoBody

private final class ConversationStubProtocol: URLProtocol {
    static var received: [(String, String)] = []
    static var pendingContactResponses = 0
    static var settledDestination: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.received.append((request.url?.path ?? "", authorization))
        let json: String
        if request.url?.path == "/api/platform" {
            json = #"{"active_jobs":1,"queued_jobs":0,"running_jobs":1}"#
        } else if request.url?.path == "/api/sessions/echo-session" {
            json = #"{"id":"echo-session","workspace_id":"workspace-echo","status":"active"}"#
        } else if request.url?.path.hasSuffix("/events") == true {
            json = #"[{"type":"PromptProgress","processed":4239,"total":15207,"cached":4000,"seq":8}]"#
        } else if request.httpMethod == "POST" {
            json = #"{"id":"job-1"}"#
        } else if let target = Self.settledDestination {
            json = "{\"settled_status\":\"completed\",\"settled_text\":\"Hello from Kairo.\",\"metadata_json\":{\"surface_output_target\":\"\(target)\"}}"
        } else {
            json = #"{"settled_status":"completed","settled_text":"Hello from Kairo."}"#
        }
        let pendingContact = request.url?.path.hasSuffix("/body-reflex") == true &&
            Self.pendingContactResponses > 0
        if pendingContact { Self.pendingContactResponses -= 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: pendingContact ? 409 : 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((pendingContact ?
            #"{"error":"completed body contact could not be claimed","code":"contact_unavailable"}"# : json).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class ConversationClientTests: XCTestCase {
    private var previousFollowEcho = false
    override func setUp() async throws {
        previousFollowEcho = AppSettings().followEcho
        AppSettings().followEcho = false
    }
    override func tearDown() async throws {
        AppSettings().followEcho = previousFollowEcho
    }

    func testServerResolvedDotAndSilenceDoNotDisplayOrSpeakLocally() async {
        let settings = AppSettings()
        let previous = settings.agentSessionID
        defer { settings.agentSessionID = previous; ConversationStubProtocol.settledDestination = nil }
        settings.agentSessionID = "existing-session"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let speech = SpeechService(settings: settings, agentToken: { "agent-test" })
        var starts = 0
        speech.onAvailabilityChange = { if speech.isBusy { starts += 1 } }
        for target in ["dot", "silent"] {
            ConversationStubProtocol.settledDestination = target
            let conversation = ConversationClient(settings: settings, speech: speech,
                session: URLSession(configuration: configuration), agentToken: { "agent-test" })
            var destinations: [String] = []
            conversation.deliverOutput = { _, destination in destinations.append(destination) }
            await conversation.send("Say this on the Dot or choose silence")
            XCTAssertEqual(destinations, [target])
            XCTAssertEqual(conversation.reply, "")
            XCTAssertEqual(starts, 0)
        }
    }

    func testBackgroundReconciliationDoesNotStartDefaultSpeech() async {
        let settings = AppSettings()
        let old = settings.agentSessionID
        defer { settings.agentSessionID = old }
        settings.agentSessionID = "existing-session"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let speech = SpeechService(settings: settings, agentToken: { "agent-test" })
        let conversation = ConversationClient(settings: settings, speech: speech,
            session: URLSession(configuration: configuration), agentToken: { "agent-test" })
        var starts = 0
        speech.onAvailabilityChange = { if speech.isBusy { starts += 1 } }
        conversation.setForeground(false)
        await conversation.send("An answer settling in the background")
        XCTAssertEqual(conversation.reply, "Hello from Kairo.")
        XCTAssertEqual(starts, 0)
    }

    func testKairoChoiceUsesOnlyTheSettledDestination() async {
        let settings = AppSettings()
        let old = settings.agentSessionID
        defer { settings.agentSessionID = old; ConversationStubProtocol.settledDestination = nil }
        settings.agentSessionID = "existing-session"
        ConversationStubProtocol.settledDestination = "ipad_display"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings, speech: SpeechService(settings: settings),
            session: URLSession(configuration: configuration), agentToken: { "agent-test" })
        var destinations: [String] = []
        conversation.outputDestination = "kairo"
        conversation.deliverOutput = { _, target in destinations.append(target) }
        await conversation.send("Choose where to reply")
        XCTAssertNil(conversation.error)
        XCTAssertEqual(destinations, ["ipad_display"])
    }

    func testSelectedDotDeliveryHasOneSpeechOwner() async {
        let settings = AppSettings()
        let old = settings.agentSessionID
        defer { settings.agentSessionID = old }
        settings.agentSessionID = "existing-session"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let speech = SpeechService(settings: settings, agentToken: { "test-agent" })
        var localSpeechStarts = 0
        speech.onPlaybackStateChange = { if $0 { localSpeechStarts += 1 } }
        let conversation = ConversationClient(settings: settings, speech: speech,
            session: URLSession(configuration: configuration), agentToken: { "test-agent" })
        speech.onPlaybackStateChange = { if $0 { localSpeechStarts += 1 } }
        conversation.outputDestination = "dot"
        await conversation.send("Send this to the Dot")
        XCTAssertNil(conversation.error)
        XCTAssertEqual(localSpeechStarts, 0)
    }

    func testIPadSubmissionUsesVerifiedSharedDotSessionRatherThanOldPrivateSession() async {
        let settings = AppSettings()
        let oldSession = settings.agentSessionID
        let oldEcho = settings.echoSessionID
        let oldWorkspace = settings.agentWorkspaceID
        defer {
            settings.agentWorkspaceID = oldWorkspace
            settings.agentSessionID = oldSession
            settings.echoSessionID = oldEcho
        }
        settings.followEcho = true
        settings.echoSessionID = "echo-session"
        settings.agentWorkspaceID = ""
        settings.agentSessionID = "old-private-session"
        ConversationStubProtocol.received = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings, speech: SpeechService(settings: settings),
            session: URLSession(configuration: configuration), agentToken: { "test-agent" })
        conversation.speakReplies = false
        await conversation.send("Hello from iPad")
        XCTAssertNil(conversation.error)
        XCTAssertEqual(ConversationStubProtocol.received.first?.0, "/api/sessions/echo-session")
        XCTAssertTrue(ConversationStubProtocol.received.contains { $0.0 == "/api/sessions/echo-session/jobs" })
        XCTAssertFalse(ConversationStubProtocol.received.contains { $0.0.contains("old-private-session") })
    }
    func testUsesAgentCredentialAndExistingJobForTextAndSpokenReply() async {
        let settings = AppSettings()
        let previousURL = settings.agentURL
        let previousSession = settings.agentSessionID
        defer {
            settings.agentURL = previousURL
            settings.agentSessionID = previousSession
        }
        settings.agentURL = "https://connect.kairo.icu"
        settings.agentSessionID = "session-1"
        ConversationStubProtocol.received = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings, speech: SpeechService(settings: settings),
                                              session: URLSession(configuration: configuration),
                                              agentToken: { "agent-only-token" })
        conversation.speakReplies = false

        await conversation.send("Hello")

        XCTAssertNil(conversation.error)
        XCTAssertEqual(conversation.reply, "Hello from Kairo.")
        XCTAssertEqual(ConversationStubProtocol.received.map(\.0),
                       ["/api/sessions/session-1/jobs", "/api/jobs/job-1", "/api/jobs/job-1/events"])
        XCTAssertTrue(ConversationStubProtocol.received.allSatisfy { $0.1 == "Bearer agent-only-token" })
        XCTAssertEqual(conversation.promptProgress?.processed, 4239)
    }

    func testRejectsPathShapedIDs() {
        XCTAssertTrue(ConversationClient.validID("session-1"))
        XCTAssertFalse(ConversationClient.validID("../other"))
    }

    func testSelectsExistingKairoIPadWorkspaceWithoutGuessingAnother() {
        let rows: [[String: Any]] = [
            ["id": "ws-other", "name": "Another project"],
            ["id": "ws-ipad", "name": "Kairo iPad"],
        ]
        XCTAssertEqual(ConversationClient.preferredWorkspaceID(rows), "ws-ipad")
        XCTAssertNil(ConversationClient.preferredWorkspaceID([
            ["id": "ws-one", "name": "One"], ["id": "ws-two", "name": "Two"]]))
    }

    func testAgentTokenQRRequiresScopedPayload() {
        XCTAssertEqual(AgentTokenQR.parse("kairo-agent-token:v1:" + String(repeating: "a", count: 64)),
                       String(repeating: "a", count: 64))
        XCTAssertNil(AgentTokenQR.parse(String(repeating: "a", count: 64)))
        XCTAssertNil(AgentTokenQR.parse("kairo-agent-token:v1:../../bad"))
    }

    func testClearChatRemovesReplyAndStartsFreshSession() async {
        let settings = AppSettings()
        let previousSession = settings.agentSessionID
        defer { settings.agentSessionID = previousSession }
        settings.agentSessionID = "session-1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings,
                                              speech: SpeechService(settings: settings),
                                              session: URLSession(configuration: configuration),
                                              agentToken: { "agent-only-token" })
        conversation.speakReplies = false
        await conversation.send("Hello")
        XCTAssertEqual(conversation.reply, "Hello from Kairo.")

        conversation.clearChat()

        XCTAssertEqual(conversation.reply, "")
        XCTAssertEqual(conversation.status, "")
        XCTAssertNil(conversation.error)
        XCTAssertNil(conversation.promptProgress)
        XCTAssertEqual(settings.agentSessionID, "")
    }

    func testPromptProgressReportsActualContextTokens() {
        let event: [String: Any] = ["type": "PromptProgress", "processed": 4239,
                                    "total": 15207, "cached": 4000]
        let progress = PromptTokenProgress(event: event)
        XCTAssertEqual(progress?.processed, 4239)
        XCTAssertEqual(progress?.total, 15207)
        XCTAssertEqual(progress?.cached, 4000)
        XCTAssertNil(PromptTokenProgress(event: ["type": "TextDelta", "text": "hello"]))
        XCTAssertNil(PromptTokenProgress(event: ["type": "PromptProgress", "processed": -1,
                                                 "total": 15207]))
    }

    func testPartialPromptProgressDoesNotDisappearOrInventCachedTokens() {
        let progress = PromptTokenProgress(event: ["type": "PromptProgress", "processed": 45, "seq": 2])
        XCTAssertNotNil(progress, "A reported processed count remains useful without a total")
        XCTAssertNil(progress?.total)
        XCTAssertNil(progress?.cached)
    }

    func testProcessingStatusKeepsBodyAwakeAcrossOtherSurfaces() async {
        let settings = AppSettings()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings,
            speech: SpeechService(settings: settings),
            session: URLSession(configuration: configuration),
            agentToken: { "agent-only-token" })
        let processing = await conversation.isKairoProcessing()
        XCTAssertEqual(processing, true)
    }

    func testTouchReflexRetriesOnlyPendingContactAndCreatesOneJob() async {
        let settings = AppSettings()
        let previousSession = settings.agentSessionID
        defer { settings.agentSessionID = previousSession }
        settings.agentSessionID = "session-1"
        ConversationStubProtocol.received = []
        ConversationStubProtocol.pendingContactResponses = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationStubProtocol.self]
        let conversation = ConversationClient(settings: settings,
            speech: SpeechService(settings: settings),
            session: URLSession(configuration: configuration),
            agentToken: { "agent-only-token" })
        conversation.speakReplies = false

        await conversation.sendTouchReflex(contactID: "contact-1", endpointID: "ipad-1")

        XCTAssertNil(conversation.error)
        XCTAssertEqual(conversation.reply, "Hello from Kairo.")
        XCTAssertEqual(ConversationStubProtocol.received.filter {
            $0.0.hasSuffix("/body-reflex") }.count, 2)
        XCTAssertEqual(ConversationStubProtocol.received.filter {
            $0.0 == "/api/jobs/job-1" }.count, 1)
    }
}
