import XCTest
@testable import KairoBody

@MainActor
final class ConversationLifecycleTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    override func setUp() {
        super.setUp()
        suiteName = "ConversationLifecycleTests.\(UUID())"
        suite = UserDefaults(suiteName: suiteName)!
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }
    private func make(_ tracker: JobTracker) -> ConversationClient {
        let settings = AppSettings(defaults: suite)
        settings.followEcho = false
        settings.sharedSessionID = "session_fixture"
        return ConversationClient(settings: settings, speech: SpeechService(), tracker: tracker,
                                  pendingStore: PendingTurnStore(defaults: suite))
    }
    func testAcknowledgesMessageBeforePreparingOutput() async {
        let client = make(JobTracker(request: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        var acknowledged = false
        client.prepareOutput = { _ in
            acknowledged = client.isSending && !client.status.isEmpty
            throw URLError(.notConnectedToInternet)
        }
        await client.send("Hello")
        XCTAssertTrue(acknowledged, "The stage needs immediate status before any network wait")
    }
    func testNewSendCannotOverwriteUnresolvedMessage() async {
        let store = PendingTurnStore(defaults: suite)
        let original = PendingTurn.new(sessionID: "session_fixture", text: "Original", attachmentIDs: [], outputDestination: "silent")
        store.save(original)
        var posts = 0
        let client = make(JobTracker(request: { _, method, _ in
            if method == "POST" { posts += 1 }
            throw HTTPStatusError(status: 403)
        }))
        await client.send("Replacement")
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(store.load(), original, "Unknown submission must retain its exact idempotency key")
    }
    func testStopDuringPreparationCannotSubmitOrResurrectPendingTurn() async {
        var posts = 0
        let client = make(JobTracker(request: { _, method, _ in
            if method == "POST" { posts += 1; return ["id": "job_fixture"] }
            return ["settled_status": "completed", "settled_text": "done"]
        }))
        let preparing = expectation(description: "preparing")
        var release: CheckedContinuation<Void, Never>?
        client.prepareOutput = { _ in
            await withCheckedContinuation { release = $0; preparing.fulfill() }
        }
        let sending = Task { await client.send("Stop this") }
        await fulfillment(of: [preparing], timeout: 2)
        await client.stopResponse()
        release?.resume()
        await sending.value
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(client.hasPendingTurn)
        XCTAssertFalse(client.isSending)
    }
    func testResetCannotDiscardPendingTurn() {
        let store = PendingTurnStore(defaults: suite)
        let original = PendingTurn.new(sessionID: "session_fixture", text: "Original", attachmentIDs: [], outputDestination: "silent")
        store.save(original)
        let client = make(JobTracker(request: { _, _, _ in throw URLError(.cancelled) }))
        client.clearChat()
        XCTAssertEqual(store.load(), original)
    }
}

extension ConversationLifecycleTests {
    func testKnownJobRecoveryPollsWithoutResubmitting() async {
        let store = PendingTurnStore(defaults: suite)
        var turn = PendingTurn.new(sessionID: "session_fixture", text: "Original", attachmentIDs: [], outputDestination: "silent")
        turn.jobID = "job_original"; store.save(turn)
        var posts = 0
        let client = make(JobTracker(request: { path, method, _ in
            if method == "POST" { posts += 1 }
            XCTAssertEqual(path, "api/jobs/job_original?compact=1")
            return ["settled_status": "completed", "settled_text": "Recovered answer"]
        }))
        await client.recoverPendingTurn()
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(client.reply, "Recovered answer")
        XCTAssertFalse(client.hasPendingTurn)
    }

    func testStoppedUnknownSubmissionIsLookedUpButNeverPostedAgain() async {
        let store = PendingTurnStore(defaults: suite)
        var turn = PendingTurn.new(sessionID: "session_fixture", text: "Stopped", attachmentIDs: [], outputDestination: "silent")
        turn.cancelRequested = true; store.save(turn)
        var methods: [String] = []
        let client = make(JobTracker(request: { path, method, _ in
            methods.append(method)
            XCTAssertTrue(path.contains("idempotency_key="))
            return [[String: Any]]()
        }))
        await client.recoverPendingTurn()
        XCTAssertEqual(methods, ["GET"])
        XCTAssertEqual(store.load(), turn)
        XCTAssertEqual(client.pendingRecovery, .unconfirmed)
        XCTAssertFalse(client.canSubmit)
    }

    func testForegroundRecoveryCannotStartASecondWatcher() async {
        let store = PendingTurnStore(defaults: suite)
        var turn = PendingTurn.new(sessionID: "session_fixture", text: "Original", attachmentIDs: [], outputDestination: "silent")
        turn.jobID = "job_original"; store.save(turn)
        let entered = expectation(description: "watching")
        var release: CheckedContinuation<[String: Any], Never>?
        var reads = 0
        let client = make(JobTracker(request: { _, _, _ in
            reads += 1
            return await withCheckedContinuation { release = $0; entered.fulfill() }
        }))
        let first = Task { await client.recoverPendingTurn() }
        await fulfillment(of: [entered], timeout: 2)
        await client.recoverPendingTurn()
        XCTAssertEqual(reads, 1)
        release?.resume(returning: ["settled_status": "completed", "settled_text": "One answer"])
        await first.value
        XCTAssertEqual(client.reply, "One answer")
    }

    func testDefinitiveSubmissionFailureRestoresUnsentDraft() async {
        let client = make(JobTracker(request: { _, _, _ in throw HTTPStatusError(status: 403) }))
        client.draft = "Keep my question"
        await client.send(client.draft)
        XCTAssertEqual(client.draft, "Keep my question")
        XCTAssertFalse(client.hasPendingTurn)
        XCTAssertNotNil(client.error)
    }
}
