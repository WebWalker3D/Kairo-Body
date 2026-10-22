import XCTest
@testable import KairoBody

/// The sensory service validates frame sub-objects by exact key set: the
/// location and device objects must carry every key, with null for unknown
/// values. Synthesized Codable drops nil keys, and the installed server
/// answers that with "invalid location schema" and a 1008 close seconds
/// after connect - the reconnect loop these tests exist to prevent.
final class WireEncodingTests: XCTestCase {
    private func json(_ value: Encodable) throws -> [String: Any] {
        let data = try BodyJSON.encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    func testLocationFrameCarriesEveryKeyEvenWithoutAFix() throws {
        let frame = LocationFrame(enabled: false, available: false, latitude: nil,
                                  longitude: nil, horizontalAccuracyM: nil, altitudeM: nil,
                                  speedMps: nil, courseDeg: nil, headingDeg: nil, observedAt: nil)
        let object = try json(frame)
        XCTAssertEqual(Set(object.keys), ["enabled", "available", "latitude", "longitude",
                                          "horizontalAccuracyM", "altitudeM", "speedMps",
                                          "courseDeg", "headingDeg", "observedAt"])
        for key in ["latitude", "longitude", "horizontalAccuracyM", "altitudeM",
                    "speedMps", "courseDeg", "headingDeg", "observedAt"] {
            XCTAssertTrue(object[key] is NSNull, "\(key) must be present as null")
        }
    }

    func testLocationFrameWithAFixStillCarriesEveryKey() throws {
        let frame = LocationFrame(enabled: true, available: true, latitude: 40.7, longitude: -74.0,
                                  horizontalAccuracyM: 10, altitudeM: nil, speedMps: nil,
                                  courseDeg: nil, headingDeg: 90, observedAt: "2026-10-22T01:00:00Z")
        let object = try json(frame)
        XCTAssertEqual(Set(object.keys), ["enabled", "available", "latitude", "longitude",
                                          "horizontalAccuracyM", "altitudeM", "speedMps",
                                          "courseDeg", "headingDeg", "observedAt"])
        XCTAssertEqual(object["latitude"] as? Double, 40.7)
        XCTAssertTrue(object["altitudeM"] is NSNull)
    }

    func testDeviceFrameCarriesBatteryLevelEvenWhenUnknown() throws {
        let frame = DeviceFrame(observedAt: "2026-10-22T01:00:00Z", batteryLevel: nil,
                                batteryState: "unknown", network: "wifi",
                                orientation: "portrait", screenBrightness: 0.5)
        let object = try json(frame)
        XCTAssertEqual(Set(object.keys), ["observedAt", "batteryLevel", "batteryState",
                                          "network", "orientation", "screenBrightness"])
        XCTAssertTrue(object["batteryLevel"] is NSNull)
    }
}
