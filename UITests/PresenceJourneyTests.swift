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
        capture("Presence-landscape")
        XCUIDevice.shared.orientation = .portrait
        capture("Presence-portrait")
        app.buttons["Conversation"].tap()
        XCTAssertTrue(app.staticTexts["Conversations"].waitForExistence(timeout: 5))
        capture("Conversation-portrait")
        app.buttons["Private"].tap()
        XCTAssertTrue(app.staticTexts["Private room"].waitForExistence(timeout: 5))
        capture("Private-room")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
