import Foundation

struct TouchEvent: Codable {
    let kind: String
    let observedAt: String
    let x: Double
    let y: Double
    let durationMs: Int?
    let contactID: String?
    let pathDeltaNormalized: Double?
}

struct MotionFrame: Codable {
    let available: Bool
    let observedAt: String?
    let sampleCount: Int
    let rollDeg: Double?
    let pitchDeg: Double?
    let yawDeg: Double?
    let peakUserAccelerationG: Double?
    let movement: String
    let userAccelerationXG: Double?
    let userAccelerationYG: Double?
    let userAccelerationZG: Double?
    let gravityXG: Double?
    let gravityYG: Double?
    let gravityZG: Double?
    let rotationRateXRadPerSec: Double?
    let rotationRateYRadPerSec: Double?
    let rotationRateZRadPerSec: Double?
    let magneticHeadingDeg: Double?
    let magneticAccuracy: String?
}

struct LocationFrame: Codable {
    let enabled: Bool
    let available: Bool
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracyM: Double?
    let altitudeM: Double?
    let speedMps: Double?
    let courseDeg: Double?
    let headingDeg: Double?
    let observedAt: String?
}

struct PressureFrame: Codable {
    let available: Bool
    let observedAt: String?
    let pressureHPa: Double?
    let relativeAltitudeM: Double?
}

struct DeviceFrame: Codable {
    let observedAt: String
    let batteryLevel: Double?
    let batteryState: String
    let network: String
    let orientation: String
    let screenBrightness: Double
}

struct SensorFrame: Codable {
    let type = "frame"
    let protocolVersion = "kairo-body/1"
    let bodyID: String
    let sessionID: String
    let sequence: Int
    let observedAt: String
    let motion: MotionFrame
    var location: LocationFrame
    let pressure: PressureFrame
    let device: DeviceFrame
    let touches: [TouchEvent]
}

struct HelloFrame: Codable {
    let type = "hello"
    let protocolVersion = "kairo-body/1"
    let bodyID: String
    let sessionID: String
    let appVersion: String
    let platform = "iPadOS"
    let capabilities: [String]
}

struct DisplayStateRequest: Encodable {
    let type = "get_display_state"
    let protocolVersion = "kairo-body/1"
    let bodyID: String
    let sessionID: String
}

struct DisplayStateSnapshot: Decodable {
    let type: String
    let protocolVersion: String
    let bodyID: String
    let sessionID: String
    let state: String
    let headline: String
    let detail: String

    func isValid(bodyID: String, sessionID: String) -> Bool {
        type == "display_state" && protocolVersion == "kairo-body/1" &&
        self.bodyID == bodyID && self.sessionID == sessionID &&
        (1...64).contains(state.count) &&
        (1...160).contains(headline.count) && detail.count <= 500
    }
}

struct CameraFrame: Codable {
    let type = "camera_frame"
    let protocolVersion = "kairo-body/1"
    let bodyID: String
    let sessionID: String
    let commandID: String?
    let sequence: Int
    let observedAt: String
    let camera: String
    let mimeType = "image/jpeg"
    let width: Int
    let height: Int
    let jpegBase64: String
}

struct CommandResult: Codable {
    let type = "command_result"
    let protocolVersion = "kairo-body/1"
    let bodyID: String
    let sessionID: String
    let commandID: String
    let ok: Bool
    let detail: String
}

enum ContactIntent: String {
    case tap, sustainedContact, drag, cancelled
    static func classify(durationMs: Int, pathLength: Double, cancelled: Bool) -> ContactIntent {
        if cancelled { return .cancelled }
        if pathLength >= 0.01 { return .drag }
        return durationMs >= 1000 ? .sustainedContact : .tap
    }
    static func shouldSubmit(isBodySurface: Bool, cancelled: Bool, conversationBusy: Bool) -> Bool {
        isBodySurface && !cancelled && !conversationBusy
    }
}
