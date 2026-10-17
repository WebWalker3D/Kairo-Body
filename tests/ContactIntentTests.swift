import XCTest
@testable import KairoBody

final class ContactIntentTests: XCTestCase {
    func testMeasuredContactBoundariesAndCancellation() {
        XCTAssertEqual(ContactIntent.classify(durationMs: 999, pathLength: 0, cancelled: false), .tap)
        XCTAssertEqual(ContactIntent.classify(durationMs: 1000, pathLength: 0, cancelled: false), .sustainedContact)
        XCTAssertEqual(ContactIntent.classify(durationMs: 3000, pathLength: 0.01, cancelled: false), .drag)
        XCTAssertEqual(ContactIntent.classify(durationMs: 3000, pathLength: 1, cancelled: true), .cancelled)
    }
    func testControlsCancelledAndBusyContactsNeverSubmit() {
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: false, cancelled: false, conversationBusy: false))
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: true, conversationBusy: false))
        XCTAssertFalse(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: false, conversationBusy: true))
        XCTAssertTrue(ContactIntent.shouldSubmit(isBodySurface: true, cancelled: false, conversationBusy: false))
    }
}
