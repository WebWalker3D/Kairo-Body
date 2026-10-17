import Foundation
import XCTest
@testable import KairoBody

/// Scripted Agent API: each request pops the next reply queued for its path.
private final class ScriptedAgentProtocol: URLProtocol {
    enum Reply {
        case json(Int, String, [String: String] = [:])
        case empty(Int, [String: String] = [:])
        case fail(URLError.Code)
        /// The server processed the request but the response was lost.
        case lostAfterProcessing(String)
    }
    static var replies: [String: [Reply]] = [:]
    static var fallback: [String: Reply] = [:]
    static var log: [(method: String, path: String, ifNoneMatch: String?, body: String?)] = []
    static var processedPosts = 0

    static func reset() { replies = [:]; fallback = [:]; log = []; processedPosts = 0 }
    static func queue(_ path: String, _ items: Reply...) { replies[path, default: []] += items }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        var body: String?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = String(decoding: data, as: UTF8.self)
        } else if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        }
        let key = request.url!.query.map { "\(path)?\($0)" } ?? path
        Self.log.append((request.httpMethod ?? "GET", key, request.value(forHTTPHeaderField: "If-None-Match"), body))
        let reply: Reply
        if var queued = Self.replies[key] ?? Self.replies[path], !queued.isEmpty {
            reply = queued.removeFirst()
            if Self.replies[key] != nil { Self.replies[key] = queued } else { Self.replies[path] = queued }
        } else {
            reply = Self.fallback[path] ?? .empty(404)
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .lostAfterProcessing:
            Self.processedPosts += 1
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .json(let status, let json, let headers):
            if request.httpMethod == "POST" { Self.processedPosts += 1 }
            respond(status, Data(json.utf8), headers)
        case .empty(let status, let headers):
            respond(status, Data(), headers)
        }
    }

    private func respond(_ status: Int, _ data: Data, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func scriptedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedAgentProtocol.self]
    return URLSession(configuration: configuration)
}

private let conversationPath = "/api/ipad/conversations"
private func feed(_ answer: String, running: Bool = false) -> String {
    let status = running ? "running" : "completed"
    let settled = running ? "null" : #""completed""#
    return #"{"schema_version":1,"read_only":true,"turns":[{"id":"job-1","session_id":"s","prompt":"hi","status":"\#(status)","created_at":"2026-10-11T00:00:00Z","settled_status":\#(settled),"settled_text":"\#(answer)","metadata_json":{"source":"discord"},"events":[]}],"live_state":{"available":true,"committed":true,"revision":7,"dimensions":[]}}"#
}

@MainActor
final class ConversationObserverReliabilityTests: XCTestCase {
    private let proof = "kbp_" + String(repeating: "d", count: 40)

    override func setUp() async throws { ScriptedAgentProtocol.reset() }

    private func observer(proof: @escaping () -> String) -> EchoConversationClient {
        EchoConversationClient(session: scriptedSession(), agentToken: { "agent" }, ownerCredential: proof)
    }

