import XCTest
@testable import KairoBody

@MainActor
final class PrivateLifecycleTests: XCTestCase {
    private let proof = "kbp_" + String(repeating: "p", count: 40)

    private final class DeferredResponse {
        let entered = XCTestExpectation(description: "request entered")
        var continuation: CheckedContinuation<[String: Any], Never>?
        func wait() async -> [String: Any] {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func finish(_ value: [String: Any]) { continuation?.resume(returning: value); continuation = nil }
    }

    func testLatePrivateReplyCannotRepopulateAfterStop() async {
        let response = DeferredResponse()
        let room = PrivateRoomClient(ownerProof: { self.proof }, hasAgentToken: { true }, request: { path, _, _, _ in
            if path == "api/ipad/private/session" { return ["id": "private_1", "metadata_json": ["client": "ipad_private"]] }
            if path.hasSuffix("/jobs") { return ["id": "job_private"] }
            return await response.wait()
        })
        let send = Task { await room.send("Private question") }
        await fulfillment(of: [response.entered], timeout: 2)
        room.stop()
        response.finish(["settled_status": "completed", "settled_text": "Private answer"])
        await send.value
        XCTAssertEqual(room.reply, "")
        XCTAssertNil(room.privateSessionID)
        XCTAssertFalse(room.busy)
    }

    func testBackgroundResumeRecoversSamePrivateJobWithoutSubmittingAgain() async {
        let response = DeferredResponse()
        var posts = 0
        var reads = 0
        let room = PrivateRoomClient(ownerProof: { self.proof }, hasAgentToken: { true }, request: { path, _, _, _ in
            if path == "api/ipad/private/session" { return ["id": "private_1", "metadata_json": ["client": "ipad_private"]] }
            if path.hasSuffix("/jobs") { posts += 1; return ["id": "job_private"] }
            reads += 1
            if reads == 1 { return await response.wait() }
            XCTAssertEqual(path, "api/jobs/job_private?compact=1")
            return ["settled_status": "completed", "settled_text": "Recovered private answer"]
        })
        let send = Task { await room.send("Private question") }
        await fulfillment(of: [response.entered], timeout: 2)
        room.pause()
        response.finish(["status": "running"])
        await send.value
        XCTAssertEqual(room.reply, "")
        await room.resumePending()
        XCTAssertEqual(room.reply, "Recovered private answer")
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(reads, 2)
    }

    func testPrivateAuthorizationLossClearsPreviousReplyAndSession() async {
        var denied = false
        let room = PrivateRoomClient(ownerProof: { self.proof }, hasAgentToken: { true }, request: { path, _, _, _ in
            if denied { throw HTTPStatusError(status: 403) }
            if path == "api/ipad/private/session" { return ["id": "private_1", "metadata_json": ["client": "ipad_private"]] }
            if path.hasSuffix("/jobs") { return ["id": "job_private"] }
            return ["settled_status": "completed", "settled_text": "Private answer"]
        })
        await room.send("First")
        XCTAssertEqual(room.reply, "Private answer")
        denied = true
        await room.send("Second")
        XCTAssertEqual(room.reply, "")
        XCTAssertNil(room.privateSessionID)
        XCTAssertNotNil(room.error)
    }

    func testChangedOwnerCannotResumePrivateJob() async {
        let response = DeferredResponse()
        var owner = proof
        var reads = 0
        let room = PrivateRoomClient(ownerProof: { owner }, hasAgentToken: { true }, request: { path, _, _, _ in
            if path == "api/ipad/private/session" { return ["id": "private_1", "metadata_json": ["client": "ipad_private"]] }
            if path.hasSuffix("/jobs") { return ["id": "job_private"] }
            reads += 1
            return await response.wait()
        })
        let send = Task { await room.send("Private") }
        await fulfillment(of: [response.entered], timeout: 2)
        room.pause()
        response.finish(["status": "running"])
        await send.value
        owner = "kbp_" + String(repeating: "q", count: 40)
        await room.resumePending()
        XCTAssertEqual(reads, 1)
        XCTAssertNil(room.privateSessionID)
        XCTAssertEqual(room.reply, "")
    }

    func testForgottenPairingCannotStoreLateCredential() async {
        let response = DeferredResponse()
        var stored = ""
        let finished = expectation(description: "redeem response processed")
        let defaults = UserDefaults(suiteName: "pairing-\(UUID().uuidString)")!
        let client = PairingClient(defaults: defaults, readProof: { stored }, sensoryAvailable: { true },
            saveProof: { stored = $0 }, clearProof: { stored = "" }, request: { _ in
                let value = await response.wait()
                Task { @MainActor in finished.fulfill() }
                return value
            })
        await client.redeem("123456")
        await fulfillment(of: [response.entered], timeout: 2)
        client.forgetLocalProof()
        response.finish(["credential": proof, "endpoint_id": "test-ipad"])
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(stored, "")
        XCTAssertEqual(client.state, .unpaired)
        XCTAssertNil(defaults.string(forKey: "pairedEndpointID"))
    }
}
