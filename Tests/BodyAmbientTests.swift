import XCTest
@testable import KairoBody

final class BodyAmbientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(phase: String = "working", proximity: (String, String)? = nil,
                          observed: Date? = nil, lifetime: TimeInterval = 20) -> GlobalBodyPresentation? {
        let seen = observed ?? now
        var object: [String: Any] = [
            "schema_version": 1, "read_only": true,
            "observed_at": BodyJSON.iso8601.string(from: seen),
            "expires_at": BodyJSON.iso8601.string(from: seen.addingTimeInterval(lifetime)),
            "activity": ["phase": phase],
            "expression": ["available": true, "state": "curious", "revision": 3],
        ]
        if let proximity {
            object["body_proximity"] = [
                "available": true, "state": proximity.0,
                "source_endpoint_id": proximity.1, "observation_id": "obs_1",
                "observed_at": BodyJSON.iso8601.string(from: seen),
                "expires_at": BodyJSON.iso8601.string(from: seen.addingTimeInterval(40)),
            ]
        }
        return GlobalBodyPresentation(object: object, now: now)
    }

    func testPhaseWordsCoverEveryMirrorPhase() {
        XCTAssertEqual(BodyAmbient.phaseWord(.idle), "Quiet — online")
        XCTAssertEqual(BodyAmbient.phaseWord(.listening), "Listening")
        XCTAssertEqual(BodyAmbient.phaseWord(.thinking), "Thinking")
        XCTAssertEqual(BodyAmbient.phaseWord(.speaking), "Speaking with you")
        XCTAssertEqual(BodyAmbient.phaseWord(.waiting), "Waiting for you")
        XCTAssertEqual(BodyAmbient.phaseWord(.reflecting), "Working in the background")
        XCTAssertEqual(BodyAmbient.phaseWord(.disconnected), "Out of touch with Kairo")
    }

    func testCardsRunStateThenAffectThenPresenceThenLink() {
        var ring = RingMirrorState()
        ring.phase = .thinking
        ring.mood = "reflective"
        let cards = BodyAmbient.cards(ring: ring, presentation: snapshot(proximity: ("away", "s22plus-blaine-sensor")),
                                      socketConnected: true, now: now)
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards[0].title, "Thinking")
        XCTAssertEqual(cards[1].title, "Reflective")
        XCTAssertEqual(cards[2].title, "The room is quiet", "away proximity reads honestly")
        XCTAssertEqual(cards[3].title, "Body link steady")
    }

    func testQueuedWorkNamesItselfOnTheStateCard() {
        var ring = RingMirrorState()
        ring.phase = .waiting
        let cards = BodyAmbient.cards(ring: ring, presentation: snapshot(phase: "queued"),
                                      socketConnected: true, now: now)
        XCTAssertEqual(cards[0].detail, "Something is queued up")
    }

    func testNearProximityReadsAsCompany() {
        let card = BodyAmbient.presenceCard(
            proximity: snapshot(proximity: ("near", "s22plus-blaine-sensor"))?.proximity, now: now)
        XCTAssertEqual(card.title, "Right beside you")
        XCTAssertNotNil(card.detail)
    }

    func testStaleOrMissingProximityNeverInventsCompany() {
        XCTAssertEqual(BodyAmbient.presenceCard(proximity: nil, now: now).title, "No recent sight of you")
        // A proximity that has already expired cannot survive the snapshot parse.
        let aged = snapshot(proximity: ("near", "s22plus-blaine-sensor"),
                            observed: now.addingTimeInterval(-60), lifetime: 25)
        let card = BodyAmbient.presenceCard(proximity: aged?.proximity, now: now)
        XCTAssertEqual(card.title, "No recent sight of you")
    }

    func testDisconnectedBodySaysSoOutOfRight() {
        let cards = BodyAmbient.cards(ring: RingMirrorState(), presentation: snapshot(),
                                      socketConnected: false, now: now)
        XCTAssertEqual(cards.last?.title, "Body link reconnecting")
    }

    func testMoodCardMarksWhereTheAffectCameFrom() {
        var ring = RingMirrorState()
        ring.mood = "joyful"
        ring.presentationFresh = false
        let mood = BodyAmbient.cards(ring: ring, presentation: nil, socketConnected: true, now: now)[1]
        XCTAssertEqual(mood.title, "Joyful")
        XCTAssertEqual(mood.detail, "using the body's last known feel")
    }
}
