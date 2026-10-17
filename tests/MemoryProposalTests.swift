import XCTest
@testable import KairoBody

final class MemoryProposalTests: XCTestCase {
    func testProposalRequiresExactHashAndFutureExpiry() {
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let valid: [String: Any] = ["id": "ipa_test", "proposal_hash": String(repeating: "a", count: 64),
            "expires_at": expiry, "note": ["text": "A private encounter."]]
        XCTAssertEqual(MemoryProposal(json: valid)?.text, "A private encounter.")
        var edited = valid; edited["proposal_hash"] = "edited"
        XCTAssertNil(MemoryProposal(json: edited))
        edited = valid; edited["expires_at"] = "2020-01-01T00:00:00Z"
        XCTAssertNil(MemoryProposal(json: edited))
    }
}
