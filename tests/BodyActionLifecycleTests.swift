import XCTest
@testable import KairoBody

final class BodyActionLifecycleTests: XCTestCase {
    func testAcceptanceIsIntermediateAndDuplicatesDoNotReplay() {
        var lifecycle = BodyActionLifecycle()
        XCTAssertEqual(lifecycle.transition(commandID: "one", phase: .accepted, detail: "queued")?.sequence, 1)
        XCTAssertNil(lifecycle.transition(commandID: "one", phase: .accepted, detail: "queued"))
        XCTAssertNil(lifecycle.transition(commandID: "one", phase: .completed, detail: "premature"))
        XCTAssertEqual(lifecycle.transition(commandID: "one", phase: .started, detail: "playing")?.sequence, 2)
        XCTAssertEqual(lifecycle.transition(commandID: "one", phase: .completed, detail: "finished")?.sequence, 3)
        XCTAssertNil(lifecycle.transition(commandID: "one", phase: .started, detail: "replayed"))
    }
    func testStopCannotBeUndoneByLateSynthesis() {
        var lifecycle = BodyActionLifecycle()
        _ = lifecycle.transition(commandID: "one", phase: .accepted, detail: "synthesizing")
        XCTAssertEqual(lifecycle.transition(commandID: "one", phase: .stopped, detail: "user stopped")?.phase, .stopped)
        XCTAssertNil(lifecycle.transition(commandID: "one", phase: .started, detail: "late audio"))
        XCTAssertNil(lifecycle.transition(commandID: "one", phase: .completed, detail: "late finish"))
    }
}
