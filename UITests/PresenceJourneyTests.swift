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
        app.buttons["Output: Kairo decides"].tap()
        app.buttons["Speak here"].tap()
        app.buttons["Conversation"].tap()
        let continuedDraft = app.descendants(matching: .any).matching(identifier: "conversationComposer").firstMatch
        XCTAssertEqual(continuedDraft.value as? String, "A draft stays on this body")
        let output = app.descendants(matching: .any).matching(identifier: "conversationOutput").firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertTrue(output.label.contains("Speak here") || (output.value as? String)?.contains("Speak here") == true)
        output.tap()
        app.buttons["Kairo decides"].tap()
        app.buttons["Presence"].tap()
        XCTAssertTrue(app.buttons["Output: Kairo decides"].exists)
        app.buttons["Conversation"].tap()
        XCTAssertTrue(app.staticTexts["Conversations"].waitForExistence(timeout: 5))
        capture("Conversation-portrait")
        app.buttons["Systems"].tap()
        XCTAssertTrue(app.buttons["Close systems"].waitForExistence(timeout: 5))
        capture("Systems-panel")
        app.buttons["Private"].tap()
        XCTAssertTrue(app.staticTexts["Private room"].waitForExistence(timeout: 5))
        capture("Private-room")
        app.buttons["Systems"].tap()
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
        app.buttons["Systems"].tap()
        app.buttons["Settings"].tap()
        if transcriptSwitch.value as? String == "0" {
            transcriptSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(transcriptSwitch.value as? String, "1")
    }

    @MainActor
    func testLookOpensWithinPresenceAndCancelPreservesDraft() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Not now (stages stay local)"].waitForExistence(timeout: 5) {
            app.buttons["Not now (stages stay local)"].tap()
        }
        let composer = app.descendants(matching: .any).matching(identifier: "stageComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Look at this with me")
        let camera = app.buttons["Show Kairo something"]
        XCTAssertTrue(camera.exists, "Camera sharing must be available in Presence")
        guard camera.exists else { return }
        camera.tap()
        XCTAssertTrue(app.buttons["Front camera"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Discuss this image"].exists)
        capture("Presence-look-sheet")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Look at this with me")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
