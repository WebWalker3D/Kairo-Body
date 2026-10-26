import XCTest

final class PresenceJourneyTests: XCTestCase {
    @MainActor
    func testPresenceInPortraitLandscapeAndConversation() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Not now (stages stay local)"].waitForExistence(timeout: 5) { app.buttons["Not now (stages stay local)"].tap() }
        XCTAssertTrue(app.buttons["Presence"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["K A I R O"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open systems"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "stageComposer").firstMatch.exists)
        capture("Presence-landscape")
        XCUIDevice.shared.orientation = .portrait
        capture("Presence-portrait")
        let composer = app.descendants(matching: .any).matching(identifier: "stageComposer").firstMatch
        composer.tap()
        composer.typeText("A draft stays on this body")
        XCTAssertTrue(app.buttons["Send to Kairo"].isHittable)
        capture("Presence-keyboard")
        app.buttons["Open systems"].tap()
        XCTAssertTrue(app.buttons["Close systems"].waitForExistence(timeout: 5))
        capture("Presence-systems")
        app.buttons["Close systems"].tap()
        app.buttons["Conversation"].tap()
        XCTAssertTrue(app.staticTexts["Conversations"].waitForExistence(timeout: 5))
        capture("Conversation-portrait")
        app.buttons["Private"].tap()
        XCTAssertTrue(app.staticTexts["Private room"].waitForExistence(timeout: 5))
        capture("Private-room")
        app.buttons["Settings"].tap()
        let transcriptSwitch = app.switches["Show the shared conversation"]
        XCTAssertTrue(transcriptSwitch.waitForExistence(timeout: 5))
        if transcriptSwitch.value as? String == "1" {
            transcriptSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(transcriptSwitch.value as? String, "0")
        app.buttons["Presence"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["Open systems"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sharedConversationHidden").firstMatch.waitForExistence(timeout: 5))
        capture("Presence-private-preview")
        app.buttons["Close systems"].tap()
        app.buttons["Settings"].tap()
        if transcriptSwitch.value as? String == "0" {
            transcriptSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(transcriptSwitch.value as? String, "1")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
