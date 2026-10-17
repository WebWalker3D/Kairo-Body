import XCTest
@testable import KairoBody

@MainActor
final class PrivateBodyClientTests: XCTestCase {
    func testPairingAcceptsSixDigitsWithLeadingZerosAndPasteFormatting() {
        XCTAssertEqual(PrivateBodyClient.normalizedChallenge("001234"), "001234")
        XCTAssertEqual(PrivateBodyClient.normalizedChallenge(" 001 234\n"), "001234")
        XCTAssertEqual(PrivateBodyClient.normalizedChallenge("001-234"), "001234")
        XCTAssertNil(PrivateBodyClient.normalizedChallenge("12345"))
        XCTAssertNil(PrivateBodyClient.normalizedChallenge("1234567"))
        XCTAssertNil(PrivateBodyClient.normalizedChallenge("１２３４５６"))
        XCTAssertNil(PrivateBodyClient.normalizedChallenge("123abc"))
        let old = "kbc_" + String(repeating: "a", count: 43)
        XCTAssertEqual(PrivateBodyClient.normalizedChallenge(old), old)
        XCTAssertFalse(PrivateBodyClient.validCredential("001234"))
    }

    func testGenericAgentTokenDoesNotProvisionOwnerAuthority() async {
        let settings = AppSettings()
        let client = PrivateBodyClient(settings: settings, readCredential: { "" }, writeCredential: { _ in })
        do { _ = try await client.openSession(); XCTFail("Owner proof required") }
        catch { XCTAssertFalse(client.isPaired) }
    }
    func testPairingCredentialMustHaveOpaqueOwnerPrefix() {
        XCTAssertFalse(PrivateBodyClient.validCredential("generic-agent-token"))
        XCTAssertFalse(PrivateBodyClient.validCredential("kbc_" + String(repeating: "a", count: 40)))
        XCTAssertTrue(PrivateBodyClient.validCredential("kbp_" + String(repeating: "a", count: 64)))
    }
    func testPrivateSessionIsSeparateFromFollowedEchoSession() {
        let settings = AppSettings()
        let client = PrivateBodyClient(settings: settings, readCredential: { "kbp_" + String(repeating: "a", count: 64) }, writeCredential: { _ in })
        XCTAssertNil(client.privateSessionID)
        XCTAssertTrue(client.isPaired)
    }
}
