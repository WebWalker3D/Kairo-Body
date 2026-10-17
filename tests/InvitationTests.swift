import XCTest
@testable import KairoBody

@MainActor
final class InvitationTests: XCTestCase {
    func testRevokedInvitationCannotBeAcceptedAfterDisplayReceiptFails() async {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: Date().addingTimeInterval(60))
        let client = InvitationClient(request: { _, body in
            if body != nil { return ["accepted": false] }
            return ["invitation": ["id": "7", "text": "Look together?", "origin": "kairo",
                "source_event_id": 42, "session_id": "source", "expires_at": expiry]]
        })
        await client.refresh(sessionID: "current", foreground: true)
        XCTAssertNotNil(client.invitation)
        await client.markDisplayed()
        XCTAssertNil(client.invitation)
        let accepted = await client.accept()
        XCTAssertNil(accepted)
    }

    func testRevocationAfterDisplayCannotStartConversation() async {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: Date().addingTimeInterval(60))
        let client = InvitationClient(request: { _, body in
            if let body { return ["accepted": body["status"] as? String == "delivered"] }
            return ["invitation": ["id": "8", "text": "Look together?", "origin": "kairo",
                "source_event_id": 42, "session_id": "source", "expires_at": expiry]]
        })
        await client.refresh(sessionID: "current", foreground: true)
        XCTAssertFalse(client.canRespond)
        await client.markDisplayed()
        XCTAssertTrue(client.canRespond)
        let accepted = await client.accept()
        XCTAssertNil(accepted)
        XCTAssertNil(client.invitation)
        XCTAssertFalse(client.canRespond)
    }

    func testAcceptedReceiptsPermitOneExplicitResponse() async {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: Date().addingTimeInterval(60))
        let client = InvitationClient(request: { _, body in
            if body != nil { return ["accepted": true] }
            return ["invitation": ["id": "9", "text": "Look together?", "origin": "kairo",
                "source_event_id": 42, "session_id": "source", "expires_at": expiry]]
        })
        await client.refresh(sessionID: "current", foreground: true)
        await client.markDisplayed()
        let first = await client.accept()
        let second = await client.accept()
        XCTAssertEqual(first, "Look together?")
        XCTAssertNil(second)
    }

    func testBackgroundRefreshDoesNotFetchAndExpiredProposalNeverAppears() async {
        var requests = 0
        let client = InvitationClient(request: { _, _ in
            requests += 1
            return ["invitation": ["id": "7", "text": "Look together?", "origin": "kairo",
                "source_event_id": 42, "session_id": "source", "expires_at": "2020-01-01T00:00:00Z"]]
        })
        await client.refresh(sessionID: "current", foreground: false)
        XCTAssertEqual(requests, 0)
        await client.refresh(sessionID: "current", foreground: true)
        XCTAssertEqual(requests, 2) // fetch, then record expired claim
        XCTAssertNil(client.invitation)
    }

    func testStopInvalidatesLateFetchWithoutShowingInvitation() async {
        let client = InvitationClient(request: { _, _ in
            try await Task.sleep(for: .milliseconds(40))
            return ["invitation": ["id": "7", "text": "Look together?", "origin": "kairo",
                "source_event_id": 42, "session_id": "source", "expires_at": "2099-01-01T00:00:00Z"]]
        })
        let fetch = Task { await client.refresh(sessionID: "current", foreground: true) }
        await Task.yield()
        client.stop()
        await fetch.value
        XCTAssertNil(client.invitation)
    }
}
