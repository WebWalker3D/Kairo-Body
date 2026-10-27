import XCTest
@testable import KairoBody

@MainActor
final class TranscriptFeedTests: XCTestCase {
    // Synthetic credentials exist only in memory; no Keychain entitlement or
    // persistent device configuration is involved in these lifecycle tests.
    private let firstOwner = "kbp_" + String(repeating: "a", count: 40)
    private let secondOwner = "kbp_" + String(repeating: "b", count: 40)

    private func snapshot(id: String = "turn_1", completed: Bool = false) -> [String: Any] {
        var job: [String: Any] = [
            "id": id, "session_id": "fixture_session", "prompt": "Are you there?",
            "status": completed ? "completed" : "running",
            "created_at": "2026-10-26T12:00:00Z",
            "metadata_json": ["surface_kind": "ipad", "client": "ipad_body"],
            "events": []
        ]
        if completed {
            job["settled_status"] = "completed"
            job["settled_text"] = "Yes, I am here."
        }
        return ["schema_version": 1, "read_only": true, "turns": [job]]
    }

    private func makeFeed(owner: (() -> String)? = nil,
                          read: @escaping TranscriptFeedClient.ConditionalRead) -> TranscriptFeedClient {
        TranscriptFeedClient(ownerProof: owner ?? { self.firstOwner },
                             agentAvailable: { true }, read: read,
                             sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
    }

    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // A generation change during the first read used to strand the loop after
    // publishing "running", so a completed response was never requested.
    func testFirstFollowContinuesPollingUntilRunningTurnCompletes() async {
        var reads = 0
        let feed = makeFeed { path, validator in
            XCTAssertEqual(path, "api/ipad/conversations?tail=20")
            reads += 1
            if reads == 1 {
                XCTAssertNil(validator)
                return (.fresh, self.snapshot(), "running-etag")
            }
            XCTAssertEqual(validator, reads == 2 ? "running-etag" : "completed-etag")
            return (.fresh, self.snapshot(completed: true), "completed-etag")
        }
        defer { feed.stop() }
        feed.followAllSurfaces(foreground: true)
        await waitUntil("The actual poll loop must observe the completed answer") {
            feed.turns.first?.answer == "Yes, I am here."
        }
        XCTAssertGreaterThanOrEqual(reads, 2)
        XCTAssertTrue(feed.following)
        XCTAssertFalse(feed.processing, "A settled answer must release the thinking state")
    }

    func testSameOwnerFollowDoesNotReplaceReadInFlight() async {
        var response: CheckedContinuation<Void, Never>?
        var reads = 0
        let feed = makeFeed { _, _ in
            reads += 1
            if reads == 1 { await withCheckedContinuation { response = $0 } }
            return (.fresh, self.snapshot(completed: true), "complete")
        }
        defer { response?.resume(); feed.stop() }
        feed.followAllSurfaces(foreground: true)
        await waitUntil("First read started") { response != nil }
        feed.followAllSurfaces(foreground: true)
        response?.resume(); response = nil
        await waitUntil("Repeated foreground notification must preserve the current read") {
            feed.turns.first?.answer == "Yes, I am here."
        }
        XCTAssertTrue(feed.following)
    }

    func testTransientFailureAnd304KeepTranscriptAndPollingRecovers() async {
        var reads = 0
        let feed = makeFeed { _, validator in
            reads += 1
            switch reads {
            case 1: return (.fresh, self.snapshot(), "running")
            case 2:
                XCTAssertEqual(validator, "running")
                throw URLError(.timedOut)
            case 3:
                XCTAssertEqual(validator, "running")
                return (.notModified, nil, "running")
            default: return (.fresh, self.snapshot(completed: true), "complete")
            }
        }
        defer { feed.stop() }
        // Prime history independently, then exercise the genuine follow loop.
        await feed.refresh()
        XCTAssertEqual(feed.turns.first?.status, "running")
        let failure = await feed.refresh()
        XCTAssertEqual(failure, .transient)
        XCTAssertNotNil(feed.connectionTrouble)
        XCTAssertEqual(feed.turns.first?.status, "running")
        let unchanged = await feed.refresh()
        XCTAssertEqual(unchanged, .notModified)
        XCTAssertEqual(feed.turns.first?.status, "running")
        feed.followAllSurfaces(foreground: true)
        await waitUntil("Polling must recover after timeout and conditional response") {
            feed.turns.first?.answer == "Yes, I am here."
        }
        XCTAssertNil(feed.connectionTrouble)
        XCTAssertFalse(feed.processing)
    }

    func testRefusedOwnerClearsContentAndLaterValidReadCanRecover() async {
        var reads = 0
        let feed = makeFeed { _, validator in
            reads += 1
            switch reads {
            case 1: return (.fresh, self.snapshot(), "private")
            case 2: return (.authorizationLost, nil, nil)
            default:
                XCTAssertNil(validator, "Refused authority must discard its cache validator")
                return (.fresh, self.snapshot(completed: true), nil)
            }
        }
        defer { feed.stop() }
        await feed.refresh()
        let refused = await feed.refresh()
        XCTAssertEqual(refused, .authorizationLost)
        XCTAssertTrue(feed.turns.isEmpty)
        XCTAssertNil(feed.lastUpdatedAt)
        XCTAssertNotNil(feed.error)
        feed.followAllSurfaces(foreground: true)
        await waitUntil("A fresh authorized follow must recover after refusal") {
            feed.turns.first?.answer == "Yes, I am here."
        }
    }

    func testBackgroundKeepsTranscriptButDiscardsLateResponseAndResumes() async {
        var response: CheckedContinuation<Void, Never>?
        var reads = 0
        let feed = makeFeed { _, _ in
            reads += 1
            if reads == 2 { await withCheckedContinuation { response = $0 } }
            return (.fresh, self.snapshot(completed: reads > 1), "version")
        }
        defer { response?.resume(); feed.stop() }
        await feed.refresh()
        feed.followAllSurfaces(foreground: true)
        await waitUntil("Foreground read started") { response != nil }
        feed.followAllSurfaces(foreground: false)
        XCTAssertFalse(feed.following)
        XCTAssertEqual(feed.turns.first?.status, "running")
        response?.resume(); response = nil
        // Await the discarded request's cleanup before observing a fresh read.
        await Task.yield()
        XCTAssertEqual(feed.turns.first?.status, "running")
        XCTAssertNil(feed.connectionTrouble)
        feed.followAllSurfaces(foreground: true)
        await waitUntil("Returning to foreground must resume polling") {
            feed.turns.first?.answer == "Yes, I am here."
        }
    }

    func testOwnerSwitchClearsPreviousContentBeforeOldRequestFinishes() async {
        var owner = firstOwner
        var response: CheckedContinuation<Void, Never>?
        var reads = 0
        let feed = makeFeed(owner: { owner }) { _, validator in
            reads += 1
            if reads == 1 { return (.fresh, self.snapshot(id: "old_owner"), "old-etag") }
            if reads == 2 {
                await withCheckedContinuation { response = $0 }
                return (.fresh, self.snapshot(id: "old_owner", completed: true), "old-etag")
            }
            XCTAssertNil(validator, "New owner must not send the old owner's validator")
            return (.fresh, self.snapshot(id: "new_owner", completed: true), nil)
        }
        defer { response?.resume(); feed.stop() }
        await feed.refresh()
        feed.followAllSurfaces(foreground: true)
        await waitUntil("Old owner's next read started") { response != nil }
        owner = secondOwner
        feed.followAllSurfaces(foreground: true)
        XCTAssertTrue(feed.turns.isEmpty, "Old owner's content must clear immediately on owner switch")
        response?.resume(); response = nil
        await waitUntil("New owner's feed must replace the old authority") {
            feed.turns.first?.id == "new_owner"
        }
        XCTAssertEqual(feed.turns.first?.answer, "Yes, I am here.")
    }

    func testMissingOwnerProofClearsPrivateTranscript() async {
        var owner = firstOwner
        let feed = makeFeed(owner: { owner }) { _, _ in
            (.fresh, self.snapshot(), "private")
        }
        await feed.refresh()
        XCTAssertFalse(feed.turns.isEmpty)
        owner = ""
        feed.followAllSurfaces(foreground: true)
        XCTAssertTrue(feed.turns.isEmpty)
        XCTAssertFalse(feed.following)
        XCTAssertNil(feed.lastUpdatedAt)
    }
}
