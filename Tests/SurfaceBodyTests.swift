import XCTest
@testable import KairoBody

@MainActor
final class SurfaceDeliveryTests: XCTestCase {
    private struct Recorder {
        var paths: [String] = []
        var claimPayload: [String: Any] = ["job_id": "job_1", "target": "ipad_display",
                                           "kind": "text", "text": "Kairo's settled answer"]
        var results: [[String: Any]] = []
    }

    private func makeClient(_ recorder: Recorder, claimError: Error? = nil)
        -> (SurfaceDeliveryClient, () -> Recorder) {
        var box = recorder
        let client = SurfaceDeliveryClient(request: { path, _ async throws in
            box.paths.append(path)
            if path.contains("/claim") {
                if let claimError { throw claimError }
                return box.claimPayload
            }
            if path.hasSuffix("/result") {
                return ["accepted": true]
            }
            return ["accepted": true]
        })
        client.display = { _ in }
        return (client, { box })
    }

    func testDisplayDeliveryClaimsAppliesAndReceipts() async {
        let (client, box) = makeClient(Recorder())
        await client.deliver(jobID: "job_1", destination: "ipad_display")
        let recorded = box().paths
        XCTAssertTrue(recorded.contains("api/surfaces/ipad_display/deliveries/job_1/claim"))
        XCTAssertTrue(recorded.contains("api/surfaces/ipad_display/deliveries/job_1/result"))
    }

    func testInvalidClaimPayloadReceiptsFailureWithoutApplying() async {
        var recorder = Recorder()
        recorder.claimPayload["kind"] = "image"
        let (client, box) = makeClient(recorder)
        await client.deliver(jobID: "job_1", destination: "ipad_display")
        let paths = box().paths
        XCTAssertTrue(paths.contains { $0.hasSuffix("/result") })
        XCTAssertFalse(client.busy)
    }

    func testSameJobIsNeverDeliveredTwice() async {
        let (client, box) = makeClient(Recorder())
        await client.deliver(jobID: "job_1", destination: "ipad_display")
        let firstCount = box().paths.filter { $0.contains("/claim") }.count
        await client.deliver(jobID: "job_1", destination: "ipad_display")
        XCTAssertEqual(box().paths.filter { $0.contains("/claim") }.count, firstCount)
    }

    func testForegroundLossStopsDeliveryAndSilencesTheVoice() async {
        let (client, _) = makeClient(Recorder())
        client.setForeground(false)
        await client.deliver(jobID: "job_1", destination: "ipad_display")
        XCTAssertEqual(client.error, nil)
        XCTAssertFalse(client.busy)
    }

    func testPresenceLoopAnnouncesDisplayAndSpeechTargets() async throws {
        var called: [String] = []
        let client = SurfaceDeliveryClient(request: { path, _ async throws -> [String: Any] in
            called.append(path)
            return ["destinations": ["ipad_display", "ipad_speech"]]
        })
        try await client.prepare("kairo")
        XCTAssertTrue(called.contains("api/ipad/destinations"))
        XCTAssertTrue(called.contains("api/surfaces/ipad_display/presence"))
        XCTAssertTrue(called.contains("api/surfaces/ipad_speech/presence"))
        client.stop()
    }
}

final class BodyProtocolTests: XCTestCase {
    func testCapabilitiesSeparatePermissionFromAvailability() {
        var facts = BodyCapabilities(frontCameraEnabled: true, cameraPermission: "granted",
            microphoneEnabled: false, microphonePermission: "granted", speechEnabled: true,
            locationEnabled: true, locationPermission: "denied", locationObservedAt: nil,
            locationAccuracyM: nil, accuracyAuthorization: "full", appVersion: "2.0.0")
        facts.speechBusy = true
        facts.displayVisible = false
        let message = facts.makeMessage(sequence: 3, bodyID: "ipad-pro-2017",
                                        sessionID: "s", foreground: true)
        let interfaces = message["interfaces"] as? [String: Any]
        func availability(_ name: String) -> String {
            let value = interfaces?[name] as? [String: Any]
            let reason = value?["reason"] as? String ?? "-"
            return "\((value?["availability"] as? String ?? "?"))|\(reason)"
        }
        XCTAssertEqual(availability("front_camera"), "ready|-")
        XCTAssertEqual(availability("rear_camera"), "blocked|blocked_by_body")
        XCTAssertEqual(availability("microphone"), "disabled|permission_off")
        XCTAssertEqual(availability("speech"), "busy|speech_busy")
        XCTAssertEqual(availability("display"), "blocked|display_hidden")
        XCTAssertEqual(availability("location"), "disabled|permission_off")
        XCTAssertEqual(message["schema"] as? String, "kairo.body_capabilities.v1")
        XCTAssertEqual(message["permission_revision"] as? Int, 0)
    }

    func testActionLifecycleOnlyAdmitsLegalTransitions() {
        var lifecycle = BodyActionLifecycle()
        // The first event must be the device's acceptance.
        XCTAssertNotNil(lifecycle.transition(commandID: "c", phase: .accepted, detail: "x"))
        XCTAssertNotNil(lifecycle.transition(commandID: "c", phase: .started, detail: "x"))
        // A second accepted after started is a duplicate.
        XCTAssertNil(lifecycle.transition(commandID: "c", phase: .accepted, detail: "x"))
        XCTAssertNotNil(lifecycle.transition(commandID: "c", phase: .completed, detail: "x"))
        // Nothing follows a terminal phase, and duplicates collapse.
        XCTAssertNil(lifecycle.transition(commandID: "c", phase: .completed, detail: "x"))
        XCTAssertNil(lifecycle.transition(commandID: "c", phase: .started, detail: "x"))
        XCTAssertEqual(lifecycle.lastEvent(commandID: "c")?.sequence, 3)
        // A fresh command starts at accepted with sequence 1.
        XCTAssertNotNil(lifecycle.transition(commandID: "d", phase: .accepted, detail: "x"))
        XCTAssertEqual(lifecycle.lastEvent(commandID: "d")?.sequence, 1)
    }

