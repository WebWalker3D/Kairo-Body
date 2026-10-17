import XCTest
@testable import KairoBody

@MainActor
final class SurfaceDeliveryClientTests: XCTestCase {
    func testObscuredDisplayCannotAcknowledgeDelivery() async {
        var outcomes: [String] = []
        var displays = 0
        let client = SurfaceDeliveryClient(request: { _, body in
            if let status = body?["status"] as? String { outcomes.append(status); return [:] }
            return ["kind": "text", "text": "Hello", "job_id": "hidden", "target": "ipad_display"]
        }, display: { _ in displays += 1 }, speak: { _, _ in false }, stopSpeech: {})
        client.setDisplayVisible(false)
        await client.deliver(jobID: "hidden", destination: "ipad_display")
        XCTAssertEqual(displays, 0)
        XCTAssertEqual(outcomes, ["failed"])
    }

    func testBackgroundDuringPrepareCannotRenewPresence() async throws {
        var release: CheckedContinuation<[String: Any], Never>?
        var presenceCalls = 0
        let client = SurfaceDeliveryClient(request: { path, _ in
            if path == "api/ipad/destinations" {
                return await withCheckedContinuation { release = $0 }
            }
            presenceCalls += 1
            return [:]
        }, display: { _ in }, speak: { _, _ in false }, stopSpeech: {})
        let preparation = Task { try await client.prepare("kairo") }
        while release == nil { await Task.yield() }
        client.setForeground(false)
        release?.resume(returning: ["destinations": ["ipad_display"]])
        _ = try? await preparation.value
        XCTAssertEqual(presenceCalls, 0)
    }

    func testBackgroundNeverClaimsOrExecutesLateSettledOutput() async {
        var requests = 0
        let client = SurfaceDeliveryClient(request: { _, _ in requests += 1; return [:] },
            display: { _ in XCTFail("Background display") }, speak: { _, _ in XCTFail("Background speech"); return true }, stopSpeech: {})
        client.setForeground(false)
        await client.deliver(jobID: "late-job", destination: "ipad_speech")
        XCTAssertEqual(requests, 0)
    }

    func testDeclineNeverClaimsAndDuplicateDoesNotReplay() async throws {
        var claims = 0
        var displays = 0
        var outcomes: [String] = []
        let client = SurfaceDeliveryClient(
            request: { _, body in
                if body?["status"] != nil { outcomes.append(body?["status"] as? String ?? ""); return [:] }
                claims += 1
                return ["kind": "text", "text": "Hello", "job_id": "job", "target": "ipad_display"]
            }, display: { _ in displays += 1 }, speak: { _, _ in false }, stopSpeech: {})
        client.setDisplayVisible(true)
        await client.deliver(jobID: "job", destination: "silent")
        XCTAssertEqual(claims, 0)
        await client.deliver(jobID: "job", destination: "ipad_display")
        await client.deliver(jobID: "job", destination: "ipad_display")
        XCTAssertEqual(claims, 1)
        XCTAssertEqual(displays, 1)
        XCTAssertEqual(outcomes, ["delivered"])
    }

    func testSpeechAcceptanceIsNotDeliveredUntilPlayerCompletes() async throws {
        var callback: ((ActionPhase, String) -> Void)?
        var outcomes: [String] = []
        let client = SurfaceDeliveryClient(request: { _, body in
            if let status = body?["status"] as? String { outcomes.append(status); return [:] }
            return ["kind": "text", "text": "Hello", "job_id": "voice", "target": "ipad_speech"]
        }, display: { _ in XCTFail("Wrong destination") }, speak: { _, onEvent in callback = onEvent; return true }, stopSpeech: {})
        await client.deliver(jobID: "voice", destination: "ipad_speech")
        XCTAssertEqual(outcomes, [])
        callback?(.started, "player started")
        await Task.yield()
        XCTAssertEqual(outcomes, [])
        callback?(.completed, "player finished")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(outcomes, ["delivered"])
    }
}
