import XCTest
@testable import KairoBody

@MainActor
final class SharedVisualContextTests: XCTestCase {
    func testSessionChangeRejectsLateImageBinding() {
        let context = SharedVisualContext()
        let old = context.beginSelection(sessionID: "old")
        _ = context.beginSelection(sessionID: "new")
        XCTAssertFalse(context.bind(attachmentID: "image", sha256: String(repeating: "a", count: 64),
            source: .selectedImage, observedAt: Date(), sessionID: "old", generation: old))
        XCTAssertEqual(context.attachmentIDs(for: "new"), [])
    }
    func testReplaceAndClearRemoveOldAttachment() {
        let context = SharedVisualContext()
        let first = context.beginSelection(sessionID: "session")
        XCTAssertTrue(context.bind(attachmentID: "one", sha256: String(repeating: "a", count: 64),
            source: .frontCamera, observedAt: Date(), sessionID: "session", generation: first))
        let second = context.beginSelection(sessionID: "session")
        XCTAssertFalse(context.bind(attachmentID: "late", sha256: String(repeating: "a", count: 64),
            source: .frontCamera, observedAt: Date(), sessionID: "session", generation: first))
        XCTAssertTrue(context.bind(attachmentID: "two", sha256: String(repeating: "b", count: 64),
            source: .selectedImage, observedAt: Date(), sessionID: "session", generation: second))
        XCTAssertEqual(context.attachmentIDs(for: "session"), ["two"])
        XCTAssertEqual(context.attachmentIDs(for: "other"), [])
        context.clear()
        XCTAssertEqual(context.attachmentIDs(for: "session"), [])
    }
    func testUploadFailureKeepsQuestion() {
        let context = SharedVisualContext()
        context.question = "What is in this image?"
        _ = context.beginSelection(sessionID: "session")
        context.fail("Upload failed")
        XCTAssertEqual(context.question, "What is in this image?")
        XCTAssertEqual(context.attachmentIDs(for: "session"), [])
    }
}