    func testDisplayStateSnapshotIsScopedToThisBodyAndSession() throws {
        let json = Data("""
        {"type":"display_state","protocolVersion":"kairo-body/1","bodyID":"ipad-pro-2017",
         "sessionID":"s","state":"curious","headline":"Kairo","detail":"watching the room"}
        """.utf8)
        let snapshot = try JSONDecoder().decode(DisplayStateSnapshot.self, from: json)
        XCTAssertTrue(snapshot.isValid(bodyID: "ipad-pro-2017", sessionID: "s"))
        XCTAssertFalse(snapshot.isValid(bodyID: "other-body", sessionID: "s"))
        XCTAssertFalse(snapshot.isValid(bodyID: "ipad-pro-2017", sessionID: "other-session"))
    }

    func testFramesEncodeIdentityOnTheWire() throws {
        let frame = SensorFrame(bodyID: "b", sessionID: "s", sequence: 4,
            observedAt: "2026-10-21T00:00:00.000Z",
            motion: MotionFrame(available: true, observedAt: nil, sampleCount: 0, rollDeg: nil,
                pitchDeg: nil, yawDeg: nil, peakUserAccelerationG: nil, movement: "unknown",
                userAccelerationXG: nil, userAccelerationYG: nil, userAccelerationZG: nil,
                gravityXG: nil, gravityYG: nil, gravityZG: nil, rotationRateXRadPerSec: nil,
                rotationRateYRadPerSec: nil, rotationRateZRadPerSec: nil,
                magneticHeadingDeg: nil, magneticAccuracy: nil),
            location: LocationFrame(enabled: false, available: false, latitude: nil, longitude: nil,
                horizontalAccuracyM: nil, altitudeM: nil, speedMps: nil, courseDeg: nil,
                headingDeg: nil, observedAt: nil),
            pressure: PressureFrame(available: false, observedAt: nil, pressureHPa: nil,
                relativeAltitudeM: nil),
            device: DeviceFrame(observedAt: "2026-10-21T00:00:00.000Z", batteryLevel: nil,
                batteryState: "unknown", network: "wifi", orientation: "portrait",
                screenBrightness: 0.5),
            touches: [])
        let data = try BodyJSON.encoder.encode(frame)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "frame")
        XCTAssertEqual(object?["protocolVersion"] as? String, "kairo-body/1")
        XCTAssertEqual(object?["bodyID"] as? String, "b")
        XCTAssertEqual(object?["sequence"] as? Int, 4)
    }
}

@MainActor
final class SpeechTests: XCTestCase {
    func testShortAnswersStayInOneChunk() {
        XCTAssertEqual(SpeechService.chunks("Hello there."), ["Hello there."])
        XCTAssertEqual(SpeechService.chunks(""), [])
        XCTAssertEqual(SpeechService.chunks("   "), [])
    }

    func testLongAnswersSplitOnSentenceBoundariesAndKeepContent() {
        let answer = (1...12).map { "Sentence number \($0) explains something about the world." }
            .joined(separator: " ")
        let chunks = SpeechService.chunks(answer)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
        let rejoined = chunks.joined(separator: " ")
        XCTAssertEqual(rejoined, answer.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 400 })
    }

    func testWhitespaceCollapsesIntoSpeakableText() {
        XCTAssertEqual(SpeechService.chunks("first\n\tsecond   third"), ["first second third"])
    }
}

@MainActor
final class MiscTests: XCTestCase {
    func testPairingChallengeNormalization() {
        XCTAssertEqual(PairingClient.normalizedChallenge(" 482-913 \n"), "482913")
        XCTAssertEqual(PairingClient.normalizedChallenge("482913"), "482913")
        XCTAssertNil(PairingClient.normalizedChallenge("48 91"))
        XCTAssertNil(PairingClient.normalizedChallenge("abc123"))
    }

    func testOwnerCredentialShape() {
        XCTAssertTrue(PairingClient.validCredential("kbp_" + String(repeating: "a", count: 40)))
        XCTAssertFalse(PairingClient.validCredential("kbc_" + String(repeating: "a", count: 40)))
        XCTAssertFalse(PairingClient.validCredential("kbp_short"))
        XCTAssertFalse(PairingClient.validCredential("kbp_" + String(repeating: "a", count: 200)))
        XCTAssertFalse(PairingClient.validCredential("kbp_has spaces"))
    }

    func testExpressionPaletteFallsBackToCalm() {
        XCTAssertEqual(ExpressionPalette.forState("curious").name, "curious")
        XCTAssertEqual(ExpressionPalette.forState("Mysterious").name, "calm")
        XCTAssertEqual(ExpressionPalette.forState("").energy, 0.35, accuracy: 0.001)
        let colours = ExpressionPalette.forState("calm").rgb
        XCTAssertEqual(colours.primary.x, 95.0 / 255.0, accuracy: 0.001)
    }

    func testTroubleCauseStringsStayReadable() {
        XCTAssertEqual(TranscriptFeedClient.troubleCause(HTTPStatusError(status: 503)), "HTTP 503")
        XCTAssertEqual(TranscriptFeedClient.troubleCause(MalformedResponse()), "unreadable response")
        XCTAssertEqual(TranscriptFeedClient.troubleCause(URLError(.timedOut)), "timed out")
    }
}
