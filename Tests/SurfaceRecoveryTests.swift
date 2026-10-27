import XCTest
@testable import KairoBody

@MainActor
final class SurfaceRecoveryTests: XCTestCase {
    func testBusySurfaceExplainsWhySecondOutputCannotPlay() async {
        let client = SurfaceDeliveryClient(request: { path, _ in
            ["job_id": path.contains("job_first") ? "job_first" : "job_second",
             "target": "ipad_speech", "kind": "text", "text": "Answer"]
        })
        var played = 0
        client.speak = { _, _ in played += 1; return true }
        await client.deliver(jobID: "job_first", destination: "ipad_speech")
        await client.deliver(jobID: "job_second", destination: "ipad_speech")
        XCTAssertEqual(played, 1)
        XCTAssertNotNil(client.error, "A refused answer must never silently disappear")
        client.stop()
    }

    func testTransientReceiptFailureRetriesReceiptWithoutRepeatingDisplay() async {
        var receipts = 0
        var displays = 0
        let client = SurfaceDeliveryClient(request: { path, _ in
            if path.hasSuffix("/claim") {
                return ["job_id": "job_one", "target": "ipad_display", "kind": "text", "text": "Answer"]
            }
            receipts += 1
            if receipts == 1 { throw URLError(.timedOut) }
            return [:]
        })
        client.display = { _ in displays += 1; return true }
        await client.deliver(jobID: "job_one", destination: "ipad_display")
        XCTAssertEqual(displays, 1)
        XCTAssertEqual(receipts, 2)
        XCTAssertNil(client.error)
    }

    func testFailedClaimCanBeRetriedWithoutReplayingCompletedOutput() async {
        var claims = 0
        var displays = 0
        let client = SurfaceDeliveryClient(request: { path, _ in
            if path.hasSuffix("/claim") {
                claims += 1
                if claims == 1 { throw HTTPStatusError(status: 503) }
                return ["job_id": "job_one", "target": "ipad_display", "kind": "text", "text": "Answer"]
            }
            return [:]
        })
        client.display = { _ in displays += 1; return true }
        await client.deliver(jobID: "job_one", destination: "ipad_display")
        await client.deliver(jobID: "job_one", destination: "ipad_display")
        await client.deliver(jobID: "job_one", destination: "ipad_display")
        XCTAssertEqual(claims, 2)
        XCTAssertEqual(displays, 1)
    }
}
