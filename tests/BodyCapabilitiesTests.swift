import XCTest
@testable import KairoBody

final class BodyCapabilitiesTests: XCTestCase {
    func testGrantedPermissionWithoutFixDoesNotInventLocationData() throws {
        let capabilities = BodyCapabilities(frontCameraEnabled: true, cameraPermission: "granted",
            microphoneEnabled: false, microphonePermission: "denied", speechEnabled: true,
            locationEnabled: true, locationPermission: "granted", locationObservedAt: nil,
            locationAccuracyM: nil, accuracyAuthorization: "full", appVersion: "test")
        let message = capabilities.makeMessage(sequence: 1, bodyID: "body", sessionID: "session", foreground: true)
        let location = try XCTUnwrap(message["location"] as? [String: Any])
        XCTAssertTrue(location["observed_at"] is NSNull)
        XCTAssertTrue(location["horizontal_accuracy_m"] is NSNull)
        let interfaces = try XCTUnwrap(message["interfaces"] as? [String: [String: Any]])
        XCTAssertEqual(interfaces["location"]?["availability"] as? String, "ready")
        XCTAssertEqual(interfaces["rear_camera"]?["availability"] as? String, "blocked")
    }

    func testBusySpeechIsNotReportedReady() throws {
        var facts = BodyCapabilities(frontCameraEnabled: false, cameraPermission: "denied",
            microphoneEnabled: false, microphonePermission: "denied", speechEnabled: true,
            locationEnabled: false, locationPermission: "denied", locationObservedAt: nil,
            locationAccuracyM: nil, accuracyAuthorization: "full", appVersion: "test")
        facts.speechBusy = true
        facts.displayVisible = false
        let message = facts.makeMessage(sequence: 1, bodyID: "body", sessionID: "session", foreground: true)
        let interfaces = try XCTUnwrap(message["interfaces"] as? [String: [String: Any]])
        XCTAssertEqual(interfaces["speech"]?["availability"] as? String, "busy")
        XCTAssertEqual(interfaces["speech"]?["reason"] as? String, "speech_busy")
        XCTAssertEqual(interfaces["display"]?["availability"] as? String, "blocked")
        XCTAssertEqual(interfaces["display"]?["reason"] as? String, "display_hidden")
    }

    func testBackgroundAndDisabledPermissionCannotBeReady() throws {
        let capabilities = BodyCapabilities(frontCameraEnabled: true, cameraPermission: "denied",
            microphoneEnabled: true, microphonePermission: "granted", speechEnabled: true,
            locationEnabled: false, locationPermission: "granted", locationObservedAt: nil,
            locationAccuracyM: nil, accuracyAuthorization: "reduced", appVersion: "test")
        let message = capabilities.makeMessage(sequence: 2, bodyID: "body", sessionID: "session", foreground: false)
        let interfaces = try XCTUnwrap(message["interfaces"] as? [String: [String: Any]])
        XCTAssertEqual(interfaces["front_camera"]?["availability"] as? String, "disabled")
        XCTAssertEqual(interfaces["microphone"]?["availability"] as? String, "background")
        XCTAssertEqual(interfaces["location"]?["availability"] as? String, "disabled")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: message))
    }
}
