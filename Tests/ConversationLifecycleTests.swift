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
