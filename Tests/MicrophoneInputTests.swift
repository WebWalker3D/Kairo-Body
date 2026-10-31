import AVFoundation
import XCTest
@testable import KairoBody

final class MicrophoneInputTests: XCTestCase {
    func testInvalidSampleRatesNeverReachFrameworkTapInstaller() {
        let invalidRates: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for rate in invalidRates {
            var installations = 0
            XCTAssertThrowsError(try MicrophoneInput.installTap(sampleRate: rate, channelCount: 1) {
                installations += 1
            }, "Invalid sample rate \(rate) must fail before framework installation")
            XCTAssertEqual(installations, 0, "Invalid sample rate \(rate) reached the installer")
        }
    }

    func testZeroChannelsNeverReachFrameworkTapInstaller() {
        var installations = 0
        XCTAssertThrowsError(try MicrophoneInput.installTap(sampleRate: 48_000, channelCount: 0) {
            installations += 1
        })
        XCTAssertEqual(installations, 0)
    }

    func testValidMicrophoneFormatsInstallExactlyOnce() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            for channels in [AVAudioChannelCount(1), AVAudioChannelCount(2)] {
                var installations = 0
                try MicrophoneInput.installTap(sampleRate: rate, channelCount: channels) {
                    installations += 1
                }
                XCTAssertEqual(installations, 1)
            }
        }
    }
}
