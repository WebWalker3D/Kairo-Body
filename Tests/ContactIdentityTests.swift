import XCTest
@testable import KairoBody

/// The touch reflex only works when the claim names the contact the server
/// observed in the sensory frame. These pin the id rules both sides share.
@MainActor
final class ContactIdentityTests: XCTestCase {
    // server/memory/ipad_body.py _CONTACT_ID
    private let serverPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")

    func testContactIDsAreUniqueAndAcceptedByTheServer() {
        let model = AppModel()
        let ids = (0..<50).map { _ in model.nextContactID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(serverPattern.firstMatch(in: id, range: range), id)
        }
    }

    func testIDsDifferAcrossLaunches() {
        // A remounted stage used to restart at "stage-1", colliding with a
        // contact the server had already consumed.
        XCTAssertNotEqual(AppModel().nextContactID(), AppModel().nextContactID())
    }

    func testMissingCredentialIsNeverARevocation() {
        XCTAssertEqual(RequestFailure.kind(of: CredentialUnavailable()), .transient)
        XCTAssertEqual(RequestFailure.kind(of: HTTPStatusError(status: 401)), .authorizationLost)
    }

    func testEmptyAgentTokenSendsNothingAndIsTransient() async {
        let http = KairoHTTP(credentials: { ("", "") })
        do {
            _ = try await http.agentObject("api/platform")
            XCTFail("an empty token must not produce a request")
        } catch {
            XCTAssertTrue(error is CredentialUnavailable)
            XCTAssertEqual(RequestFailure.kind(of: error), .transient)
        }
    }
}

final class TouchSurfaceTests: XCTestCase {
    func testStrokesOffTheRingArePinnedToTheSurface() {
        XCTAssertEqual(SensorManager.onSurface(-0.2, 1.4).0, 0)
        XCTAssertEqual(SensorManager.onSurface(-0.2, 1.4).1, 1)
        XCTAssertEqual(SensorManager.onSurface(0.25, 0.75).0, 0.25)
        XCTAssertEqual(SensorManager.onSurface(.nan, .infinity).0, 0.5)
    }
}
