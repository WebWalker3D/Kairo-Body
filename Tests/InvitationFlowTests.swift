import XCTest
@testable import KairoBody

@MainActor
final class InvitationFlowTests: XCTestCase {
    func testAcceptedInvitationRetainsSourceSessionAndRequiresDisplayedReceipt() async {
        var outcomes: [String] = []
        let client = InvitationClient(ownerProof: { "kbp_" + String(repeating: "v", count: 40) }, request: { path, method, body in
            if method == "GET" {
                return ["invitation": ["id": "1", "text": "Continue our earlier thought", "origin": "kairo",
                                       "source_event_id": 7, "session_id": "source_session",
                                       "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))]]
            }
            XCTAssertEqual(path, "api/ipad/invitations/1/result")
            outcomes.append(body?["status"] as? String ?? "")
            return ["accepted": true]
        })
        await client.refresh(foreground: true)
        XCTAssertFalse(client.canRespond)
        await client.markDisplayed()
        XCTAssertTrue(client.canRespond)
        let accepted = await client.accept()
        XCTAssertEqual(accepted?.sourceSessionID, "source_session")
        XCTAssertEqual(accepted?.text, "Continue our earlier thought")
        XCTAssertEqual(outcomes, ["delivered", "answered"])
        let duplicate = await client.accept()
        XCTAssertNil(duplicate)
        XCTAssertEqual(outcomes, ["delivered", "answered"])
    }
}
