import Foundation

@main
enum BodyProtocolContractTests {
    static func main() throws {
        let location = LocationFrame(
            enabled: false, available: false, latitude: nil, longitude: nil,
            horizontalAccuracyM: nil, altitudeM: nil, speedMps: nil,
            courseDeg: nil, headingDeg: nil, observedAt: nil
        )
        let encodedLocation = try JSONEncoder().encode(location)
        let locationJSON = try JSONSerialization.jsonObject(with: encodedLocation) as! [String: Any]
        for field in ["latitude", "longitude", "horizontalAccuracyM", "altitudeM",
                      "speedMps", "courseDeg", "headingDeg", "observedAt"] {
            precondition(locationJSON[field] is NSNull, "Location field \(field) must encode as null")
        }

        let device = DeviceFrame(observedAt: "2026-09-24T00:00:00.000Z",
                                 batteryLevel: nil, batteryState: "unknown",
                                 network: "wifi", orientation: "portrait",
                                 screenBrightness: 0.5)
        let encodedDevice = try JSONEncoder().encode(device)
        let deviceJSON = try JSONSerialization.jsonObject(with: encodedDevice) as! [String: Any]
        precondition(deviceJSON["batteryLevel"] is NSNull,
                     "Unavailable battery must encode as null")
        let motion = MotionFrame(
            available: true, observedAt: "2026-09-24T00:00:00.000Z", sampleCount: 60,
            rollDeg: 1, pitchDeg: 2, yawDeg: 3, peakUserAccelerationG: 0.12,
            movement: "moving", userAccelerationXG: 0.01, userAccelerationYG: -0.02,
            userAccelerationZG: 0.03, gravityXG: 0, gravityYG: -1, gravityZG: 0,
            rotationRateXRadPerSec: 0.1, rotationRateYRadPerSec: 0.2,
            rotationRateZRadPerSec: 0.7, magneticHeadingDeg: 44,
            magneticAccuracy: "high"
        )
        let motionJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(motion)) as! [String: Any]
        precondition(motionJSON["userAccelerationYG"] as? Double == -0.02)
        precondition(motionJSON["rotationRateZRadPerSec"] as? Double == 0.7)
        precondition(motionJSON["magneticHeadingDeg"] as? Double == 44)
        precondition(motionJSON["magneticAccuracy"] as? String == "high")
        print("Body protocol JSON contract passed")
    }
}
