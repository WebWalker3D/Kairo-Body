import XCTest
@testable import KairoBody

@MainActor
final class SleepWakeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "sleep-wake-test-\(UUID().uuidString)")!
    }

    func testWakeUsesOnlyEmergencyControlAndValidatesReceipt() async {
        var calls = 0
        let control = SleepWakeControl(defaults: defaults(), paired: { true }, request: { path, method, body in
            calls += 1
            XCTAssertEqual(path, "api/sleep/wake")
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(Set(body.keys), ["request_key", "kind", "reason"])
            XCTAssertEqual(body["kind"] as? String, "emergency")
            return ["request_key": body["request_key"]!, "episode": "new", "previous_episode": "old", "revision": 7]
        })
        await control.wake()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(control.message, "Kairo's waking is complete. Continuity checks passed.")
        XCTAssertFalse(control.busy)
    }

    func testUnpairedControlNeverSends() async {
        let control = SleepWakeControl(defaults: defaults(), paired: { false }, request: { _, _, _ in
            XCTFail("unpaired request must not leave the app")
            return [:]
        })
        await control.wake()
        XCTAssertEqual(control.message, "Pair this iPad with Kairo first.")
    }

    func testPendingIsNotCompletion() async {
        let control = SleepWakeControl(defaults: defaults(), paired: { true }, request: { _, _, body in
            ["pending": true, "request_key": body["request_key"]!, "episode": "old"]
        })
        await control.wake()
        XCTAssertTrue(control.message.contains("pending"))
        XCTAssertFalse(control.message.contains("is complete"))
    }

    func testTimeoutKeepsSameRequestAcrossClientRestart() async {
        let storage = defaults()
        var firstKey: String?
        let first = SleepWakeControl(defaults: storage, paired: { true }, request: { _, _, body in
            firstKey = body["request_key"] as? String
            throw URLError(.timedOut)
        })
        await first.wake()
        XCTAssertTrue(first.message.contains("unconfirmed"))
        let second = SleepWakeControl(defaults: storage, paired: { true }, request: { _, _, body in
            XCTAssertEqual(body["request_key"] as? String, firstKey)
            return ["request_key": body["request_key"]!, "episode": "new", "previous_episode": "old", "revision": 7]
        })
        await second.wake()
        XCTAssertTrue(second.message.contains("is complete"))
    }

    func testMalformedReceiptDoesNotClaimCompletion() async {
        for response: [String: Any] in [[:], ["episode": "new"], ["request_key": "different", "episode": "new", "previous_episode": "old", "revision": 7]] {
            let control = SleepWakeControl(defaults: defaults(), paired: { true }, request: { _, _, _ in response })
            await control.wake()
            XCTAssertTrue(control.message.contains("unconfirmed"))
        }
    }

    func testDenialAndSafetyHoldAreNotSuccessAndAreNotRetriedAutomatically() async {
        for status in [401, 403, 409, 500] {
            var calls = 0
            let control = SleepWakeControl(defaults: defaults(), paired: { true }, request: { _, _, _ in
                calls += 1
                throw HTTPStatusError(status: status)
            })
            await control.wake()
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(control.message.contains("\(status)"))
            XCTAssertFalse(control.message.contains("is complete"))
        }
    }
}
