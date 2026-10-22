import XCTest
@testable import KairoBody

/// Public-path topology is a deployment fact, not a guess. The installed
/// 1.0.x body app proved which paths connect.kairo.icu actually serves; these
/// pins keep a rewrite from ever sending the sensory socket or pairing redeem
/// back to the agent API root, where they answer 401.
final class DeploymentTopologyTests: XCTestCase {
    func testSensorySocketSitsBehindTheMemoryPrefix() {
        XCTAssertEqual(AppConfig.bodySocketURL, "wss://connect.kairo.icu/memory/v1/body/ws")
        XCTAssertEqual(AppConfig.bodyPairingRedeemURL,
                       "https://connect.kairo.icu/memory/v1/body/pairing/redeem")
    }

    func testDotObserverUsesTheAgentAPIPathThatAnswers101() {
        XCTAssertEqual(AppConfig.dotObserverURL, "wss://connect.kairo.icu/ws/body")
    }

    func testEveryHardcodedOriginParsesToItsPinnedHost() throws {
        for raw in [AppConfig.bodySocketURL, AppConfig.bodyPairingRedeemURL, AppConfig.dotObserverURL] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(url.host, "connect.kairo.icu")
            XCTAssertTrue(["wss", "https"].contains(url.scheme))
            XCTAssertFalse(url.path.isEmpty)
        }
    }
}