    func testOutagesTimeoutsAndMalformedBodiesKeepTheTranscript() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.queue(conversationPath,
            .json(200, feed("Kept answer"), ["ETag": #"W/"rev-1""#]),
            .empty(502),
            .fail(.timedOut),
            .json(200, "<html>bad gateway</html>"),
            .json(503, #"{"error":"x","code":"owner_authorization_unavailable"}"#))
        await client.refreshAllSurfaces()
        XCTAssertEqual(client.turns.map(\.id), ["job-1"])
        for _ in 0..<4 {
            let outcome = await client.refreshAllSurfaces()
            XCTAssertEqual(outcome, .transient)
            XCTAssertEqual(client.turns.map(\.id), ["job-1"], "the transcript survives the failure")
            XCTAssertEqual(client.state?.revision, 7)
            XCTAssertNil(client.error)
            XCTAssertNotNil(client.connectionTrouble)
        }
    }

    func testUnchangedConversationIsValidatedWith304AndRealChangesArrive() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.queue(conversationPath,
            .json(200, feed("First"), ["ETag": #"W/"rev-1""#]),
            .empty(304, ["ETag": #"W/"rev-1""#]),
            .json(200, feed("Second"), ["ETag": #"W/"rev-2""#]))
        await client.refreshAllSurfaces()
        let firstTurns = client.turns.map(\.answer)
        let unchanged = await client.refreshAllSurfaces()
        XCTAssertEqual(unchanged, .notModified)
        XCTAssertEqual(client.turns.map(\.answer), firstTurns)
        XCTAssertNil(client.connectionTrouble)
        let changed = await client.refreshAllSurfaces()
        XCTAssertEqual(changed, .fresh)
        XCTAssertEqual(client.turns.first?.answer, "Second")
        XCTAssertEqual(ScriptedAgentProtocol.log.map(\.ifNoneMatch),
                       [nil, #"W/"rev-1""#, #"W/"rev-1""#])
    }

    func testAnUnrequested304IsTroubleNotAnEmptyConversation() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.queue(conversationPath, .empty(304))
        let outcome = await client.refreshAllSurfaces()
        XCTAssertEqual(outcome, .transient)
        XCTAssertNotNil(client.connectionTrouble)
    }

    func testConfirmedAuthorizationLossClearsAndRecoveryStartsUnconditionally() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.queue(conversationPath,
            .json(200, feed("Private"), ["ETag": #"W/"rev-1""#]),
            .json(403, #"{"error":"rejected","code":"owner_authorization_rejected"}"#),
            .json(200, feed("Again"), ["ETag": #"W/"rev-9""#]))
        await client.refreshAllSurfaces()
        let lost = await client.refreshAllSurfaces()
        XCTAssertEqual(lost, .authorizationLost)
        XCTAssertTrue(client.turns.isEmpty)
        XCTAssertNil(client.state)
        XCTAssertNotNil(client.error)
        await client.refreshAllSurfaces()
        XCTAssertEqual(client.turns.first?.answer, "Again")
        XCTAssertNil(ScriptedAgentProtocol.log.last?.ifNoneMatch, "a cleared view must not revalidate stale content")
    }

    func testDifferentOwnerProofIsAnExplicitConversationChange() async {
        var proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.queue(conversationPath,
            .json(200, feed("Owner A"), ["ETag": #"W/"rev-1""#]),
            .json(200, feed("Owner B"), ["ETag": #"W/"rev-2""#]))
        await client.refreshAllSurfaces()
        proof = "kbp_" + String(repeating: "e", count: 40)
        await client.refreshAllSurfaces()
        XCTAssertEqual(client.turns.first?.answer, "Owner B")
        XCTAssertNil(ScriptedAgentProtocol.log.last?.ifNoneMatch)
    }

    func testConcurrentRefreshesDoNotOverlap() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.fallback[conversationPath] = .json(200, feed("One"), ["ETag": #"W/"rev-1""#])
        async let first = client.refreshAllSurfaces()
        async let second = client.refreshAllSurfaces()
        let outcomes = await [first, second]
        XCTAssertEqual(ScriptedAgentProtocol.log.count, 1)
        XCTAssertTrue(outcomes.contains(nil))
    }

    func testBackgroundKeepsTheTranscriptWhileReadsPause() async {
        let proof = self.proof
        let client = observer { proof }
        ScriptedAgentProtocol.fallback[conversationPath] = .json(200, feed("Visible"), ["ETag": #"W/"rev-1""#])
        await client.refreshAllSurfaces()
        client.followAllSurfaces(foreground: false)
        XCTAssertEqual(client.turns.first?.answer, "Visible")
        let reads = ScriptedAgentProtocol.log.count
        await client.refreshAllSurfaces()
        XCTAssertEqual(ScriptedAgentProtocol.log.count, reads)
    }
}

@MainActor
final class MessageSubmissionReliabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var savedSession = ""
    private var savedFollow = false

    override func setUp() async throws {
        ScriptedAgentProtocol.reset()
        defaults = UserDefaults(suiteName: "submission-tests-\(UUID().uuidString)")
        let settings = AppSettings()
        savedSession = settings.agentSessionID
        savedFollow = settings.followEcho
        settings.agentSessionID = "session-1"
        settings.followEcho = false
    }

    override func tearDown() async throws {
        let settings = AppSettings()
        settings.agentSessionID = savedSession
        settings.followEcho = savedFollow
    }

    private func conversation(clock: (() -> Date)? = nil, sleep: ((Double) async throws -> Void)? = nil) -> ConversationClient {
        let settings = AppSettings()
        let client = ConversationClient(settings: settings, speech: SpeechService(settings: settings),
            session: scriptedSession(), agentToken: { "agent" },
            pendingStore: PendingTurnStore(defaults: defaults),
            now: clock ?? Date.init, sleep: sleep ?? { _ in })
        client.speakReplies = false
        return client
    }

    private let settled = #"{"id":"job-1","status":"completed","settled_status":"completed","settled_text":"Hello from Kairo."}"#
    private let running = #"{"id":"job-1","status":"running"}"#

    func testLostSubmissionResponseCreatesExactlyOneJobAndOneMessage() async {
        let client = conversation()
        ScriptedAgentProtocol.queue("/api/sessions/session-1/jobs",
            .lostAfterProcessing("first attempt reached the server"),
            .json(202, #"{"id":"job-1"}"#))
        ScriptedAgentProtocol.queue("/api/jobs/job-1", .json(200, settled))
        ScriptedAgentProtocol.fallback["/api/jobs/job-1/events"] = .json(200, "[]")
        await client.send("Are you there?")
        XCTAssertNil(client.error)
        XCTAssertEqual(client.reply, "Hello from Kairo.")
        let posts = ScriptedAgentProtocol.log.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].body, posts[1].body, "the retry is the identical request")
        XCTAssertTrue(posts[0].body?.contains("ipad-body:") == true)
        XCTAssertNil(PendingTurnStore(defaults: defaults).load(), "a settled turn is released")
    }

    func testFailedStatusChecksDoNotAbandonTheRunningJob() async {
        let client = conversation()
        ScriptedAgentProtocol.queue("/api/sessions/session-1/jobs", .json(202, #"{"id":"job-1"}"#))
        ScriptedAgentProtocol.queue("/api/jobs/job-1",
            .json(200, running), .empty(502), .fail(.timedOut), .json(200, "not json"), .json(200, settled))
        ScriptedAgentProtocol.fallback["/api/jobs/job-1/events"] = .json(200, "[]")
        await client.send("Long question")
        XCTAssertNil(client.error)
        XCTAssertEqual(client.reply, "Hello from Kairo.")
    }

    func testDeadlineKeepsTheJobAndCheckAgainRecoversTheResult() async {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let client = conversation(clock: { now }, sleep: { now += $0 })
        ScriptedAgentProtocol.queue("/api/sessions/session-1/jobs", .json(202, #"{"id":"job-1"}"#))
        ScriptedAgentProtocol.fallback["/api/jobs/job-1"] = .json(200, running)
        ScriptedAgentProtocol.fallback["/api/jobs/job-1/events"] = .json(200, "[]")
        await client.send("Very long task")
        XCTAssertEqual(client.pendingRecovery, .stillWorking(jobID: "job-1"))
        XCTAssertNil(client.error)
        XCTAssertFalse(client.status.isEmpty)
        XCTAssertEqual(PendingTurnStore(defaults: defaults).load()?.jobID, "job-1")
        ScriptedAgentProtocol.fallback["/api/jobs/job-1"] = .json(200, settled)
        await client.recoverPending()
        XCTAssertEqual(client.reply, "Hello from Kairo.")
        XCTAssertNil(client.pendingRecovery)
        XCTAssertEqual(ScriptedAgentProtocol.log.filter { $0.method == "POST" }.count, 1)
    }

    func testUnconfirmedMessageIsKeptAndRetriedWithItsOriginalKey() async {
        let client = conversation()
        ScriptedAgentProtocol.fallback["/api/sessions/session-1/jobs"] = .fail(.notConnectedToInternet)
        await client.send("Offline message")
        XCTAssertEqual(client.pendingRecovery, .unconfirmed)
        let firstBody = ScriptedAgentProtocol.log.first { $0.method == "POST" }?.body
        ScriptedAgentProtocol.fallback["/api/sessions/session-1/jobs"] = nil
        ScriptedAgentProtocol.queue("/api/sessions/session-1/jobs", .json(202, #"{"id":"job-1"}"#))
        ScriptedAgentProtocol.queue("/api/jobs/job-1", .json(200, settled))
        ScriptedAgentProtocol.fallback["/api/jobs/job-1/events"] = .json(200, "[]")
        await client.recoverPending()
        XCTAssertEqual(client.reply, "Hello from Kairo.")
        XCTAssertEqual(ScriptedAgentProtocol.log.last { $0.method == "POST" }?.body, firstBody)
    }

    func testPendingTurnResumesAfterRelaunchWithoutResending() async {
        var turn = PendingTurn.new(sessionID: "session-1", text: "Before relaunch", attachmentIDs: [],
                                   outputDestination: nil)
        turn.jobID = "job-1"
        PendingTurnStore(defaults: defaults).save(turn)
        let client = conversation()
        ScriptedAgentProtocol.queue("/api/jobs/job-1", .json(200, settled))
        ScriptedAgentProtocol.fallback["/api/jobs/job-1/events"] = .json(200, "[]")
        await client.resumePendingIfNeeded()
        XCTAssertEqual(client.reply, "Hello from Kairo.")
        XCTAssertTrue(ScriptedAgentProtocol.log.allSatisfy { $0.method == "GET" })
        XCTAssertNil(PendingTurnStore(defaults: defaults).load())
    }

    func testDefinitiveRejectionReleasesTheMessageForEditing() async {
        let client = conversation()
        ScriptedAgentProtocol.queue("/api/sessions/session-1/jobs", .json(400, #"{"error":"bad"}"#))
        await client.send("Rejected")
        XCTAssertNotNil(client.error)
        XCTAssertNil(client.pendingRecovery)
        XCTAssertNil(PendingTurnStore(defaults: defaults).load())
    }
}

@MainActor
final class ConversationObserverLoopTests: XCTestCase {
    func testFollowingKeepsPollingAfterAdoptingTheOwnerProof() async {
        ScriptedAgentProtocol.reset()
        ScriptedAgentProtocol.fallback[conversationPath] = .json(200, feed("Busy", running: true), ["ETag": #"W/"rev-1""#])
        let proof = "kbp_" + String(repeating: "f", count: 40)
        let client = EchoConversationClient(session: scriptedSession(), agentToken: { "agent" }, ownerCredential: { proof })
        client.followAllSurfaces(foreground: true)
        // A running turn polls every 2 s; two reads prove the loop survived the first.
        let deadline = Date().addingTimeInterval(6)
        while ScriptedAgentProtocol.log.count < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        client.stop()
        XCTAssertGreaterThanOrEqual(ScriptedAgentProtocol.log.count, 2)
        XCTAssertEqual(ScriptedAgentProtocol.log.dropFirst().first?.ifNoneMatch, #"W/"rev-1""#)
    }
}
