import XCTest
@testable import KairoBody

@MainActor
final class ApprovalClientTests: XCTestCase {
    private let missingApproval = PendingApproval(jobID: "job_missing", requestID: 1, description: "missing", scope: "tool", truncated: false)
    private let proof = "kbp_" + String(repeating: "p", count: 40)
    private func snapshot(id: Any = 1, truncated: Bool = false) -> [String: Any] {
        ["approvals": [["job_id": "job_example", "request_id": id,
                        "description": "inspect_will {'history_limit': 12}",
                        "scope": "tool", "truncated": truncated]]]
    }

    func testRefreshSelectsJobAndThrottles() async {
        var reads = 0
        var instant = Date(timeIntervalSince1970: 100)
        let client = ApprovalClient(ownerProof: { self.proof }, now: { instant }, request: { path, method, body in
            XCTAssertEqual(path, "api/observe?limit=30"); XCTAssertEqual(method, "GET"); XCTAssertNil(body)
            reads += 1
            return self.snapshot()
        })
        await client.refresh(jobID: "job_example")
        XCTAssertEqual(client.approval?.requestID, 1)
        let observed = client.approval
        await client.refresh(jobID: "job_example")
        XCTAssertEqual(reads, 1)
        instant.addTimeInterval(9)
        await client.refresh(jobID: "job_example")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(client.approval, observed)
    }

    func testOnlyExplicitOnceDecisionAndAcceptedIsQueued() async {
        var decisions: [String] = []
        let client = ApprovalClient(ownerProof: { self.proof }, request: { path, method, body in
            if method == "GET" { return self.snapshot() }
            XCTAssertEqual(path, "api/jobs/job_example/permission")
            XCTAssertEqual(body?["request_id"] as? Int, 1)
            decisions.append(body?["decision"] as? String ?? "")
            return ["accepted": true]
        })
        await client.refresh(jobID: "job_example")
        XCTAssertTrue(decisions.isEmpty)
        await client.decide(client.approval ?? missingApproval, allow: true)
        await client.decide(client.approval ?? missingApproval, allow: true)
        XCTAssertEqual(decisions, ["y"])
        XCTAssertNil(client.approval)
        XCTAssertTrue(client.status.contains("queued"))
    }

    func testMalformedOrTruncatedRequestCannotBeDecided() async {
        for value in [true, -1, 0, 1.5, "1"] as [Any] {
            let client = ApprovalClient(ownerProof: { self.proof }, request: { _, _, _ in self.snapshot(id: value) })
            await client.refresh(jobID: "job_example")
            XCTAssertNil(client.approval)
        }
        var posts = 0
        let client = ApprovalClient(ownerProof: { self.proof }, request: { _, method, _ in
            if method == "POST" { posts += 1 }
            return self.snapshot(truncated: true)
        })
        await client.refresh(jobID: "job_example")
        await client.decide(client.approval ?? missingApproval, allow: false)
        XCTAssertEqual(posts, 0)
    }

    func testAmbiguousFailureDoesNotRetryAndConflictClears() async {
        for code in [409, 503] {
            var posts = 0
            let client = ApprovalClient(ownerProof: { self.proof }, request: { _, method, _ in
                if method == "GET" { return self.snapshot() }
                posts += 1; throw HTTPStatusError(status: code)
            })
            await client.refresh(jobID: "job_example")
            await client.decide(client.approval ?? missingApproval, allow: false)
            await client.decide(client.approval ?? missingApproval, allow: false)
            XCTAssertEqual(posts, 1)
            XCTAssertNil(client.approval)
            XCTAssertNotNil(client.error)
        }
    }

    func testStopAndPairingChangeDiscardLateRead() async {
        for changeOwner in [false, true] {
            var owner = proof
            let entered = expectation(description: "read")
            var continuation: CheckedContinuation<[String: Any], Never>?
            let client = ApprovalClient(ownerProof: { owner }, request: { _, _, _ in
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            })
            let task = Task { await client.refresh(jobID: "job_example") }
            await fulfillment(of: [entered], timeout: 2)
            if changeOwner { owner = "kbp_" + String(repeating: "q", count: 40) } else { client.stop() }
            continuation?.resume(returning: snapshot())
            await task.value
            XCTAssertNil(client.approval)
            XCTAssertFalse(client.busy)
        }
    }

