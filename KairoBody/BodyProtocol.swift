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

    private enum CodingKeys: String, CodingKey {
        case enabled, available, latitude, longitude, horizontalAccuracyM
        case altitudeM, speedMps, courseDeg, headingDeg, observedAt
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(enabled, forKey: .enabled)
        try fields.encode(available, forKey: .available)
        try fields.encode(latitude, forKey: .latitude)
        try fields.encode(longitude, forKey: .longitude)
        try fields.encode(horizontalAccuracyM, forKey: .horizontalAccuracyM)
        try fields.encode(altitudeM, forKey: .altitudeM)
        try fields.encode(speedMps, forKey: .speedMps)
        try fields.encode(courseDeg, forKey: .courseDeg)
        try fields.encode(headingDeg, forKey: .headingDeg)
        try fields.encode(observedAt, forKey: .observedAt)
    }
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

    private enum CodingKeys: String, CodingKey {
        case observedAt, batteryLevel, batteryState, network, orientation, screenBrightness
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(observedAt, forKey: .observedAt)
        try fields.encode(batteryLevel, forKey: .batteryLevel)
        try fields.encode(batteryState, forKey: .batteryState)
        try fields.encode(network, forKey: .network)
        try fields.encode(orientation, forKey: .orientation)
        try fields.encode(screenBrightness, forKey: .screenBrightness)
    }
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

enum BodyJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func now() -> String { iso8601.string(from: Date()) }
}
