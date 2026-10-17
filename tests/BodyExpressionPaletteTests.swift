import XCTest
@testable import KairoBody

final class BodyExpressionPaletteTests: XCTestCase {
    func testExpressionColorsMatchKairoBodyPresets() {
        let expected: [String: (String, String)] = [
            "calm": ("#5fb3ff", "#e6f8ff"),
            "curious": ("#a78bfa", "#7dd3fc"),
            "focused": ("#6ee7b7", "#f8fafc"),
            "joyful": ("#fbbf24", "#f9a8d4"),
            "concerned": ("#fb7185", "#fbbf24"),
            "playful": ("#f9a8d4", "#fbbf24"),
            "reflective": ("#c4b5fd", "#7dd3fc"),
            "resolute": ("#6ee7b7", "#f8fafc"),
        ]
        for (state, colors) in expected {
            let palette = BodyExpressionPalette.forState(state)
            XCTAssertEqual(palette.primaryHex, colors.0, state)
            XCTAssertEqual(palette.accentHex, colors.1, state)
        }
        XCTAssertNotEqual(BodyExpressionPalette.forState("calm").primaryHex,
                          BodyExpressionPalette.forState("reflective").primaryHex)
    }

    func testUnknownStateKeepsNeutralFallback() {
        let palette = BodyExpressionPalette.forState("present")
        XCTAssertEqual(palette.primaryHex, "#5fb3ff")
        XCTAssertEqual(palette.accentHex, "#e6f8ff")
    }

    func testInitialDisplayDoesNotClaimAnExpression() {
        XCTAssertEqual(BodyClient.DisplayState().state, "awaiting state")
    }

    func testPulledDisplayStateBindsToClientTransport() throws {
        let good = Data("""
        {"type":"display_state","protocolVersion":"kairo-body/1","bodyID":"ipad",
         "sessionID":"session-a","state":"reflective","headline":"Kairo","detail":"Current expression: reflective"}
        """.utf8)
        let snapshot = try JSONDecoder().decode(DisplayStateSnapshot.self, from: good)
        XCTAssertTrue(snapshot.isValid(bodyID: "ipad", sessionID: "session-a"))
        XCTAssertFalse(snapshot.isValid(bodyID: "ipad", sessionID: "session-b"))
    }
    func testGlobalWorkOverridesPassiveDotListening() {
        XCTAssertEqual(BodyActivityPolicy.resolve(capturing: false, speaking: false, sending: false,
            processing: true, dotPhase: "listening", dotFresh: true, connected: true), .working)
        XCTAssertEqual(BodyActivityPolicy.resolve(capturing: false, speaking: true, sending: false,
            processing: true, dotPhase: "listening", dotFresh: true, connected: true), .speaking)
        XCTAssertEqual(BodyActivityPolicy.resolve(capturing: true, speaking: false, sending: false,
            processing: true, dotPhase: "listening", dotFresh: true, connected: true), .listening)
    }

    func testStaleDotCannotMaskIdleOrGlobalWork() {
        XCTAssertEqual(BodyActivityPolicy.resolve(capturing: false, speaking: false, sending: false,
            processing: false, dotPhase: "speaking", dotFresh: false, connected: true), .idle)
        XCTAssertEqual(BodyActivityPolicy.resolve(capturing: false, speaking: false, sending: false,
            processing: true, dotPhase: "speaking", dotFresh: false, connected: true), .working)
    }

    func testGlobalPresentationRequiresFreshLeaseAndKnownExpression() throws {
        let now = Date(timeIntervalSince1970: 1_791_068_400)
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = ["schema_version": 1, "read_only": true,
            "observed_at": formatter.string(from: now), "expires_at": formatter.string(from: now.addingTimeInterval(30)),
            "activity": ["phase": "background"],
            "expression": ["available": true, "state": "reflective", "revision": 42]]
        let current = GlobalBodyPresentation(object: object, now: now)
        XCTAssertEqual(current?.expression, "reflective")
        XCTAssertTrue(current?.processing == true)
        XCTAssertFalse(current!.isFresh(at: now.addingTimeInterval(31)))
        XCTAssertNil(GlobalBodyPresentation(object: object, now: now.addingTimeInterval(31)))
        object["expression"] = ["available": true, "state": "private prose", "revision": 42]
        XCTAssertNil(GlobalBodyPresentation(object: object, now: now)?.expression)
        object["activity"] = ["phase": "waiting"]
        XCTAssertFalse(GlobalBodyPresentation(object: object, now: now)!.processing)
        object["read_only"] = false
        XCTAssertNil(GlobalBodyPresentation(object: object, now: now))
    }

    func testFailedMoodRefreshDoesNotSwitchToAnotherExpressionSource() throws {
        let now = Date(timeIntervalSince1970: 1_791_068_400)
        let formatter = ISO8601DateFormatter()
        let snapshot = try XCTUnwrap(GlobalBodyPresentation(object: ["schema_version": 1, "read_only": true,
            "observed_at": formatter.string(from: now), "expires_at": formatter.string(from: now.addingTimeInterval(30)),
            "activity": ["phase": "working"], "expression": ["available": true, "state": "focused", "revision": 42]], now: now))
        let retained = GlobalBodyPresentation.afterRefresh(nil, previous: snapshot, now: now.addingTimeInterval(10))
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: retained, paired: true,
            fallback: "joyful", now: now.addingTimeInterval(10)), "focused")
        XCTAssertNil(GlobalBodyPresentation.afterRefresh(nil, previous: snapshot, now: now.addingTimeInterval(31)))
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: snapshot, paired: true,
            fallback: "joyful", now: now.addingTimeInterval(31)), "awaiting state")
        XCTAssertEqual(GlobalBodyPresentation.expressionState(snapshot: nil, paired: false,
            fallback: "joyful", now: now), "joyful")
    }

    func testBodyProximityRequiresFreshPhysicalEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_791_068_400)
        let formatter = ISO8601DateFormatter()
        var evidence: [String: Any] = ["available": true, "state": "near",
            "source_endpoint_id": "s22plus-blaine-sensor", "observation_id": "receipt",
            "observed_at": formatter.string(from: now.addingTimeInterval(-10)),
            "expires_at": formatter.string(from: now.addingTimeInterval(35))]
        let sense = try XCTUnwrap(BodyProximity(object: evidence, now: now))
        XCTAssertEqual(sense.state, "near")
        XCTAssertEqual(sense.sourceEndpointID, "s22plus-blaine-sensor")
        XCTAssertFalse(sense.isFresh(at: now.addingTimeInterval(36)))
        XCTAssertNil(BodyProximity(object: evidence, now: now.addingTimeInterval(36)))
        evidence["state"] = "Blaine is here"
        XCTAssertNil(BodyProximity(object: evidence, now: now))
        evidence["state"] = "away"
        evidence["available"] = false
        XCTAssertNil(BodyProximity(object: evidence, now: now))
        evidence["available"] = true
        evidence["expires_at"] = formatter.string(from: now.addingTimeInterval(90))
        XCTAssertNil(BodyProximity(object: evidence, now: now))
    }

}