    func testUnpairedAndUnsafeJobNeverRequest() async {
        var calls = 0
        let client = ApprovalClient(ownerProof: { "" }, request: { _, _, _ in calls += 1; return self.snapshot() })
        await client.refresh(jobID: "job_example")
        await client.decide(client.approval ?? missingApproval, allow: true)
        XCTAssertEqual(calls, 0)
        let paired = ApprovalClient(ownerProof: { self.proof }, request: { _, _, _ in calls += 1; return self.snapshot() })
        await paired.refresh(jobID: "../permission")
        XCTAssertEqual(calls, 0)
    }

    func testBusyDecisionCannotDuplicateAndLateReceiptCannotRestoreAfterStop() async {
        var posts = 0
        let entered = expectation(description: "decision")
        var continuation: CheckedContinuation<[String: Any], Never>?
        let client = ApprovalClient(ownerProof: { self.proof }, request: { _, method, _ in
            if method == "GET" { return self.snapshot() }
            posts += 1
            return await withCheckedContinuation { continuation = $0; entered.fulfill() }
        })
        await client.refresh(jobID: "job_example")
        let decision = Task { await client.decide(client.approval ?? missingApproval, allow: false) }
        await fulfillment(of: [entered], timeout: 2)
        await client.decide(client.approval ?? missingApproval, allow: false)
        XCTAssertEqual(posts, 1)
        client.stop()
        continuation?.resume(returning: ["accepted": true])
        await decision.value
        XCTAssertNil(client.approval)
        XCTAssertEqual(client.status, "")
        XCTAssertFalse(client.busy)
    }

    func testReplacedPairingCannotDecidePreviouslyDisplayedRequest() async {
        var owner = proof
        var posts = 0
        let client = ApprovalClient(ownerProof: { owner }, request: { _, method, _ in
            if method == "POST" { posts += 1 }
            return self.snapshot()
        })
        await client.refresh(jobID: "job_example")
        owner = "kbp_" + String(repeating: "q", count: 40)
        await client.decide(client.approval ?? missingApproval, allow: true)
        XCTAssertEqual(posts, 0)
        XCTAssertNil(client.approval)
    }

    func testStaleSnapshotCannotAuthorizeDecision() async {
        var instant = Date(timeIntervalSince1970: 100)
        var posts = 0
        let client = ApprovalClient(ownerProof: { self.proof }, now: { instant }, request: { _, method, _ in
            if method == "POST" { posts += 1 }
            return self.snapshot()
        })
        await client.refresh(jobID: "job_example")
        instant.addTimeInterval(31)
        await client.decide(client.approval ?? missingApproval, allow: true)
        XCTAssertEqual(posts, 0)
        XCTAssertNil(client.approval)
    }

    func testOldConfirmationCannotDecideSameRequestIDOnAnotherJob() async {
        var posts = 0
        var selected = "job_example"
        let client = ApprovalClient(ownerProof: { self.proof }, request: { _, method, _ in
            if method == "POST" { posts += 1 }
            return ["approvals": [["job_id": selected, "request_id": 1,
                                    "description": "Inspect", "scope": "tool", "truncated": false]]]
        })
        await client.refresh(jobID: "job_example")
        let old = client.approval ?? missingApproval
        selected = "job_other"
        await client.refresh(jobID: selected)
        await client.decide(old, allow: true)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(client.approval?.jobID, "job_other")
    }

    func testFreshObservationAfterAmbiguousDecisionRequiresAnotherExplicitDecision() async {
        var posts = 0
        let client = ApprovalClient(ownerProof: { self.proof }, request: { _, method, _ in
            if method == "GET" { return self.snapshot() }
            posts += 1
            if posts == 1 { throw URLError(.timedOut) }
            return ["accepted": true]
        })
        await client.refresh(jobID: "job_example")
        let first = client.approval ?? missingApproval
        await client.decide(first, allow: false)
        await client.refresh(jobID: "job_example")
        XCTAssertEqual(posts, 1)
        XCTAssertNotEqual(client.approval, first)
        await client.decide(first, allow: false)
        XCTAssertEqual(posts, 1)
        await client.decide(client.approval ?? missingApproval, allow: false)
        XCTAssertEqual(posts, 2)
    }
}
